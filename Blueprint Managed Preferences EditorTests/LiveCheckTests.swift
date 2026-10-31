import Foundation
import JTKit
import JTKitLiveCheck
import JTKitTestSupport
import Testing
@testable import Blueprint_Managed_Preferences_Editor

// Live checks (JTKit ROADMAP step 11), run only by Scripts/release-check.sh,
// which switches them on (JTKIT_LIVE=1) and passes the credentials it read
// from the login Keychain. ⌘U skips them. The tenant is named by role only:
// jamf-test-a over the Jamf Platform API. Every request goes through
// JTKitLiveCheck's guarded network: creates only with the run's JTKTEST
// prefix, changes and deletes only of objects this run created.

private let live = LiveCheckRun.isEnabled

#if JTKIT_FAULT_BREAK_BUILD
// Set only by `release-check.sh --fault break-build`, to check that a broken
// build stops the release check before anything reaches a tenant.
#error("Build broken on purpose by the release check's --fault break-build")
#endif

/// The allow-listed tenant as the checks use it.
struct LiveTenant: Sendable {
    static let role = "jamf-test-a"
    static let service = AllowList.Service.jamfPlatform

    let entry: AllowList.Entry
    let credentials: PlatformCredentials
    /// JTKit's client without the app's allow-list, still on the guarded
    /// network: the test group and Blueprint, their removal and the reads
    /// that check the app's work. The app itself has no create or delete.
    let api: JamfPlatform.Client

    init(run: LiveCheckRun) throws {
        entry = try run.entry(role: Self.role, service: Self.service)
        let region = try #require(JamfRegion(rawValue: entry.region ?? ""))
        credentials = PlatformCredentials(
            region: region, environmentID: try #require(entry.environmentID),
            clientID: try run.credential(Self.role, "client-id"),
            clientSecret: try run.credential(Self.role, "client-secret"),
            connectionName: "Live check")
        let secret = credentials.clientSecret
        api = try JamfPlatform.Client(
            connection: credentials.connection, secret: { secret },
            recorder: RequestRecorder(session: run.network.session, log: nil, category: "Live check"))
    }

    var blueprints: JamfPlatform.Blueprints { JamfPlatform.Blueprints(client: api) }

    // MARK: The test device group

    /// An empty static computer group: never smart, never with members.
    func createEmptyStaticGroup(name: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name, "deviceType": "COMPUTER", "groupType": "STATIC", "members": [String](),
        ])
        let response = try await api.send(HTTPRequest(method: "POST", path: JamfPlatform.Client.deviceGroupsPath,
                                                      body: body, contentType: "application/json"))
        let created = try LosslessJSON(data: response.data)
        return try #require(created["id"]?.stringValue, "The group create returned no id")
    }

    /// The group as Jamf has it, and its member list's total.
    func group(id: String) async throws -> (group: JamfPlatform.DeviceGroup?, members: Int?) {
        let path = "\(JamfPlatform.Client.deviceGroupsPath)/\(JamfPlatform.pathSegment(id))"
        let group = JamfPlatform.DeviceGroup(json: try await api.json(path))
        let members = try await api.json(path + "/members")
        return (group, members["totalCount"]?.numberValue?.intValue ?? members["results"]?.arrayValue?.count)
    }

    func isEmptyStatic(_ state: (group: JamfPlatform.DeviceGroup?, members: Int?)) -> Bool {
        state.group?.groupType == .static && (state.group?.memberCount ?? 0) == 0 && state.members == 0
    }

    // MARK: Test objects

    /// Every Blueprint and device group named as a test object.
    func testObjects(_ run: LiveCheckRun) async throws -> [(resource: String, id: String, name: String)] {
        let blueprints = try await self.blueprints.list().filter { run.isSweepable($0.name) }
        let groups = try await api.deviceGroups().filter { run.isSweepable($0.name) }
        return blueprints.map { ("blueprints", $0.id, $0.name) } + groups.map { ("device-groups", $0.id, $0.name) }
    }

    func delete(resource: String, id: String) async throws {
        let path = resource == "blueprints"
            ? "\(JamfPlatform.Blueprints.path)/\(JamfPlatform.pathSegment(id))"
            : "\(JamfPlatform.Client.deviceGroupsPath)/\(JamfPlatform.pathSegment(id))"
        do {
            _ = try await api.send(HTTPRequest(method: "DELETE", path: path, repeating: .safe))
        } catch let error as JamfPlatform.APIError where error.status == 404 {
            // Not counted from the answer: JTKit's read-back marks it removed
            // only once the object is gone (Jamf can answer 404 for a group it
            // still lists); a leftover fails the run.
        }
    }

    /// Deletes a test group once no Blueprint uses it any more. Jamf removes a
    /// deleted Blueprint in the background, and until then refuses the
    /// group's delete with 422 HAS_DEPENDENCIES; only that answer is
    /// retried, for up to two minutes.
    func deleteGroupWhenFree(id: String) async throws {
        let deadline = Date().addingTimeInterval(120)
        while true {
            do {
                return try await delete(resource: "device-groups", id: id)
            } catch let error as JamfPlatform.APIError where error.status == 422 && error.hasDependencies && Date() < deadline {
                try await Task.sleep(for: .seconds(5))
            }
        }
    }

    /// Waits until a deleted Blueprint is gone (404), up to two minutes.
    func waitUntilBlueprintGone(id: String) async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            do {
                _ = try await blueprints.detail(id: id)
            } catch let error as JamfPlatform.APIError where error.status == 404 {
                return
            }
            try await Task.sleep(for: .seconds(3))
        }
    }
}

private extension JamfPlatform.APIError {
    var hasDependencies: Bool {
        body?.errors.contains { $0.code == "HAS_DEPENDENCIES" } == true
    }
}

// MARK: Stage 1: sign in

@MainActor
@Suite("Live: sign in", .enabled(if: live), .serialized)
struct LiveSignInTests {
    /// A sign-in and small reads (Blueprints and device groups), plus a count
    /// of left-over test objects (removed in stage 4). Reads only.
    @Test func signInAndRead() async throws {
        let run = try LiveCheckRun.current()
        do {
            let target = try LiveTenant(run: run)
            let leftovers = try await target.testObjects(run).count
            run.record(step: "sign in: \(LiveTenant.role)", passed: true, note: "\(leftovers) left-over test objects")
        } catch {
            run.record(step: "sign in: \(LiveTenant.role)", passed: false, note: String(describing: error))
            throw error
        }
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }
}

// MARK: Stage 4: the main task, live

@MainActor
@Suite("Live: create, edit, save, deploy, verify, remove", .enabled(if: live), .serialized)
struct LiveBlueprintTests {
    /// The test payload's preference domain and key: made up, so they match no real app.
    static let domain = "com.example.jtktest"
    static let key = "JTKTESTFlag"

    @Test func tenantA() async throws {
        let run = try LiveCheckRun.current()
        guard run.roles.contains(LiveTenant.role) else { return }
        let target = try LiveTenant(run: run)
        let ledgerTarget = try run.target(role: LiveTenant.role, service: LiveTenant.service)
        let step = { (name: String) in "\(LiveTenant.role): \(name)" }

        // The app as it runs, but with one in-memory connection to the test
        // tenant (never the saved connections or the Keychain), the guarded
        // network, and backups in a folder of this run's.
        let suiteName = "be.jordythery.blueprint-managed-preferences-editor.live-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let backups = FileManager.default.temporaryDirectory.appending(path: "bm-live-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: backups)
        }
        let profiles = ProfileStore(defaults: defaults, secrets: InMemorySecretStore())
        let profile = ConnectionProfile(name: "Live check", region: target.credentials.region,
                                        environmentID: target.credentials.environmentID, clientID: target.credentials.clientID)
        try profiles.connections.save(profile, secrets: [.main: target.credentials.clientSecret])
        profiles.selectedProfileID = profile.id
        let demo = DemoMode(key: AppModel.demoModeKey, defaults: defaults, arguments: [DemoMode.launchArgument, "NO"])
        let app = AppModel(profileStore: profiles, session: run.network.session, backupRoot: backups, demo: demo)

        // 1. An empty static test group, checked before anything is scoped to it.
        let groupID = try await target.createEmptyStaticGroup(name: "\(run.prefix) – Group")
        let group = try await target.group(id: groupID)
        run.record(step: step("create an empty static device group"), passed: target.isEmptyStatic(group),
                   note: "type \(group.group.map { $0.groupType.displayName } ?? "unknown"), \(group.group?.memberCount.map(String.init) ?? "?") members, member list \(group.members.map(String.init) ?? "?")")
        try #require(target.isEmptyStatic(group), "The test group isn't an empty static group; nothing is created or deployed")

        // 2. A test Blueprint with one Managed Preferences payload, made by
        //    the check: the app has no create.
        let blueprintID = try await target.blueprints.create(
            name: "\(run.prefix) – Blueprint", description: "Release check test object; removed after the run",
            deviceGroups: [groupID], steps: [try Self.step()])
        let created = try await target.blueprints.detail(id: blueprintID)
        let isFound = created.managedPreferencePayloads.count == 1
        run.record(step: step("create a Blueprint with one Managed Preferences payload"), passed: isFound,
                   note: "\(created.managedPreferencePayloads.count) payloads read back")
        try #require(isFound, "Jamf didn't keep the Managed Preferences payload")
        // Only with `release-check.sh --fault fail-live-step`: fails with
        // objects on the tenant, so cleanup has to remove them.
        try run.injectFault("fail-live-step", at: step("failure after creating objects"))

        // 3. Edit the key and save with the app's own editor: fetch again,
        //    check, back up, PATCH the complete steps, reload.
        try await app.fetchBlueprint(id: blueprintID)
        let editor = try #require(app.editors[blueprintID], "The app found no Managed Preferences in the test Blueprint")
        let preferenceDomain = try #require(editor.document.payloads.first?.domains.first { $0.name == Self.domain })
        let entry = try #require(preferenceDomain.entries?.first)
        let node = try #require(entry.settings.first { $0.key == Self.key })
        #expect(node.value == .boolean(false))
        let changed = editor.modifySettings("Edit", domainID: preferenceDomain.id, entryID: entry.id) { nodes in
            nodes.modifyNode(withID: node.id) { $0.value = .boolean(true) }
        }
        let payloadPath = editor.document.payloads[0].path
        await editor.save(andDeploy: false)
        let saved = changed && editor.alert?.title == "Saved" && !editor.isDirty
        let backedUp = BackupStore.backups(for: blueprintID, root: backups).count == 1
        #expect(saved && backedUp, "\(editor.alert?.title ?? "no alert"): \(editor.alert?.message ?? "")")
        run.record(step: step("edit the key and save with the app's editor"), passed: saved && backedUp,
                   note: editor.alert?.title)

        // 4. Read back: the key is true, and the steps are otherwise as read
        //    after the create (the rest of the payload included).
        let readBack = try await target.blueprints.detail(id: blueprintID)
        var expected = try #require(created.json["steps"])
        let keyPath = Array(payloadPath.dropFirst()) + [
            .key("PayloadContent"), .key(Self.domain), .key("Forced"), .index(0), .key("mcx_preference_settings"), .key(Self.key),
        ]
        #expect(expected.value(at: keyPath) == .bool(false))
        let isSet = expected.setValue(.bool(true), at: keyPath)
        #expect(isSet)
        let onlyKeyChanged = readBack.json["steps"] == expected
        let sameOutside = ["name", "description", "scope"].allSatisfy { readBack.json[$0] == created.json[$0] }
        #expect(onlyKeyChanged && sameOutside,
                "read back: \(readBack.json["steps"]?.serializedString() ?? "none")\nexpected: \(expected.serializedString())")
        run.record(step: step("read back: only the edited key changed"), passed: onlyKeyChanged && sameOutside)

        // 5. Deploy with the app's own Deploy, only while the group still has no members.
        let beforeDeploy = try await target.group(id: groupID)
        try #require(target.isEmptyStatic(beforeDeploy), "The test group has members now; not deploying")
        let previousStart = readBack.overview.deploymentState?.lastDeploymentStarted
        await editor.deploy()
        #expect(editor.alert?.title == "Deployment Started", "\(editor.alert?.title ?? "no alert"): \(editor.alert?.message ?? "")")
        let outcome = try await target.blueprints.watchDeployment(id: blueprintID, previousStart: previousStart)
        let deployed = outcome.isFinished && outcome.value?.didSucceed == true
        #expect(deployed, "deployment \(outcome.value?.jobState ?? "unknown")")
        let afterDeploy = try await target.blueprints.detail(id: blueprintID)
        let isDeployed = afterDeploy.overview.deploymentState?.state == .deployed
            && afterDeploy.json.value(at: [.key("steps")] + keyPath) == .bool(true)
        #expect(isDeployed, "state \(String(describing: afterDeploy.overview.deploymentState?.state))")
        run.record(step: step("deploy to the empty group with the app's Deploy"), passed: deployed && isDeployed,
                   note: outcome.value?.jobState)

        // 6. Remove the Blueprint, then the group.
        try await target.delete(resource: "blueprints", id: blueprintID)
        try await target.waitUntilBlueprintGone(id: blueprintID)
        try await target.deleteGroupWhenFree(id: groupID)
        let left = try await target.testObjects(run).filter { $0.id == blueprintID || $0.id == groupID }
        #expect(left.isEmpty, "still there: \(left.map(\.name))")
        run.record(step: step("remove the Blueprint and the group"), passed: left.isEmpty)
        #expect(run.ledger.outstanding.filter { $0.target == ledgerTarget }.isEmpty)
        #expect(run.network.refusals.isEmpty, "\(run.network.refusals)")
    }

    /// One step with a migrated-profile component holding one Managed
    /// Preferences payload (the shape Jamf gives a migrated Classic profile):
    /// a made-up domain with one key, false. Jamf requires real UUIDs as
    /// payload UUIDs (400 PATTERN otherwise).
    static func step() throws -> LosslessJSON {
        let payload = UUID().uuidString
        let configuration = UUID().uuidString
        return try LosslessJSON(string: #"{"name":"JTKTEST Managed Preferences","components":[{"identifier":"com.jamf.ddm-configuration-profile","configuration":{"payloadUUID":"\#(configuration)","payloadContent":[{"payloadType":"com.apple.ManagedClient.preferences","payloadUUID":"\#(payload)","PayloadContent":{"\#(domain)":{"Forced":[{"mcx_preference_settings":{"\#(key)":false}}]}},"payloadVersion":1,"payloadIdentifier":"com.example.jtktest.payload","payloadDisplayName":"JTKTEST Preferences"}],"payloadIdentifier":"com.example.jtktest.profile","payloadDisplayName":"JTKTEST Profile"}}],"activationPredicate":null}"#)
    }
}

// MARK: Cleanup (every exit of stage 4)

@MainActor
@Suite("Live: cleanup", .enabled(if: live), .serialized)
struct LiveCleanupTests {
    /// Deletes what the run's ledger still lists, then sweeps the tenant for
    /// anything still named as a test object. Blueprints go before groups (a
    /// group in a Blueprint's scope can't be removed). Fails if anything is left.
    @Test func removeTestObjects() async throws {
        let run = try LiveCheckRun.current()
        let temporary = FileManager.default.temporaryDirectory
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? [] where folder.hasPrefix("bm-live-") {
            try? FileManager.default.removeItem(at: temporary.appending(path: folder))
        }
        let target = try LiveTenant(run: run)
        let ledgerTarget = try run.target(role: LiveTenant.role, service: LiveTenant.service)
        for object in try await target.testObjects(run) {
            try run.adoptForSweep(role: LiveTenant.role, service: LiveTenant.service,
                                  resource: object.resource, id: object.id, name: object.name)
        }
        let outstanding = run.ledger.outstanding.filter { $0.target == ledgerTarget }
        for item in outstanding.filter({ $0.resource == "blueprints" }) + outstanding.filter({ $0.resource != "blueprints" }) {
            do {
                if item.resource == "blueprints" {
                    try await target.delete(resource: item.resource, id: item.id)
                } else {
                    try await target.deleteGroupWhenFree(id: item.id)
                }
            } catch {
                run.record(step: "cleanup: \(item.resource) \(item.id)", passed: false, note: String(describing: error))
            }
        }
        let left = run.ledger.outstanding
        run.record(step: "cleanup", passed: left.isEmpty, note: left.isEmpty ? nil : "\(left.count) not removed")
        #expect(left.isEmpty, "\(left.map { "\($0.resource) \($0.id) \($0.name)" })")
    }
}
