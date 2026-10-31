import Foundation
import JTKit

/// This app's view of a Blueprint fetched with JTKit: its Managed Preferences
/// payloads and the scope text shown in confirmations.
nonisolated extension JamfPlatform.BlueprintDetail {
    /// Every `com.apple.ManagedClient.preferences` payload, found anew from the
    /// JSON. This walks the whole tree; `AppModel` keeps the domains per Blueprint.
    var managedPreferencePayloads: [ManagedPreferencesPayloadLocation] {
        ManagedPreferencesLocator.locate(in: json)
    }

    /// All preference domains across the payloads, in document order.
    static func domains(of payloads: [ManagedPreferencesPayloadLocation]) -> [String] {
        var seen = Set<String>()
        return payloads.flatMap(\.domains).filter { seen.insert($0).inserted }
    }

    /// Human-readable scope for confirmations.
    var scopeDescription: String {
        let groups = scopeDeviceGroups
        guard !groups.isEmpty else { return "No device groups are in scope." }
        let shown = groups.prefix(5).joined(separator: "\n")
        let more = groups.count > 5 ? "\n…and \(groups.count - 5) more" : ""
        return "\(groups.count) device group\(groups.count == 1 ? "" : "s"):\n\(shown)\(more)"
    }
}
