import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Blueprint_Managed_Preferences_Editor

/// Saving through the real editor and JTKit's client, against a fake server,
/// with a throwaway connection and backup folder.
@MainActor
@Suite("Saving")
final class SaveTests {
    private let suiteName = "be.jordythery.blueprint-managed-preferences-editor.tests.save-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let backupRoot = FileManager.default.temporaryDirectory.appending(path: "bmpe-save-\(UUID().uuidString)")
    nonisolated private static let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)
    nonisolated private static let blueprintID = "0a1b2c3d-2222-4222-8222-0123456789ab"
    nonisolated private static let blueprintPath = "/blueprints/v1/blueprints/\(blueprintID)"

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: backupRoot)
    }

    /// An app with one complete connection, talking to `server`, with `json` loaded.
    private func makeApp(_ server: MockServer, json: String = emailBlueprintJSON) throws -> (AppModel, EditorModel?) {
        let profileStore = ProfileStore(defaults: defaults, secrets: InMemorySecretStore())
        let profile = ConnectionProfile(name: "Test Tenant", region: .eu,
                                        environmentID: "5f1e2d3c-4b5a-4968-8776-655443322110", clientID: "id")
        try profileStore.connections.save(profile, secrets: [.main: "s3cr3t"])
        profileStore.selectedProfileID = profile.id
        let app = AppModel(profileStore: profileStore, session: server.session, backupRoot: backupRoot)
        let detail = try JamfPlatform.BlueprintDetail(data: Data(json.utf8))
        app.store(detail)
        return (app, app.editors[detail.id])
    }

    /// Sets `OfficeAutoSignIn` in the first of the two payloads to false.
    private func editFirstPayload(_ editor: EditorModel) throws {
        let domain = try #require(editor.document.payloads[0].domains.first)
        let entry = try #require(domain.entries?.first)
        let nodeID = try #require(entry.settings.first { $0.key == "OfficeAutoSignIn" }?.id)
        let changed = editor.modifySettings("Edit", domainID: domain.id, entryID: entry.id) { nodes in
            nodes.modifyNode(withID: nodeID) { $0.value = .boolean(false) }
        }
        #expect(changed)
        #expect(editor.isDirty)
    }

    private func apiRequests(_ server: MockServer) -> [RecordedRequest] {
        server.requests.filter { $0.path != "/auth/token" }
    }

    /// The exact text of the value at `path` in the fixture.
    private func text(at path: [LosslessJSON.PathComponent], in json: String) throws -> String {
        try #require(try LosslessJSON(string: json).value(at: path)).serializedString()
    }

    @Test func savingOneEditedPayloadSendsEverythingElseBackByteForByte() async throws {
        let server = MockServer { request in
            switch (request.method, request.path) {
            case ("POST", "/auth/token"): Self.token
            case ("GET", Self.blueprintPath): .json(200, emailBlueprintJSON)
            case ("PATCH", Self.blueprintPath): MockResponse(status: 204, body: Data())
            default: .json(500, "{}")
            }
        }
        let (app, editor) = try makeApp(server)
        let edited = try #require(editor)
        #expect(edited.document.payloads.count == 2)
        let firstPath = edited.document.payloads[0].path
        let secondPath = edited.document.payloads[1].path
        try editFirstPayload(edited)

        await edited.save(andDeploy: false)

        #expect(edited.alert?.title == "Saved")
        // Read to check nothing changed, save, read the new version.
        #expect(apiRequests(server).map(\.method) == ["GET", "PATCH", "GET"])
        let patch = try #require(apiRequests(server).first { $0.method == "PATCH" })
        #expect(patch.header("Content-Type") == "application/merge-patch+json")

        // Only the steps are sent: name, description, scope and division stay
        // on the server as they are.
        let body = try LosslessJSON(data: patch.body)
        #expect(body.objectValue?.keys == ["steps"])

        // The steps are the original bytes with only the first payload changed.
        let originalSteps = try text(at: [.key("steps")], in: emailBlueprintJSON)
        let firstPayload = try text(at: firstPath, in: emailBlueprintJSON)
        let secondPayload = try text(at: secondPath, in: emailBlueprintJSON)
        #expect(emailBlueprintJSON.contains(#""steps":"# + originalSteps))
        #expect(originalSteps.components(separatedBy: firstPayload).count == 2, "The first payload appears once")
        let editedFirstPayload = firstPayload.replacingOccurrences(of: #""OfficeAutoSignIn":true"#, with: #""OfficeAutoSignIn":false"#)
        #expect(editedFirstPayload != firstPayload)
        let expectedSteps = originalSteps.replacingOccurrences(of: firstPayload, with: editedFirstPayload)
        #expect(patch.bodyString == #"{"steps":"# + expectedSteps + "}")

        // Spelled out: everything around the first payload is unchanged, the
        // second payload included.
        let sent = String(patch.bodyString.dropFirst(#"{"steps":"#.count).dropLast())
        let range = try #require(originalSteps.range(of: firstPayload))
        #expect(sent.hasPrefix(String(originalSteps[..<range.lowerBound])))
        #expect(sent.hasSuffix(String(originalSteps[range.upperBound...])))
        #expect(sent.contains(secondPayload))

        // A backup of the Blueprint exactly as read before the save.
        let backups = BackupStore.backups(for: Self.blueprintID, root: backupRoot)
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: try #require(backups.first).url) == Data(emailBlueprintJSON.utf8))
        #expect(app.isReadOnly(Self.blueprintID) == false)
    }

    @Test func aBlueprintChangedOnTheServerIsNotSaved() async throws {
        let changed = emailBlueprintJSON.replacingOccurrences(of: "2026-01-02T09:31:00.222222Z", with: "2026-01-03T10:00:00.000000Z")
        #expect(changed != emailBlueprintJSON)
        let server = MockServer { request in
            request.path == "/auth/token" ? Self.token : .json(200, changed)
        }
        // The editor only borrows the app (`unowned`), so the test keeps it.
        let (app, editor) = try makeApp(server)
        let edited = try #require(editor)
        try editFirstPayload(edited)

        await edited.save(andDeploy: false)

        #expect(edited.alert?.kind == .conflict)
        #expect(apiRequests(server).map(\.method) == ["GET"])
        #expect(BackupStore.backups(for: Self.blueprintID, root: backupRoot).isEmpty)
        #expect(edited.isDirty, "The edits are kept")
        #expect(app.details[Self.blueprintID]?.overview.updated == "2026-01-02T09:31:00.222222Z", "The loaded copy is kept")
    }

    /// A Blueprint assigned to a division is read-only from the start.
    @Test func aDivisionLockedBlueprintIsReadOnlyFromTheStart() throws {
        let locked = emailBlueprintJSON.replacingOccurrences(of: #""scope":"#, with: #""divisionId":"d-1","scope":"#)
        let server = MockServer { _ in Issue.record("No request may be sent"); return .json(500, "{}") }
        let (app, editor) = try makeApp(server, json: locked)
        #expect(app.isReadOnly(Self.blueprintID))
        let edited = try #require(editor)
        #expect(!edited.canEdit)
        let domain = try #require(edited.document.payloads[0].domains.first)
        let entry = try #require(domain.entries?.first)
        #expect(!edited.modifySettings("Edit", domainID: domain.id, entryID: entry.id) { $0.removeAll() })
    }

    /// Test Connection names a missing read permission.
    @Test func testConnectionNamesAMissingReadPermission() async throws {
        let server = MockServer { request in
            request.path == "/auth/token" ? Self.token : .json(403, #"{"httpStatus":403,"errors":[{"code":"BAD_PERMISSIONS"}]}"#)
        }
        let (app, _) = try makeApp(server)
        let profile = try #require(app.profileStore.selectedProfile)
        do {
            _ = try await app.testConnection(profile, typedSecret: nil)
            Issue.record("Expected a missing permission")
        } catch let problem as JamfPlatform.PermissionProblem {
            #expect(problem.missing.map(\.permission) == ["blueprints:read"])
            #expect(problem.localizedDescription.contains("blueprints:read"))
        }
    }
}
