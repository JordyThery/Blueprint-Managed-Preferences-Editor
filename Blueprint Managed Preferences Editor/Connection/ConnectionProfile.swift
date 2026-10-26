import Foundation
import JTKit

/// Jamf Platform API region.
nonisolated enum PlatformRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    case us
    case eu
    case apac

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .us: "United States (us)"
        case .eu: "Europe (eu)"
        case .apac: "Asia Pacific (apac)"
        }
    }

    /// `https://{region}.api.jamfcloud.com`
    var baseURL: URL {
        URL(string: "https://\(rawValue).api.jamfcloud.com")!
    }
}

/// A saved tenant connection. The client secret is NOT stored here: it lives in the
/// Keychain, keyed by `id`.
///
/// Saved under the UserDefaults key `connectionProfiles` with these field names;
/// keep them, or saved connections are lost.
nonisolated struct ConnectionProfile: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var region: PlatformRegion
    var environmentID: String
    var clientID: String

    static func newProfile() -> ConnectionProfile {
        ConnectionProfile(name: "New Connection", region: .us, environmentID: "", clientID: "")
    }

    /// The name in the toolbar picker and the Connection menu, e.g. "Production (eu)".
    var menuTitle: String {
        "\(ConnectionMenuText.name(of: connection)) (\(region.rawValue))"
    }

    var isComplete: Bool {
        !environmentID.trimmingCharacters(in: .whitespaces).isEmpty
            && !clientID.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Everything the API client needs to talk to one tenant.
nonisolated struct PlatformCredentials: Sendable, Equatable {
    var region: PlatformRegion
    var environmentID: String
    var clientID: String
    var clientSecret: String
    /// Shown with each entry in the activity log.
    var connectionName = ""
}

/// How JTKit's connections list and editor see a profile: a Jamf Platform API
/// connection. Only the name, region, Environment ID and client ID change.
nonisolated extension ConnectionProfile: ConnectionRecord {
    var connection: Connection {
        get {
            Connection(id: id, name: name, service: .jamfPlatform,
                       region: JamfRegion(rawValue: region.rawValue) ?? .us,
                       environmentID: environmentID, clientID: clientID)
        }
        set {
            name = newValue.name
            region = PlatformRegion(rawValue: newValue.region.rawValue) ?? region
            environmentID = newValue.environmentID
            clientID = newValue.clientID
        }
    }
}
