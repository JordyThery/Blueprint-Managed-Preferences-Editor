import Foundation
import JTKit
import JTKitTestSupport
import SwiftUI
import Testing
@testable import Blueprint_Managed_Preferences_Editor

/// Counts every read and write, so a test can show the Keychain isn't touched.
private final class CountingSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var reads = 0
    private var writes = 0

    var readCount: Int { lock.withLock { reads } }
    var writeCount: Int { lock.withLock { writes } }

    func secret(for account: String) -> String? {
        lock.withLock {
            reads += 1
            return secrets[account]
        }
    }

    func setSecret(_ secret: String?, for account: String) -> Bool {
        lock.withLock {
            writes += 1
            secrets[account] = secret
            return true
        }
    }
}

/// Demo mode with the real editor and JTKit's real client against JTKit's demo
/// server, next to one saved (throwaway) connection and a throwaway "real"
/// backup folder that must stay empty.
@MainActor
@Suite("Demo mode", .serialized)
final class DemoModeTests {
    private let suiteName = "be.jordythery.blueprint-managed-preferences-editor.tests.demo-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let realBackupRoot = FileManager.default.temporaryDirectory.appending(path: "bmpe-demo-real-\(UUID().uuidString)")
    private let secrets = CountingSecretStore()
    private let profile = ConnectionProfile(name: "Production", region: .eu,
                                            environmentID: "5f1e2d3c-4b5a-4968-8776-655443322110", clientID: "client-1")
    nonisolated private static let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)
    private var scratch: URL?

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: realBackupRoot)
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// An app with one saved connection, demo mode on for this run (or off),
    /// and the real network replaced by `server`.
    private func makeApp(demoOn: Bool = true, server: MockServer? = nil) throws -> AppModel {
        let store = ProfileStore(defaults: defaults, secrets: secrets)
        try store.connections.save(profile, secrets: [.main: "real-secret"])
        store.selectedProfileID = profile.id
        let demo = DemoMode(key: AppModel.demoModeKey, defaults: defaults,
                            arguments: [DemoMode.launchArgument, demoOn ? "YES" : "NO"])
        scratch = demo.scratchDirectory
        let unreachable = MockServer { _ in Issue.record("The real network was used"); return .json(500, "{}") }
        return AppModel(profileStore: store, session: (server ?? unreachable).session,
                        backupRoot: realBackupRoot, demo: demo)
    }

    private func savedProfilesData() -> Data? {
        defaults.data(forKey: "connectionProfiles")
    }

    /// Sets `EnableCheckForUpdatesButton` in the first payload (Microsoft AutoUpdate, Forced) to true.
    private func editFirstPayload(_ editor: EditorModel) throws {
        let domain = try #require(editor.document.payloads[0].domains.first)
        #expect(domain.name == "com.microsoft.autoupdate2")
        let entry = try #require(domain.entries?.first)
        let nodeID = try #require(entry.settings.first { $0.key == "EnableCheckForUpdatesButton" }?.id)
        let changed = editor.modifySettings("Edit", domainID: domain.id, entryID: entry.id) { nodes in
            nodes.modifyNode(withID: nodeID) { $0.value = .boolean(true) }
        }
        #expect(changed && editor.isDirty)
    }

    private func text(at path: [LosslessJSON.PathComponent], in json: String) throws -> String {
        try #require(try LosslessJSON(string: json).value(at: path)).serializedString()
    }

    private func storedSteps(_ app: AppModel, _ id: String) throws -> String {
        try #require(app.demo.jamfPlatformServer.blueprint(id: id)?["steps"]).serializedString()
    }

    /// The "only the edited payload changes" rule, against the demo server: what
    /// the server ends up storing is the steps as read, with only the first
    /// payload's one value changed, the second payload byte for byte included.
    @Test func savingOneEditedPayloadSendsEverythingElseBackByteForByteInDemoMode() async throws {
        let app = try makeApp()
        let id = DemoBlueprints.microsoft365ID
        try await app.fetchBlueprint(id: id)
        let editor = try #require(app.editors[id])
        #expect(editor.document.payloads.count == 2)
        let read = String(decoding: editor.base.rawData, as: UTF8.self)
        let originalSteps = try text(at: [.key("steps")], in: read)
        let firstPayload = try text(at: editor.document.payloads[0].path, in: read)
        let secondPayload = try text(at: editor.document.payloads[1].path, in: read)
        #expect(originalSteps == (try storedSteps(app, id)), "the sample data is in the service's form")
        let before = try #require(app.demo.jamfPlatformServer.blueprint(id: id))

        try editFirstPayload(editor)
        await editor.save(andDeploy: false)

        #expect(editor.alert?.title == "Saved")
        #expect(app.demo.jamfPlatformServer.patchCount == 1)
        let editedFirstPayload = firstPayload.replacingOccurrences(
            of: #""EnableCheckForUpdatesButton":false"#, with: #""EnableCheckForUpdatesButton":true"#)
        #expect(editedFirstPayload != firstPayload)
        #expect(originalSteps.components(separatedBy: firstPayload).count == 2, "The first payload appears once")
        let stored = try storedSteps(app, id)
        #expect(stored == originalSteps.replacingOccurrences(of: firstPayload, with: editedFirstPayload))
        let range = try #require(originalSteps.range(of: firstPayload))
        #expect(stored.hasPrefix(String(originalSteps[..<range.lowerBound])))
        #expect(stored.hasSuffix(String(originalSteps[range.upperBound...])))
        #expect(stored.contains(secondPayload))

        // Name, description and scope stay as they were.
        let after = try #require(app.demo.jamfPlatformServer.blueprint(id: id))
        for key in ["id", "name", "description", "scope", "created"] {
            #expect(after[key] == before[key], "\(key)")
        }

        // The backup is the Blueprint as read, in the demo's temporary folder.
        #expect(app.backupRoot.path().hasPrefix(app.demo.scratchDirectory.path()))
        let backups = BackupStore.backups(for: id, root: app.backupRoot)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: try #require(backups.first).url) == Data(read.utf8))
        #expect(!FileManager.default.fileExists(atPath: realBackupRoot.path()), "the real folder is untouched")
        #expect(!FileManager.default.fileExists(atPath: BackupStore.directory(for: id).path()))
    }

    @Test func restoreAndDeployWorkInDemoModeAndBackUpIntoTheTemporaryFolder() async throws {
        let app = try makeApp()
        let id = DemoBlueprints.microsoft365ID
        try await app.fetchBlueprint(id: id)
        let editor = try #require(app.editors[id])
        let originalSteps = try storedSteps(app, id)
        try editFirstPayload(editor)
        await editor.save(andDeploy: true)
        #expect(editor.alert?.title == "Saved and Deployment Started")
        #expect(app.demo.jamfPlatformServer.deployCount == 1)

        let backup = try #require(BackupStore.backups(for: id, root: editor.backupRoot).first)
        await editor.restore(from: backup)
        #expect(editor.alert?.title == "Restored")
        #expect(try storedSteps(app, id) == originalSteps, "the backup's steps, byte for byte")
        #expect(BackupStore.backups(for: id, root: app.backupRoot).count == 2, "a fresh backup before the restore")
        #expect(!FileManager.default.fileExists(atPath: realBackupRoot.path()))
    }

    @Test func demoModeReadsNothingSavedAndShowsTheSampleBlueprints() async throws {
        let app = try makeApp()
        let savedBefore = savedProfilesData()
        let readsBefore = secrets.readCount
        let writesBefore = secrets.writeCount

        let blueprints = try await app.currentService().list()
        #expect(blueprints.count == 9, "JTKit's six Contoso Blueprints and the app's three")
        for id in [DemoBlueprints.microsoft365ID, DemoBlueprints.chromeID, DemoBlueprints.helpdeskID] {
            try await app.fetchBlueprint(id: id)
        }
        #expect(app.preferenceDomains[DemoBlueprints.microsoft365ID] == ["com.microsoft.autoupdate2", "com.microsoft.Outlook"])
        #expect(app.preferenceDomains[DemoBlueprints.chromeID] == ["com.google.Chrome"])
        #expect(app.preferenceDomains[DemoBlueprints.helpdeskID] == ["com.contoso.example.helpdesk"])
        let modes = try #require(app.editors[DemoBlueprints.microsoft365ID]?.document.payloads[0].domains.first?.entries)
        #expect(modes.map(\.mode) == ["Forced", "Set-Once", "Often"])

        #expect(secrets.readCount == readsBefore && secrets.writeCount == writesBefore, "no Keychain")
        #expect(savedProfilesData() == savedBefore)
        #expect(app.profileStore.selectedProfileID == profile.id, "the connection in use is left as it was")
        #expect(defaults.object(forKey: AppModel.demoModeKey) == nil, "a -JTKitDemo run saves nothing")
        #expect(!app.activityLog.entries.isEmpty)
        #expect(app.activityLog.entries.allSatisfy { $0.connection == "Contoso (Demo)" })
    }

    @Test func testConnectionStaysRealInDemoMode() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/auth/token": Self.token
            default: .json(200, #"{"totalCount":3,"results":[]}"#)
            }
        }
        let app = try makeApp(server: server)
        let message = try await app.testConnection(profile, typedSecret: nil)
        #expect(message == "Connected · 3 Blueprints")
        #expect(server.requests.allSatisfy { $0.url.host() == "eu.api.jamfcloud.com" })
        #expect(String(decoding: try #require(server.requests.first).body, as: UTF8.self).contains("real-secret"))
        #expect(app.demo.jamfPlatformServer.requestCount == 0)
    }

    @Test func choosingASavedConnectionInThePickerLeavesDemoMode() throws {
        let app = try makeApp()
        let picker = app.connectionSelection(from: .mainWindow)
        #expect(picker.wrappedValue == nil, "no saved connection shown as chosen")
        #expect(app.connectionSelection(from: .settings).wrappedValue == profile.id)
        picker.wrappedValue = profile.id
        #expect(!app.demo.isOn)
        #expect(app.profileStore.selectedProfileID == profile.id)
        #expect(app.backupRoot == realBackupRoot)
    }

    @Test func switchingDemoModeWithUnsavedEditsAsksFirst() async throws {
        let app = try makeApp()
        try await app.fetchBlueprint(id: DemoBlueprints.microsoft365ID)
        let editor = try #require(app.editors[DemoBlueprints.microsoft365ID])

        #expect(!app.demo.requestSwitch(to: false), "nothing unsaved: no question")
        #expect(!app.demo.isOn)
        app.demo.isOn = true
        try editFirstPayload(editor)

        #expect(app.demo.requestSwitch(to: false))
        #expect(app.demo.isOn && app.demo.pendingSwitch == false)
        app.demo.cancelSwitch()
        #expect(app.demo.isOn && editor.isDirty, "cancel keeps demo mode and the edits")

        // Choosing a saved connection asks the connection question instead.
        #expect(app.chooseConnection(profile.id, from: .mainWindow))
        #expect(app.demo.isOn)
        app.confirmConnectionSwitch()
        #expect(!app.demo.isOn && app.profileStore.selectedProfileID == profile.id)
    }

    @Test func outsideDemoModeTheRealConnectionAndFolderAreUsed() throws {
        let app = try makeApp(demoOn: false)
        #expect(app.backupRoot == realBackupRoot)
        _ = try app.currentClient()
        #expect(secrets.readCount > 0)
        #expect(app.demo.jamfPlatformServer.requestCount == 0)
    }
}

/// The app's sample data is clearly fake, like JTKit's.
@Suite("Demo sample data")
struct DemoSampleDataTests {
    private static func strings(in json: LosslessJSON) -> [String] {
        switch json {
        case .string(let text): [text]
        case .array(let items): items.flatMap(strings(in:))
        case .object(let object): object.members.flatMap { [$0.key] + strings(in: $0.value) }
        default: []
        }
    }

    @Test func everyIDIsFakeAndEveryAddressIsContosos() throws {
        let blueprints = DemoBlueprints.all
        #expect(blueprints.count == 3)
        let texts = blueprints.flatMap { Self.strings(in: .object($0)) }
        let uuid = /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        let realDomains = ["com.apple.", "com.jamf.", "com.microsoft.", "com.google."]
        for text in texts {
            for match in text.matches(of: uuid) {
                #expect(DemoSamples.isDemoID(String(match.output)), "\(text)")
            }
            if text.hasPrefix("com."), !realDomains.contains(where: text.hasPrefix) {
                #expect(text.hasPrefix("com.contoso.example."), "\(text)")
            }
            if let host = URL(string: text)?.host(), text.contains("://"), !text.hasPrefix("file:") {
                #expect(host.hasSuffix("contoso.example"), "\(text)")
            }
            if text.contains("@") {
                #expect(text.hasSuffix("@contoso.example"), "\(text)")
            }
        }
    }
}
