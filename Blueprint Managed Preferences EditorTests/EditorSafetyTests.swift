import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Blueprint_Managed_Preferences_Editor

/// Counts requests per kind and lets a test hold a PATCH until it says so.
private final class ServerScript: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    let patchGate = DispatchSemaphore(value: 0)

    /// How many requests of this kind arrived so far, this one included.
    func count(_ kind: String) -> Int {
        lock.withLock {
            counts[kind, default: 0] += 1
            return counts[kind] ?? 0
        }
    }
}

/// Deploy, duplicate domains, reload, connection changes while an operation
/// runs, Save & Deploy step by step, restore and import, through the real
/// editor and JTKit's client against a fake server.
@MainActor
@Suite("Editor safety")
final class EditorSafetyTests {
    private let suiteName = "be.jordythery.blueprint-managed-preferences-editor.tests.safety-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let backupRoot = FileManager.default.temporaryDirectory.appending(path: "bmpe-safety-\(UUID().uuidString)")
    private let profile = ConnectionProfile(name: "Test Tenant", region: .eu,
                                            environmentID: "5f1e2d3c-4b5a-4968-8776-655443322110", clientID: "id")
    private let otherProfile = ConnectionProfile(name: "Other Tenant", region: .us,
                                                 environmentID: "5f1e2d3c-4b5a-4968-8776-655443322111", clientID: "id-2")
    nonisolated private static let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)
    nonisolated private static let blueprintID = "0a1b2c3d-2222-4222-8222-0123456789ab"
    nonisolated private static let blueprintPath = "/blueprints/v1/blueprints/\(blueprintID)"
    nonisolated private static let changedJSON = emailBlueprintJSON.replacingOccurrences(
        of: "2026-01-02T09:31:00.222222Z", with: "2026-01-03T10:00:00.000000Z")
    nonisolated private static let noContent = MockResponse(status: 204, body: Data())
    nonisolated private static let notFound = MockResponse.json(404, #"{"httpStatus":404,"errors":[{"code":"NOT_FOUND"}]}"#)

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: backupRoot)
    }

    private func makeApp(_ server: MockServer, json: String = emailBlueprintJSON) throws -> (AppModel, EditorModel) {
        let profileStore = ProfileStore(defaults: defaults, secrets: InMemorySecretStore())
        try profileStore.connections.save(profile, secrets: [.main: "s3cr3t"])
        try profileStore.connections.save(otherProfile, secrets: [.main: "s3cr3t-2"])
        profileStore.selectedProfileID = profile.id
        let app = AppModel(profileStore: profileStore, session: server.session, backupRoot: backupRoot)
        let detail = try JamfPlatform.BlueprintDetail(data: Data(json.utf8))
        app.store(detail)
        return (app, try #require(app.editors[detail.id]))
    }

    private static func silentServer() -> MockServer {
        MockServer { _ in Issue.record("No request may be sent"); return .json(500, "{}") }
    }

    private func edit(_ editor: EditorModel, to value: Bool = false) throws {
        let domain = try #require(editor.document.payloads[0].domains.first)
        let entry = try #require(domain.entries?.first)
        let nodeID = try #require(entry.settings.first { $0.key == "OfficeAutoSignIn" }?.id)
        editor.modifySettings("Edit", domainID: domain.id, entryID: entry.id) { nodes in
            nodes.modifyNode(withID: nodeID) { $0.value = .boolean(value) }
        }
        #expect(editor.isDirty == !value)
    }

    private func methods(_ server: MockServer) -> [String] {
        server.requests.filter { $0.path != "/auth/token" }.map(\.method)
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: Deploy (finding 1)

    /// Deploy… confirms the scope of the copy loaded earlier, so a Blueprint
    /// changed on the server since is not deployed.
    @Test func deployReadsTheBlueprintFirstAndRefusesAChangedOne() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? Self.token : .json(200, Self.changedJSON)
        }
        let (app, editor) = try makeApp(server)

        await editor.deploy()

        #expect(methods(server) == ["GET"], "no deploy request")
        #expect(editor.alert?.kind == .conflict)
        #expect(editor.alert?.message.contains("Nothing was deployed.") == true)
        #expect(editor.alert?.message.contains("2026-01-02T09:31") == false, "times are formatted")
        withExtendedLifetime(app) {}
    }

    @Test func deployOfAnUnchangedBlueprintStartsTheDeployment() async throws {
        let server = MockServer { request in
            switch (request.method, request.path) {
            case ("POST", "/auth/token"): Self.token
            case ("GET", Self.blueprintPath): .json(200, emailBlueprintJSON)
            case ("POST", Self.blueprintPath + "/deploy"): Self.noContent
            default: .json(500, "{}")
            }
        }
        let (app, editor) = try makeApp(server)

        await editor.deploy()

        #expect(methods(server) == ["GET", "POST", "GET"])
        #expect(editor.alert?.title == "Deployment Started")
        withExtendedLifetime(app) {}
    }

    // MARK: Duplicate domains (finding 2)

    @Test func newDomainCannotReuseANameInItsPayload() throws {
        let (app, editor) = try makeApp(Self.silentServer())
        let office = try #require(editor.document.payloads[0].domains.first)

        // No domain selected: the first payload, which holds com.microsoft.office.
        #expect(editor.validateDomainName("com.microsoft.office", renaming: nil) != nil)
        #expect(editor.addDomain(name: "com.microsoft.office") == nil)
        // The clashing domain itself selected.
        #expect(editor.validateDomainName("com.microsoft.office", renaming: nil, near: office.id) != nil)
        #expect(editor.addDomain(name: " com.microsoft.office ", near: office.id) == nil)
        #expect(!editor.isDirty)
        // Renaming a domain to its own name is fine; a new name is too.
        #expect(editor.validateDomainName("com.microsoft.office", renaming: office.id) == nil)
        #expect(editor.addDomain(name: "com.example.new") != nil)
        #expect(editor.validateDomainName("", renaming: nil) == "The domain name can’t be empty.")
        withExtendedLifetime(app) {}
    }

    @Test func importLeavesADomainWithAnUnexpectedShapeAlone() throws {
        let json = emailBlueprintJSON.replacingOccurrences(
            of: #""com.microsoft.office":{"Forced":[{"mcx_preference_settings":{"OfficeAutoSignIn":true,"OfficeActivationEmailAddress":"$EMAIL"}}]}"#,
            with: #""com.microsoft.office":"not an object""#)
        #expect(json != emailBlueprintJSON)
        let (app, editor) = try makeApp(Self.silentServer(), json: json)
        #expect(editor.document.payloads[0].domains.first?.isEditable == false)

        let result = editor.importDomains(
            [ImportedDomain(name: "com.microsoft.office", mode: "Forced", settings: [PlistNode(key: "K", value: .string("v"))])],
            near: nil)

        #expect(result == EditorModel.ImportResult(skipped: ["com.microsoft.office"]))
        #expect(editor.document.payloads[0].domains.count == 1, "no second domain with the same name")
        #expect(!editor.isDirty)
        #expect(result.summary(fileName: "x.mobileconfig").title == "Nothing Imported")
        withExtendedLifetime(app) {}
    }

    /// The review lists a duplicate domain name as its own domain, and a
    /// change of order, so it never says "No Differences" for a real change.
    @Test func theReviewShowsDuplicateDomainsAndOrderChanges() throws {
        // Two members with the same key (KeyValuePairs keeps both).
        let one = try LosslessJSON(string: #"{"Forced":[{"mcx_preference_settings":{"A":true}}]}"#)
        let old = LosslessJSON.Object(["com.example.app": one])
        let duplicated = LosslessJSON.Object(["com.example.app": one, "com.example.app": one])
        #expect(duplicated.members.count == 2)
        let duplicateChanges = PreferenceChange.diff(old: old, new: duplicated, payloadName: "P", payloadID: "p")
        #expect(duplicateChanges.map(\.domain) == ["com.example.app (2)"])
        #expect(duplicateChanges.first?.kind == .added)

        let ab = LosslessJSON.object(LosslessJSON.Object(["A": .bool(true), "B": .bool(false)]))
        let ba = LosslessJSON.object(LosslessJSON.Object(["B": .bool(false), "A": .bool(true)]))
        let reordered = PreferenceChange.diff(old: LosslessJSON.Object(["d": ab]), new: LosslessJSON.Object(["d": ba]),
                                              payloadName: "P", payloadID: "p")
        #expect(reordered.map(\.keyPath) == ["(order of keys)"])

        #expect(PreferenceChange.diff(old: old, new: old, payloadName: "P", payloadID: "p").isEmpty)
    }

    // MARK: Reload and discard (findings 3, 14)

    @Test func reloadKeepsUnsavedEditsUnlessTheyAreDiscarded() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? Self.token : .json(200, emailBlueprintJSON)
        }
        let (app, editor) = try makeApp(server)
        try edit(editor)

        await editor.reload()
        #expect(server.requests.isEmpty, "nothing is read")
        #expect(editor.isDirty)

        await editor.reload(discardingEdits: true)
        #expect(methods(server) == ["GET"])
        #expect(!editor.isDirty)
        withExtendedLifetime(app) {}
    }

    @Test func discardGoesBackToTheNewestCopyReadFromTheServer() throws {
        let (app, editor) = try makeApp(Self.silentServer())
        try edit(editor)
        // A Refresh reads a newer copy; the dirty editor keeps its baseline.
        app.store(try JamfPlatform.BlueprintDetail(data: Data(Self.changedJSON.utf8), fetchedAt: Date().addingTimeInterval(60)))
        #expect(editor.base.overview.updated == "2026-01-02T09:31:00.222222Z")

        editor.discardChanges()

        #expect(editor.base.overview.updated == "2026-01-03T10:00:00.000000Z")
        #expect(!editor.isDirty)
    }

    // MARK: Connection changes (findings 4, 5, 10)

    /// A save in flight while the user switches connection: its result shows
    /// in the main window and nothing of the old tenant reaches the new one.
    @Test func aSaveInFlightDuringAConnectionSwitchStaysWithTheOldConnection() async throws {
        let script = ServerScript()
        let server = MockServer { request in
            switch (request.method, request.path) {
            case ("POST", "/auth/token"): return Self.token
            case ("GET", Self.blueprintPath): return .json(200, emailBlueprintJSON)
            case ("PATCH", Self.blueprintPath):
                _ = script.patchGate.wait(timeout: .now() + 10)
                return Self.noContent
            default: return .json(500, "{}")
            }
        }
        let (app, editor) = try makeApp(server)
        try edit(editor)

        let save = Task { await editor.save(andDeploy: false) }
        await waitUntil { server.requests.contains { $0.method == "PATCH" } }
        #expect(app.chooseConnection(otherProfile.id, from: .mainWindow), "unsaved edits ask first")
        app.confirmConnectionSwitch()
        #expect(app.editors.isEmpty && app.overviews.isEmpty)
        script.patchGate.signal()
        await save.value

        #expect(app.overviews.isEmpty, "the old tenant's Blueprint isn't listed under the new one")
        #expect(app.details.isEmpty && app.editors.isEmpty)
        #expect(editor.alert == nil)
        #expect(app.notice?.title == "Saved")
        #expect(app.notice?.message.contains("before the connection changed") == true)
    }

    /// Editing the active connection's Environment ID in Settings makes it
    /// another tenant: the old Blueprints are cleared, also with no window open.
    @Test func editingTheActiveConnectionsEnvironmentClearsTheOldBlueprints() async throws {
        let (app, editor) = try makeApp(Self.silentServer())
        try edit(editor)
        let generation = app.connectionGeneration

        var edited = profile
        edited.environmentID = "5f1e2d3c-4b5a-4968-8776-655443322112"
        try app.profileStore.connections.save(edited)
        await waitUntil { app.editors.isEmpty }

        #expect(app.editors.isEmpty && app.overviews.isEmpty && app.details.isEmpty)
        #expect(app.connectionGeneration == generation + 1)
        #expect(app.notice?.title == "Unsaved Changes Discarded")

        // Renaming the connection is the same tenant: nothing is cleared.
        app.store(try JamfPlatform.BlueprintDetail(data: Data(emailBlueprintJSON.utf8)))
        edited.name = "Renamed"
        try app.profileStore.connections.save(edited)
        _ = try app.currentClient()
        #expect(app.editors.count == 1)
    }

    /// Deleting the active connection in Settings doesn't ask, so the
    /// discarded edits are reported.
    @Test func clearingTheConnectionReportsDiscardedEdits() throws {
        let (app, editor) = try makeApp(Self.silentServer())
        try edit(editor)

        #expect(!app.chooseConnection(nil, from: .settings), "it doesn't ask")
        app.tenantDidChangeIfNeeded()

        #expect(app.editors.isEmpty)
        #expect(app.notice?.title == "Unsaved Changes Discarded")
        #expect(app.notice?.message.contains("Sample Office e-mail autofill (migrated)") == true)
    }

    @Test func discardAndSwitchDoesNotReportTheEditsAgain() throws {
        let (app, editor) = try makeApp(Self.silentServer())
        try edit(editor)

        #expect(app.chooseConnection(otherProfile.id, from: .mainWindow))
        app.confirmConnectionSwitch()

        #expect(app.editors.isEmpty)
        #expect(app.notice == nil)
    }

    // MARK: Quit (finding 6)

    @Test func quitAsksOnlyWithUnsavedEdits() throws {
        let (app, editor) = try makeApp(Self.silentServer())
        #expect(app.quitQuestion == nil)
        try edit(editor)
        #expect(app.quitQuestion?.quitButton == "Discard and Quit")
        #expect(app.quitQuestion?.message.contains("Sample Office e-mail autofill (migrated)") == true)
    }

    // MARK: Import (findings 7, 15)

    @Test func importingAModeTheDomainLacksAddsAnEntry() throws {
        let (app, editor) = try makeApp(Self.silentServer())
        let setting = [PlistNode(key: "Once", value: .boolean(true))]

        let result = editor.importDomains([ImportedDomain(name: "com.microsoft.office", mode: "Set-Once", settings: setting)], near: nil)

        #expect(result.replaced == 1 && result.added == 0)
        let entries = try #require(editor.document.payloads[0].domains.first?.entries)
        #expect(entries.map(\.mode) == ["Forced", "Set-Once"], "the Forced entry is kept")
        #expect(entries[0].settings.map(\.key) == ["OfficeAutoSignIn", "OfficeActivationEmailAddress"])
        #expect(entries[1].settings == setting)
        withExtendedLifetime(app) {}
    }

    @Test func replacingSettingsFromAFileForAnotherDomainAsksFirst() {
        let same = ImportedDomain(name: "com.example.app", mode: "Set-Once", settings: [])
        let sameForced = ImportedDomain(name: "com.example.app", mode: "Forced", settings: [])
        let other = ImportedDomain(name: "com.example.other", mode: "Forced", settings: [])

        #expect(PlistImporter.settingsMatch(forDomain: "com.example.app", mode: "Forced", in: [other, same, sameForced]) == .sameDomain(sameForced))
        #expect(PlistImporter.settingsMatch(forDomain: "com.example.app", mode: "Often", in: [other, same]) == .sameDomain(same))
        #expect(PlistImporter.settingsMatch(forDomain: "com.example.app", mode: "Forced", in: [other]) == .otherDomain(other))
        #expect(PlistImporter.settingsMatch(forDomain: "com.example.app", mode: "Forced", in: []) == .none)
    }

    @Test func importSummariesUseRealPlurals() {
        let one = EditorModel.ImportResult(added: 1, replaced: 0).summary(fileName: "a.plist")
        #expect(one.title == "Imported")
        #expect(one.message == "Imported from a.plist: 1 domain added. Use Undo to revert.")
        let more = EditorModel.ImportResult(added: 2, replaced: 3, skipped: ["x"]).summary(fileName: "b.mobileconfig")
        #expect(more.message.hasPrefix("Imported from b.mobileconfig: 2 domains added, 3 domains updated."))
        #expect(more.message.contains("“x” has an unexpected shape and is read-only"))
        #expect(EditorModel.ImportResult().summary(fileName: "c.plist").message == "c.plist matches the current settings; nothing changed.")
    }

    // MARK: Payload outside the steps (finding 8)

    @Test func aPayloadOutsideTheStepsIsReadOnly() throws {
        let json = #"{"id":"0a1b2c3d-4444-4444-8444-0123456789ab","name":"Elsewhere","updated":"2026-01-02T09:31:00.222222Z","steps":[],"extra":{"payloadType":"com.apple.ManagedClient.preferences","PayloadContent":{"com.example.app":{"Forced":[{"mcx_preference_settings":{"A":true}}]}}}}"#
        let (app, editor) = try makeApp(Self.silentServer(), json: json)
        let payload = try #require(editor.document.payloads.first)
        #expect(!payload.isEditable)
        let domain = try #require(payload.domains.first)
        #expect(domain.name == "com.example.app", "still shown")
        #expect(!editor.canEdit(domainID: domain.id))
        let entry = try #require(domain.entries?.first)
        #expect(!editor.modifySettings("Edit", domainID: domain.id, entryID: entry.id) { $0.removeAll() })
        #expect(editor.addDomain(name: "com.example.new") == nil, "no editable payload to add to")
        withExtendedLifetime(app) {}
    }

    // MARK: Save & Deploy step by step (finding 9)

    @Test func aFailedDeployAfterASaveSaysTheSaveWorked() async throws {
        let server = MockServer { request in
            switch (request.method, request.path) {
            case ("POST", "/auth/token"): Self.token
            case ("GET", Self.blueprintPath): .json(200, emailBlueprintJSON)
            case ("PATCH", Self.blueprintPath): Self.noContent
            default: .json(400, #"{"httpStatus":400,"errors":[{"code":"INVALID"}]}"#)
            }
        }
        let (app, editor) = try makeApp(server)
        try edit(editor)

        await editor.save(andDeploy: true)

        #expect(methods(server) == ["GET", "PATCH", "GET", "POST"])
        #expect(editor.alert?.title == "Saved, Deploy Failed")
        #expect(editor.alert?.message.contains("was saved") == true)
        #expect(!editor.isDirty)
        withExtendedLifetime(app) {}
    }

    @Test func aFailedReloadAfterASaveSkipsTheDeployAndKeepsTheSaveAsSaved() async throws {
        let script = ServerScript()
        let server = MockServer { request in
            switch (request.method, request.path) {
            case ("POST", "/auth/token"): return Self.token
            case ("GET", Self.blueprintPath):
                return script.count("GET") == 1 ? .json(200, emailBlueprintJSON) : Self.notFound
            case ("PATCH", Self.blueprintPath): return Self.noContent
            default: return .json(500, "{}")
            }
        }
        let (app, editor) = try makeApp(server)
        try edit(editor)

        await editor.save(andDeploy: true)

        #expect(methods(server) == ["GET", "PATCH", "GET"], "no deploy")
        #expect(editor.alert?.title == "Saved, Reload Failed")
        #expect(editor.alert?.message.contains("wasn’t deployed") == true)
        #expect(!editor.isDirty, "the saved edits don't look unsaved")
        let value = editor.document.payloads[0].domains.first?.entries?.first?.settings.first { $0.key == "OfficeAutoSignIn" }?.value
        #expect(value == .boolean(false))
        withExtendedLifetime(app) {}
    }

    /// 409 DIVISION_PATCH_NOT_ALLOWED on a save makes the Blueprint read-only.
    @Test func aDivisionRefusalOnSaveMakesTheBlueprintReadOnly() async throws {
        let server = MockServer { request in
            switch (request.method, request.path) {
            case ("POST", "/auth/token"): Self.token
            case ("GET", Self.blueprintPath): .json(200, emailBlueprintJSON)
            default: .json(409, #"{"httpStatus":409,"errors":[{"code":"DIVISION_PATCH_NOT_ALLOWED"}]}"#)
            }
        }
        let (app, editor) = try makeApp(server)
        try edit(editor)

        await editor.save(andDeploy: false)

        #expect(editor.alert?.title == "Blueprint Is Read-Only")
        #expect(app.isReadOnly(Self.blueprintID))
        #expect(!editor.canEdit)
        #expect(editor.isDirty, "the edits are kept")
    }

    // MARK: Restore

    @Test func restoreRefusesAChangedBlueprintAndABackupOfAnotherOne() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? Self.token : .json(200, Self.changedJSON)
        }
        let (app, editor) = try makeApp(server)
        let own = try BackupStore.write(editor.base, root: backupRoot)

        await editor.restore(from: BlueprintBackup(url: own, blueprintID: Self.blueprintID, date: Date(), size: 0))
        #expect(editor.alert?.kind == .conflict)
        #expect(editor.alert?.message.contains("Nothing was changed.") == true)
        #expect(!methods(server).contains("PATCH"))

        editor.alert = nil
        let foreign = try BackupStore.write(try JamfPlatform.BlueprintDetail(data: Data(rosettaBlueprintJSON.utf8)), root: backupRoot)
        await editor.restore(from: BlueprintBackup(url: foreign, blueprintID: Self.blueprintID, date: Date(), size: 0))
        #expect(editor.alert?.title == "Restore Failed")
        #expect(!methods(server).contains("PATCH"))
        withExtendedLifetime(app) {}
    }

    @Test func restoreReplacesUnsavedEdits() async throws {
        let server = MockServer { request in
            switch (request.method, request.path) {
            case ("POST", "/auth/token"): Self.token
            case ("GET", Self.blueprintPath): .json(200, emailBlueprintJSON)
            case ("PATCH", Self.blueprintPath): Self.noContent
            default: .json(500, "{}")
            }
        }
        let (app, editor) = try makeApp(server)
        let backup = try BackupStore.write(editor.base, root: backupRoot)
        try edit(editor)

        await editor.restore(from: BlueprintBackup(url: backup, blueprintID: Self.blueprintID, date: Date(), size: 0))

        #expect(editor.alert?.title == "Restored")
        #expect(!editor.isDirty)
        #expect(BackupStore.backups(for: Self.blueprintID, root: backupRoot).count == 2, "a fresh backup first")
        withExtendedLifetime(app) {}
    }

    // MARK: Discovery

    @Test func refreshKeepsDirtyEditorsAndDropsOthersThatAreGone() async throws {
        let server = MockServer { request in
            switch request.path {
            case "/auth/token": Self.token
            case "/blueprints/v1/blueprints": .json(200, #"{"totalCount":0,"results":[]}"#)
            default: .json(500, "{}")
            }
        }
        let (app, dirty) = try makeApp(server)
        app.store(try JamfPlatform.BlueprintDetail(data: Data(rosettaBlueprintJSON.utf8)))
        let clean = try #require(app.editors["0a1b2c3d-3333-4333-8333-0123456789ab"])
        try edit(dirty)

        app.refresh()
        await waitUntil { if case .finished = app.discoveryState { true } else { false } }

        #expect(app.editors.keys.sorted() == [Self.blueprintID], "only the dirty one stays")
        #expect(app.overviews.map(\.id) == [Self.blueprintID])
        #expect(clean.undoManager == nil, "the dropped editor's undo history is detached")
    }

    // MARK: Backups (finding 12)

    @Test func aBackupFolderNeverLeavesTheBackupsFolder() {
        let root = URL(filePath: "/tmp/Backups", directoryHint: .isDirectory)
        for id in ["..", ".", "", "../x", "a/../../b"] {
            let directory = BackupStore.directory(for: id, root: root)
            #expect(directory.deletingLastPathComponent().standardizedFileURL.path() == root.standardizedFileURL.path(), "\(id)")
            #expect(directory.standardizedFileURL.path().hasPrefix(root.path()), "\(id)")
        }
        #expect(BackupStore.directory(for: Self.blueprintID, root: root).lastPathComponent == Self.blueprintID)
    }
}
