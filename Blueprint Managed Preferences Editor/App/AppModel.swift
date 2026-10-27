import Foundation
import JTKit
import Observation

/// App-wide state: the active connection, discovered blueprints, their editors
/// and JTKit's activity log.
@Observable
final class AppModel {
    enum DiscoveryState: Equatable {
        case idle
        case listing
        case fetchingDetails(completed: Int, total: Int)
        case finished(Date)
        case failed(String)
    }

    enum SidebarFilter: String, CaseIterable, Identifiable {
        case managedPreferences = "Managed Preferences"
        case all = "All Blueprints"
        var id: String { rawValue }
    }

    let profileStore: ProfileStore
    /// JTKit's activity log (Window › Activity Log, ⇧⌘L), filled by the Jamf client.
    let activityLog = ActivityLog()
    /// Where requests for real connections go: the network, or a fake server
    /// in tests. Also while demo mode is on (Test Connection in Settings).
    let session: URLSession
    /// JTKit's demo mode, saved under `demoMode`: sample Blueprints on a fake
    /// server inside the app instead of the saved connection.
    let demo: DemoMode
    /// Where backups of real connections go.
    private let savedBackupRoot: URL
    /// Where backups are written before every save and restore, and where the
    /// Restore list reads them: in demo mode the demo's temporary folder, never
    /// the real one.
    var backupRoot: URL {
        demo.isOn ? demo.scratchDirectory.appending(path: "Backups", directoryHint: .isDirectory) : savedBackupRoot
    }
    let updates = UpdateChecker(configuration: UpdateConfiguration(
        owner: "JordyThery",
        repository: "Blueprint-Managed-Preferences-Editor",
        appName: "Blueprint Managed Preferences Editor"
    ))

    private(set) var overviews: [JamfPlatform.BlueprintOverview] = []
    private(set) var details: [String: JamfPlatform.BlueprintDetail] = [:]
    private(set) var detailErrors: [String: String] = [:]
    /// The preference domains of each Blueprint with a ManagedClient payload,
    /// found once when it is stored: finding them walks the whole JSON.
    private(set) var preferenceDomains: [String: [String]] = [:]
    private(set) var discoveryState: DiscoveryState = .idle
    /// One editor per blueprint with a ManagedClient payload, kept while switching
    /// between blueprints so unsaved edits survive.
    private(set) var editors: [String: EditorModel] = [:]
    /// Blueprints that returned 409 DIVISION_PATCH_NOT_ALLOWED.
    var readOnlyBlueprintIDs: Set<String> = []

    /// Whether a Blueprint may not be written: assigned to a division, or
    /// refused for that before.
    func isReadOnly(_ id: String) -> Bool {
        readOnlyBlueprintIDs.contains(id) || details[id]?.isDivisionLocked == true
    }

    var sidebarFilter: SidebarFilter = .managedPreferences
    var searchText = ""
    var selectedBlueprintID: String?

    /// Maximum number of detail GETs in flight during discovery.
    let maxConcurrentDetailRequests = 5

    /// JTKit's client for the selected profile, kept while its credentials stay the same.
    private var client: (credentials: PlatformCredentials, client: JamfPlatform.Client)?
    /// The demo's client, one for the whole launch, like the demo server.
    private var demoClient: JamfPlatform.Client?
    private var refreshTask: Task<Void, Never>?

    static let demoModeKey = "demoMode"

    /// - Parameters: all for tests: saved connections, the network, the
    ///   backup folder and demo mode (off and not saved unless given).
    init(profileStore: ProfileStore = ProfileStore(), session: URLSession = .shared,
         backupRoot: URL = BackupStore.rootURL, demo: DemoMode? = nil) {
        self.profileStore = profileStore
        self.session = session
        self.savedBackupRoot = backupRoot
        self.demo = demo ?? DemoMode(key: Self.demoModeKey, arguments: [DemoMode.launchArgument, "NO"])
        // Turning demo mode on or off discards the editors, so unsaved edits ask first.
        self.demo.asksBeforeSwitching = { [unowned self] in self.hasUnsavedChanges }
    }

    /// The app as launched. A sandbox run (`-JTKitSandbox YES`, UI tests)
    /// keeps connections and secrets in memory.
    static func forLaunch() -> AppModel {
        let demo = DemoMode(key: demoModeKey)
        guard demo.isSandbox else { return AppModel(demo: demo) }
        return AppModel(profileStore: ProfileStore(defaults: DemoMode.sandboxDefaults(), secrets: SandboxSecretStore()),
                        demo: demo)
    }

    /// Demo mode is on or a saved connection is chosen.
    var hasActiveConnection: Bool {
        demo.isOn || profileStore.selectedProfile != nil
    }

    var isBusy: Bool {
        switch discoveryState {
        case .listing, .fetchingDetails: true
        default: false
        }
    }

    var hasUnsavedChanges: Bool {
        editors.values.contains(where: \.isDirty)
    }

    // MARK: Connection

    /// Where another connection was chosen: the main window (toolbar picker,
    /// Connection menu) or Settings › Connections. The question about unsaved
    /// changes appears there. In demo mode the main window shows no saved
    /// connection as chosen, so choosing one there leaves demo mode.
    enum ConnectionSwitchOrigin {
        case mainWindow
        case settings
    }

    /// A connection chosen while blueprint edits were unsaved, waiting for
    /// "Discard and Switch".
    struct PendingConnectionSwitch: Equatable {
        let profileID: UUID
        let origin: ConnectionSwitchOrigin
    }

    var pendingConnectionSwitch: PendingConnectionSwitch?

    /// Makes `profileID` the active connection, leaving demo mode, or, when
    /// blueprint edits are unsaved, keeps it waiting for "Discard and Switch",
    /// since switching discards them. Returns true when it asks first.
    /// Clearing the choice (after the active connection was deleted) never
    /// asks and stays in demo mode.
    @discardableResult
    func chooseConnection(_ profileID: UUID?, from origin: ConnectionSwitchOrigin) -> Bool {
        let leavesDemo = demo.isOn && origin == .mainWindow && profileID != nil
        guard profileID != profileStore.selectedProfileID || leavesDemo else { return false }
        if let profileID, hasUnsavedChanges {
            pendingConnectionSwitch = PendingConnectionSwitch(profileID: profileID, origin: origin)
            return true
        }
        select(profileID)
        return false
    }

    /// "Discard and Switch": makes the waiting connection the active one.
    func confirmConnectionSwitch() {
        guard let pending = pendingConnectionSwitch else { return }
        pendingConnectionSwitch = nil
        select(pending.profileID)
    }

    /// The question about unsaved edits was already asked (or not needed).
    private func select(_ profileID: UUID?) {
        if profileID != nil { demo.isOn = false }
        profileStore.selectedProfileID = profileID
    }

    /// The client for the selected profile, rebuilt when its credentials
    /// change. In demo mode the demo's, which reads no saved connection or
    /// Keychain item and reaches only the demo server.
    func currentClient() throws -> JamfPlatform.Client {
        if demo.isOn { return try currentDemoClient() }
        guard let profile = profileStore.selectedProfile,
              let credentials = profileStore.credentials(for: profile) else {
            throw APIError.missingCredentials
        }
        if let client, client.credentials == credentials {
            return client.client
        }
        let newClient = try makeClient(credentials: credentials)
        client = (credentials, newClient)
        return newClient
    }

    /// The Blueprints API for the selected profile.
    func currentService() throws -> JamfPlatform.Blueprints {
        JamfPlatform.Blueprints(client: try currentClient())
    }

    /// A client for a real connection, on the real network, also while demo
    /// mode is on (Test Connection).
    func makeClient(credentials: PlatformCredentials) throws -> JamfPlatform.Client {
        try PlatformAPIClient.make(credentials: credentials, session: session, log: activityLog)
    }

    /// The demo's client, with the app's allow-list; the first one also adds
    /// the app's sample Blueprints (`DemoBlueprints`) to the demo server.
    private func currentDemoClient() throws -> JamfPlatform.Client {
        if let demoClient { return demoClient }
        demo.jamfPlatformServer.add(DemoBlueprints.all)
        let source = demo.jamfPlatform()
        let made = try PlatformAPIClient.make(connection: source.connection, secret: source.secret,
                                              session: source.session, log: activityLog)
        demoClient = made
        return made
    }

    /// Called when the user switches profile: clears everything loaded from the old tenant.
    func connectionDidChange() {
        refreshTask?.cancel()
        client = nil
        overviews = []
        details = [:]
        detailErrors = [:]
        preferenceDomains = [:]
        for editor in editors.values { editor.detachUndoHistory() }
        editors = [:]
        readOnlyBlueprintIDs = []
        selectedBlueprintID = nil
        discoveryState = .idle
    }

    // MARK: Details and editors

    /// Records a freshly fetched detail. Editors without unsaved changes are
    /// rebased onto it; editors with unsaved changes keep their baseline (the
    /// concurrency check at save time catches server-side changes).
    func store(_ detail: JamfPlatform.BlueprintDetail) {
        details[detail.id] = detail
        detailErrors[detail.id] = nil
        let payloads = detail.managedPreferencePayloads
        preferenceDomains[detail.id] = payloads.isEmpty ? nil : JamfPlatform.BlueprintDetail.domains(of: payloads)
        if let index = overviews.firstIndex(where: { $0.id == detail.id }) {
            overviews[index] = detail.overview
        } else {
            overviews.insert(detail.overview, at: 0)
        }
        if let editor = editors[detail.id] {
            if !editor.isDirty && !editor.isBusy { editor.reset(to: detail) }
        } else if !payloads.isEmpty {
            editors[detail.id] = EditorModel(detail: detail, app: self)
        }
    }

    // MARK: Discovery

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await runDiscovery() }
    }

    private func runDiscovery() async {
        let service: JamfPlatform.Blueprints
        do {
            service = try currentService()
        } catch {
            discoveryState = .failed(error.localizedDescription)
            return
        }

        discoveryState = .listing
        let list: [JamfPlatform.BlueprintOverview]
        do {
            list = try await service.list()
        } catch is CancellationError {
            return
        } catch {
            discoveryState = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }

        let listedIDs = Set(list.map(\.id))
        // Blueprints that disappeared from the server stay listed while they hold
        // unsaved edits, so those edits can still be reviewed, saved or discarded.
        let retained = editors.filter { listedIDs.contains($0.key) || $0.value.isDirty }
        for (id, editor) in editors where retained[id] == nil {
            editor.detachUndoHistory()
        }
        editors = retained
        let keptIDs = retained.keys.filter { !listedIDs.contains($0) }.sorted()
        overviews = list + keptIDs.compactMap { retained[$0]?.base.overview }
        details = details.filter { listedIDs.contains($0.key) || retained[$0.key] != nil }
        preferenceDomains = preferenceDomains.filter { details[$0.key] != nil }
        detailErrors = [:]
        discoveryState = .fetchingDetails(completed: 0, total: list.count)

        // Fetch details with a bounded number of requests in flight.
        await withTaskGroup(of: (String, Result<JamfPlatform.BlueprintDetail, Error>).self) { group in
            var pending = list.map(\.id)[...]
            var completed = 0

            func enqueueNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask {
                    do {
                        return (id, .success(try await service.detail(id: id)))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            for _ in 0..<maxConcurrentDetailRequests { enqueueNext() }

            for await (id, result) in group {
                if Task.isCancelled {
                    group.cancelAll()
                    return
                }
                switch result {
                case .success(let detail):
                    store(detail)
                case .failure(let error):
                    detailErrors[id] = error.localizedDescription
                }
                completed += 1
                discoveryState = .fetchingDetails(completed: completed, total: list.count)
                enqueueNext()
            }
        }
        guard !Task.isCancelled else { return }
        discoveryState = .finished(Date())
    }

    /// Fetches one blueprint by ID, whether or not it contains Managed Preferences.
    func fetchBlueprint(id: String) async throws {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let detail = try await currentService().detail(id: trimmed)
        store(detail)
        // Make sure the fetched blueprint is visible even if it has no ManagedClient payload.
        if preferenceDomains[detail.id] == nil { sidebarFilter = .all }
        selectedBlueprintID = detail.id
    }

    // MARK: Sidebar

    var visibleOverviews: [JamfPlatform.BlueprintOverview] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return overviews.filter { overview in
            let domains = preferenceDomains[overview.id]
            if sidebarFilter == .managedPreferences {
                guard domains != nil else { return false }
            }
            guard !query.isEmpty else { return true }
            if overview.name.localizedCaseInsensitiveContains(query) { return true }
            if overview.description?.localizedCaseInsensitiveContains(query) == true { return true }
            return domains?.contains { $0.localizedCaseInsensitiveContains(query) } ?? false
        }
    }

    var managedPreferencesCount: Int {
        preferenceDomains.count
    }
}
