import Foundation

/// `deploymentState.state` from the API. Unknown values are kept, not dropped.
nonisolated enum DeploymentStateKind: Hashable, Sendable {
    case notDeployed
    case deployed
    case outOfDate
    case other(String)

    init(rawValue: String) {
        switch rawValue {
        case "NOT_DEPLOYED": self = .notDeployed
        case "DEPLOYED": self = .deployed
        case "OUT_OF_DATE": self = .outOfDate
        default: self = .other(rawValue)
        }
    }

    var displayName: String {
        switch self {
        case .notDeployed: "Not Deployed"
        case .deployed: "Deployed"
        case .outOfDate: "Out of Date"
        case .other(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

nonisolated struct DeploymentState: Hashable, Sendable {
    var state: DeploymentStateKind
    var lastDeploymentStarted: String?
    var lastDeploymentState: String?

    init?(json: JSONValue?) {
        guard let json, let raw = json["state"]?.stringValue else { return nil }
        state = DeploymentStateKind(rawValue: raw)
        lastDeploymentStarted = json["lastDeployment"]?["started"]?.stringValue
        lastDeploymentState = json["lastDeployment"]?["state"]?.stringValue
    }
}

/// Fields shared by the list overview and the detail response. Parsed leniently:
/// only `id` is required.
nonisolated struct BlueprintOverview: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var description: String?
    /// Kept as the exact server string so optimistic-concurrency checks compare
    /// like with like.
    var created: String?
    var updated: String?
    var deploymentState: DeploymentState?

    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue else { return nil }
        self.id = id
        name = json["name"]?.stringValue ?? "(unnamed)"
        description = json["description"]?.stringValue
        created = json["created"]?.stringValue
        updated = json["updated"]?.stringValue
        deploymentState = DeploymentState(json: json["deploymentState"])
    }

    var updatedDate: Date? { updated.flatMap(PlatformDate.parse) }
    var createdDate: Date? { created.flatMap(PlatformDate.parse) }
}

/// A full blueprint as returned by GET /v1/blueprints/{id}.
///
/// The whole response is held as a lossless `JSONValue` so that anything the app
/// does not edit can be sent back exactly as it was received.
nonisolated struct BlueprintDetail: Identifiable, Sendable {
    let overview: BlueprintOverview
    /// The parsed response, used for edits and PATCH bodies.
    let json: JSONValue
    /// The exact response bytes, used for backups and the Raw JSON view.
    let rawData: Data
    let fetchedAt: Date
    let managedPreferencePayloads: [ManagedPreferencesPayloadLocation]

    var id: String { overview.id }
    var steps: JSONValue? { json["steps"] }
    var scope: JSONValue? { json["scope"] }

    init(data: Data, fetchedAt: Date = Date()) throws {
        let json = try JSONValue(data: data)
        guard let overview = BlueprintOverview(json: json) else {
            throw APIError.invalidResponse("The blueprint response has no \"id\".")
        }
        self.overview = overview
        self.json = json
        rawData = data
        self.fetchedAt = fetchedAt
        managedPreferencePayloads = ManagedPreferencesLocator.locate(in: json)
    }

    var containsManagedPreferences: Bool { !managedPreferencePayloads.isEmpty }

    /// Device group IDs from `scope.deviceGroups`.
    var scopeDeviceGroups: [String] {
        scope?["deviceGroups"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Human-readable scope for confirmations.
    var scopeDescription: String {
        let groups = scopeDeviceGroups
        guard !groups.isEmpty else { return "No device groups are in scope." }
        let shown = groups.prefix(5).joined(separator: "\n")
        let more = groups.count > 5 ? "\n…and \(groups.count - 5) more" : ""
        return "\(groups.count) device group\(groups.count == 1 ? "" : "s"):\n\(shown)\(more)"
    }

    /// All preference domains across every ManagedClient payload, in document order.
    var preferenceDomains: [String] {
        var seen = Set<String>()
        return managedPreferencePayloads.flatMap(\.domains).filter { seen.insert($0).inserted }
    }
}

/// Date parsing for the API's ISO 8601 timestamps, with or without fractional seconds.
nonisolated enum PlatformDate {
    static func parse(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return try? withFraction.parse(string)
    }
}
