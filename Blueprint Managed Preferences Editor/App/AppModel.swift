import Foundation
import Observation

/// App-wide state: the active connection, discovered blueprints, their editors
/// and the request log.
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

    let profileStore = ProfileStore()
    let requestLog = RequestLog()

    private(set) var overviews: [BlueprintOverview] = []
    private(set) var details: [String: BlueprintDetail] = [:]
    private(set) var detailErrors: [String: String] = [:]
    private(set) var discoveryState: DiscoveryState = .idle
    /// One editor per blueprint with a ManagedClient payload, kept while switching
    /// between blueprints so unsaved edits survive.
    private(set) var editors: [String: EditorModel] = [:]
    /// Blueprints that returned 409 DIVISION_PATCH_NOT_ALLOWED.
    var readOnlyBlueprintIDs: Set<String> = []

    var sidebarFilter: SidebarFilter = .managedPreferences
    var searchText = ""
    var selectedBlueprintID: String?

    /// Maximum number of detail GETs in flight during discovery.
    let maxConcurrentDetailRequests = 5

    private var client: PlatformAPIClient?
    private var refreshTask: Task<Void, Never>?

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

    /// Returns a client for the selected profile, rebuilding it when credentials change.
    func currentService() throws -> BlueprintService {
        guard let profile = profileStore.selectedProfile,
              let credentials = profileStore.credentials(for: profile) else {
            throw APIError.missingCredentials
        }
        if let client, client.credentials == credentials {
            return BlueprintService(client: client)
        }
        let newClient = makeClient(credentials: credentials)
        client = newClient
        return BlueprintService(client: newClient)
    }

    func makeClient(credentials: PlatformCredentials) -> PlatformAPIClient {
        let log = requestLog
        return PlatformAPIClient(credentials: credentials) { entry in
            log.append(entry)
        }
    }

    /// Called when the user switches profile: clears everything loaded from the old tenant.
    func connectionDidChange() {
        refreshTask?.cancel()
        client = nil
        overviews = []
        details = [:]
        detailErrors = [:]
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
    func store(_ detail: BlueprintDetail) {
        details[detail.id] = detail
        detailErrors[detail.id] = nil
        if let index = overviews.firstIndex(where: { $0.id == detail.id }) {
            overviews[index] = detail.overview
        } else {
            overviews.insert(detail.overview, at: 0)
        }
        if let editor = editors[detail.id] {
            if !editor.isDirty && !editor.isBusy { editor.reset(to: detail) }
        } else if detail.containsManagedPreferences {
            editors[detail.id] = EditorModel(detail: detail, app: self)
        }
    }

    // MARK: Discovery

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { await runDiscovery() }
    }

    private func runDiscovery() async {
        let service: BlueprintService
        do {
            service = try currentService()
        } catch {
            discoveryState = .failed(error.localizedDescription)
            return
        }

        discoveryState = .listing
        let list: [BlueprintOverview]
        do {
            list = try await service.listAll()
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
        detailErrors = [:]
        discoveryState = .fetchingDetails(completed: 0, total: list.count)

        // Fetch details with a bounded number of requests in flight.
        await withTaskGroup(of: (String, Result<BlueprintDetail, Error>).self) { group in
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
        if !detail.containsManagedPreferences { sidebarFilter = .all }
        selectedBlueprintID = detail.id
    }

    // MARK: Sidebar

    var visibleOverviews: [BlueprintOverview] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return overviews.filter { overview in
            let detail = details[overview.id]
            if sidebarFilter == .managedPreferences {
                guard detail?.containsManagedPreferences == true else { return false }
            }
            guard !query.isEmpty else { return true }
            if overview.name.localizedCaseInsensitiveContains(query) { return true }
            if overview.description?.localizedCaseInsensitiveContains(query) == true { return true }
            return detail?.preferenceDomains.contains { $0.localizedCaseInsensitiveContains(query) } ?? false
        }
    }

    var managedPreferencesCount: Int {
        details.values.filter(\.containsManagedPreferences).count
    }
}
