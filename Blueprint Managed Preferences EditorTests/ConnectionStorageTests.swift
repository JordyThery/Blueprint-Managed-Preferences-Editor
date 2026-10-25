import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Blueprint_Managed_Preferences_Editor

/// Saved connections made by earlier versions keep working with JTKit's store.
@MainActor
@Suite("Saved connections", .serialized)
final class ConnectionStorageTests {
    private let defaults: UserDefaults
    /// One throwaway settings file for the whole suite, emptied around every test.
    private let suiteName = "be.jordythery.blueprint-managed-preferences-editor.tests.connections"
    private let secrets = InMemorySecretStore()

    private let first = UUID(uuidString: "ADE57996-82F0-43F1-A2F0-57D462ADFA34")!
    private let second = UUID(uuidString: "42B1F00D-0000-4000-8000-000000000002")!

    init() {
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The list as earlier versions saved it: `JSONEncoder()` with no options.
    private func saveTheOldWay(_ profiles: [ConnectionProfile]) throws {
        defaults.set(try JSONEncoder().encode(profiles), forKey: "connectionProfiles")
    }

    private var oldProfiles: [ConnectionProfile] {
        [ConnectionProfile(id: first, name: "Production", region: .eu,
                           environmentID: "e77c1408-10c8-4007-b177-abc9157fbcaa", clientID: "client-1"),
         ConnectionProfile(id: second, name: "Test", region: .us, environmentID: "", clientID: "")]
    }

    @Test func profilesSavedByEarlierVersionsLoadWithTheirActiveChoice() throws {
        try saveTheOldWay(oldProfiles)
        defaults.set(second.uuidString, forKey: "selectedConnectionProfileID")

        let store = ProfileStore(defaults: defaults, secrets: secrets)

        #expect(store.profiles == oldProfiles)
        #expect(store.selectedProfileID == second)
        #expect(store.connections.problem == nil)
    }

    @Test func aStaleActiveChoiceFallsBackToTheFirstProfile() throws {
        try saveTheOldWay(oldProfiles)
        defaults.set(UUID().uuidString, forKey: "selectedConnectionProfileID")

        #expect(ProfileStore(defaults: defaults, secrets: secrets).selectedProfileID == first)
    }

    @Test func savingKeepsTheKeyAndFieldNamesAndBacksUpOnce() throws {
        try saveTheOldWay(oldProfiles)
        let original = try #require(defaults.data(forKey: "connectionProfiles"))
        let store = ProfileStore(defaults: defaults, secrets: secrets)

        var renamed = oldProfiles[0]
        renamed.connection.name = "Production EU"
        try store.connections.save(renamed)
        try store.connections.save(renamed)

        #expect(defaults.data(forKey: "connectionProfiles.backup") == original)
        let saved = try #require(defaults.data(forKey: "connectionProfiles"))
        let fields = try #require(try JSONSerialization.jsonObject(with: saved) as? [[String: Any]])
        #expect(Set(fields[0].keys) == ["id", "name", "region", "environmentID", "clientID"])
        #expect(try JSONDecoder().decode([ConnectionProfile].self, from: saved) == [renamed, oldProfiles[1]])
    }

    @Test func theConnectionMapsToAJamfPlatformConnectionAndBack() {
        var profile = oldProfiles[0]
        let connection = profile.connection
        #expect(connection.service == .jamfPlatform)
        #expect(connection.region == .eu)
        #expect(connection.environmentID == profile.environmentID)
        #expect(connection.clientID == "client-1")

        profile.connection = connection
        #expect(profile == oldProfiles[0])
    }

    @Test func secretsUseTheProfileIDAsAccount() throws {
        secrets.setSecret("old-secret", for: first.uuidString)
        try saveTheOldWay(oldProfiles)
        let store = ProfileStore(defaults: defaults, secrets: secrets)

        #expect(store.credentials(for: oldProfiles[0])?.clientSecret == "old-secret")

        try store.connections.save(oldProfiles[1], secrets: [.main: "new-secret"])
        #expect(secrets.all[second.uuidString] == "new-secret")
    }

    @Test func surroundingSpacesAreRemovedFromTheSecret() throws {
        secrets.setSecret(" old-secret\n", for: first.uuidString)
        try saveTheOldWay(oldProfiles)
        let store = ProfileStore(defaults: defaults, secrets: secrets)

        #expect(store.credentials(for: oldProfiles[0])?.clientSecret == "old-secret")
    }

    @Test func theKeychainItemsKeepTheirServiceAndLabel() {
        #expect(ProfileStore.keychain.service == "Blueprint Managed Preferences Editor.client-secret")
        #expect(ProfileStore.keychain.label == "Blueprint Managed Preferences Editor client secret")
    }

    @Test func theFirstNewProfileBecomesActive() throws {
        let store = ProfileStore(defaults: defaults, secrets: secrets)
        let profile = store.newProfile()
        try store.connections.save(profile)

        #expect(store.selectedProfile == profile)
        #expect(defaults.string(forKey: "selectedConnectionProfileID") == profile.id.uuidString)
    }

    @Test func deletingTheActiveProfileMakesTheFirstRemainingOneActive() throws {
        try saveTheOldWay(oldProfiles)
        secrets.setSecret("old-secret", for: first.uuidString)
        let store = ProfileStore(defaults: defaults, secrets: secrets)

        try store.connections.delete(id: first)
        store.selectedProfileID = nil // what the Connections tab does for the deleted one
        store.profileWasDeleted()

        #expect(store.selectedProfileID == second)
        #expect(secrets.all[first.uuidString] == nil)
    }

    @Test func anUnreadableListIsKeptAndNotSavedOver() throws {
        defaults.set(Data("not json".utf8), forKey: "connectionProfiles")
        let store = ProfileStore(defaults: defaults, secrets: secrets)

        #expect(store.connections.problem != nil)
        #expect(throws: (any Error).self) { try store.connections.save(ConnectionProfile.newProfile()) }
        #expect(defaults.data(forKey: "connectionProfiles") == Data("not json".utf8))
    }

    @Test func theMenuShowsTheNameAndRegion() {
        #expect(oldProfiles[0].menuTitle == "Production (eu)")
    }
}
