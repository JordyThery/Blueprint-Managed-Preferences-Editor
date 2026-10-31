import JTKit
import SwiftUI

/// The Connections tab of JTKit's Settings window (`SettingsWindow`), between
/// its General tab (Appearance) and its Updates tab: JTKit's shared list and
/// editor for the saved Jamf Platform API connections.
struct ConnectionsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let store = model.profileStore
        ConnectionsSettingsTab(
            store: store.connections,
            services: [.jamfPlatform],
            allowsChangingService: false,
            roles: [.active(selection: model.connectionSelection(from: .settings))],
            footer: "Requires an API client with blueprints:read, blueprints:update and blueprints:deploy. Load Environments lists the environments an organization-scope integration can see; otherwise copy the Environment ID from the integration’s details in Jamf Account. The client secret is stored in your login Keychain.",
            newRecord: { _ in store.newProfile() },
            didDelete: { _ in store.profileWasDeleted() },
            test: { profile, typed in try await model.testConnection(profile, typedSecret: typed[.main]) },
            environments: { profile, typed in try await model.environments(for: profile, typedSecret: typed[.main]) }
        )
        .confirmsConnectionSwitch(from: .settings)
        .onChange(of: store.profiles) { store.profilesDidChange() }
    }
}

extension AppModel {
    /// The read permission Test Connection checks. Write permissions can't be
    /// checked without writing, so they stay in the footer.
    static let readChecks: [JamfPlatform.PermissionCheck] = [.blueprintsRead]

    /// Test Connection in Settings: signs in, then checks that the Blueprint
    /// list can be read, with the editor's values, saved or not. A secret
    /// typed in the editor is used instead of the stored one.
    func testConnection(_ profile: ConnectionProfile, typedSecret: String?) async throws -> String {
        let secret = typedSecret ?? profileStore.secret(for: profile) ?? ""
        let client = try makeClient(credentials: PlatformCredentials(profile: profile, secret: secret))
        try await client.signIn()
        let results = await client.checkPermissions(Self.readChecks)
        if let problem = JamfPlatform.PermissionProblem(results) { throw problem }
        let page = try await JamfPlatform.Blueprints(client: client).listPage(page: 0, pageSize: 1)
        let count = page.totalCount.map { counted($0, "Blueprint") } ?? "Blueprints readable"
        return "Connected · \(count)"
    }

    /// Load Environments in Settings: the environments the editor's
    /// integration can see. No Environment ID is needed for this.
    func environments(for profile: ConnectionProfile, typedSecret: String?) async throws -> [JamfPlatform.Environment] {
        let secret = (typedSecret ?? profileStore.secret(for: profile) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials = PlatformCredentials(profile: profile, secret: secret)
        return try await JamfPlatform.environments(
            for: credentials.connection, secret: { secret },
            recorder: PlatformAPIClient.recorder(for: credentials, session: session, log: activityLog),
            permits: PlatformAPIClient.permits)
    }
}
