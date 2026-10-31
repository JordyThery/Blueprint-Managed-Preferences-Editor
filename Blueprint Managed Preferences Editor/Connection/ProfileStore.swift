import Foundation
import JTKit
import Observation
import os

/// The saved connection profiles and the active one. JTKit's `ConnectionStore`
/// keeps the profiles (without secrets) under the UserDefaults key
/// `connectionProfiles`, and their client secrets in the login Keychain
/// (service `Blueprint Managed Preferences Editor.client-secret`, account =
/// profile UUID). The active profile is saved under
/// `selectedConnectionProfileID`. Never rename these: saved connections and
/// secrets are keyed by them.
@Observable
final class ProfileStore {
    static let profilesKey = "connectionProfiles"
    static let selectedKey = "selectedConnectionProfileID"

    let connections: ConnectionStore<ConnectionProfile>
    @ObservationIgnored private let defaults: UserDefaults

    var selectedProfileID: UUID? {
        didSet { defaults.set(selectedProfileID?.uuidString, forKey: Self.selectedKey) }
    }

    /// - Parameters:
    ///   - defaults: where the profiles and the active one are saved.
    ///   - secrets: where client secrets are kept; the app's Keychain items by default.
    init(defaults: UserDefaults = .standard, secrets: any SecretStore = ProfileStore.keychain) {
        self.defaults = defaults
        let logger = Self.logger
        connections = ConnectionStore(
            storage: UserDefaultsConnectionStorage(key: Self.profilesKey, defaults: defaults),
            secrets: [.main: SecretLocation(store: secrets)],
            log: { logger.error("\($0, privacy: .public)") }
        )
        let storedSelection = defaults.string(forKey: Self.selectedKey).flatMap(UUID.init)
        // A stored selection that no longer matches a profile would read as "no connection".
        if let storedSelection, connections.record(id: storedSelection) != nil {
            selectedProfileID = storedSelection
        } else {
            selectedProfileID = connections.records.first?.id
        }
    }

    /// The client secrets. Never rename: saved secrets are keyed by these.
    nonisolated static let keychain = KeychainSecretStore(
        service: "Blueprint Managed Preferences Editor.client-secret",
        label: "Blueprint Managed Preferences Editor client secret",
        log: { logger.error("\($0, privacy: .public)") }
    )

    private nonisolated static let logger = Logger(subsystem: "be.jordythery.blueprint-managed-preferences-editor", category: "connections")

    var profiles: [ConnectionProfile] { connections.records }

    var selectedProfile: ConnectionProfile? {
        selectedProfileID.flatMap(connections.record(id:))
    }

    /// A new profile for + in Settings › Connections. It doesn't change the
    /// active profile: it becomes active only once it's saved complete (see
    /// `profilesDidChange()`), so Revert leaves the selection as it was.
    func newProfile() -> ConnectionProfile {
        ConnectionProfile.newProfile()
    }

    /// After the saved profiles changed in Settings: when no profile is
    /// active, the first complete one (Environment ID and client ID filled
    /// in and saved) becomes active.
    func profilesDidChange() {
        guard selectedProfile == nil, let complete = profiles.first(where: \.isComplete) else { return }
        selectedProfileID = complete.id
    }

    /// After a profile was deleted in Settings: when it was the active one, the
    /// first remaining profile becomes active.
    func profileWasDeleted() {
        if selectedProfile == nil { selectedProfileID = profiles.first?.id }
    }

    /// The stored client secret, or nil when there is none or the Keychain
    /// can't be read (the error code goes to the log).
    func secret(for profile: ConnectionProfile) -> String? {
        connections.secret(for: profile.connection)
    }

    /// Nil when the profile is incomplete or has no stored secret.
    func credentials(for profile: ConnectionProfile) -> PlatformCredentials? {
        guard profile.isComplete, let secret = secret(for: profile), !secret.isEmpty else {
            return nil
        }
        return PlatformCredentials(profile: profile, secret: secret)
    }
}

nonisolated extension PlatformCredentials {
    /// The profile's values and a secret, with surrounding spaces removed.
    init(profile: ConnectionProfile, secret: String) {
        self.init(
            region: profile.region,
            environmentID: profile.environmentID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientID: profile.clientID.trimmingCharacters(in: .whitespacesAndNewlines),
            clientSecret: secret.trimmingCharacters(in: .whitespacesAndNewlines),
            connectionName: profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
