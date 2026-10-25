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
            footer: "Requires an API client with blueprints:read, blueprints:update and blueprints:deploy. The client secret is stored in your login Keychain.",
            newRecord: { _ in store.newProfile() },
            didDelete: { _ in store.profileWasDeleted() },
            test: { profile, typed in try await model.testConnection(profile, typedSecret: typed[.main]) }
        )
        .confirmsConnectionSwitch(from: .settings)
    }
}

extension AppModel {
    /// Test Connection in Settings: fetches a token, then calls
    /// GET /blueprints/v1/blueprints?page-size=1 with the editor's values,
    /// saved or not. A secret typed in the editor is used instead of the stored one.
    func testConnection(_ profile: ConnectionProfile, typedSecret: String?) async throws -> String {
        let secret = typedSecret ?? profileStore.secret(for: profile) ?? ""
        let client = makeClient(credentials: PlatformCredentials(profile: profile, secret: secret))
        try await client.refreshToken()
        let page = try await BlueprintService(client: client).listPage(page: 0, pageSize: 1)
        let count = page.totalCount.map { "\($0) blueprint\($0 == 1 ? "" : "s")" } ?? "blueprint list OK"
        return "Connected · \(count)"
    }
}
