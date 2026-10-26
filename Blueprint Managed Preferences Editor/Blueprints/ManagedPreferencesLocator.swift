import Foundation
import JTKit

/// Where a `com.apple.ManagedClient.preferences` payload was found inside a blueprint.
nonisolated struct ManagedPreferencesPayloadLocation: Hashable, Sendable, Identifiable {
    /// Path from the blueprint root to the payloadContent item.
    let path: [LosslessJSON.PathComponent]
    /// The payloadContent item itself.
    let payload: LosslessJSON.Object
    /// `configuration.payloadDisplayName` of the owning component, if found.
    let payloadDisplayName: String?
    /// Top-level keys of the payload's `PayloadContent` object (the preference domains).
    /// Empty if `PayloadContent` is missing or not an object.
    let domains: [String]
    /// Human-readable notes about anything unexpected in the shape.
    let shapeWarnings: [String]

    var id: String { path.pathString }
}

/// Finds ManagedClient payloads without assuming the exact shape: it searches the whole
/// tree for objects whose `payloadType` is the ManagedClient type, then checks how
/// well each match fits the expected structure. It never throws on unknown shapes.
nonisolated enum ManagedPreferencesLocator {
    static let payloadType = "com.apple.ManagedClient.preferences"
    static let ddmComponentIdentifier = "com.jamf.ddm-configuration-profile"

    static func locate(in blueprint: LosslessJSON) -> [ManagedPreferencesPayloadLocation] {
        let matches = blueprint.findObjects { object in
            (object["payloadType"] ?? object["PayloadType"])?.stringValue == payloadType
        }
        return matches.map { match in
            describe(match.object, at: match.path, in: blueprint)
        }
    }

    private static func describe(
        _ payload: LosslessJSON.Object,
        at path: [LosslessJSON.PathComponent],
        in blueprint: LosslessJSON
    ) -> ManagedPreferencesPayloadLocation {
        var warnings: [String] = []

        // Expected: steps[i].components[j].configuration.payloadContent[k]
        var displayName: String?
        if path.count == 7,
           case .key("steps") = path[0], case .index = path[1],
           case .key("components") = path[2], case .index = path[3],
           case .key("configuration") = path[4],
           case .key("payloadContent") = path[5], case .index = path[6] {
            let component = blueprint.value(at: Array(path.prefix(4)))
            let componentIdentifier = component?["identifier"]?.stringValue
            displayName = component?["configuration"]?["payloadDisplayName"]?.stringValue
            if componentIdentifier != ddmComponentIdentifier {
                warnings.append("Owning component identifier is \"\(componentIdentifier ?? "missing")\", expected \"\(ddmComponentIdentifier)\".")
            }
        } else {
            warnings.append("Found at unexpected location \(path.pathString).")
        }

        if payload["payloadType"] == nil {
            warnings.append("Uses \"PayloadType\" rather than \"payloadType\".")
        }

        var domains: [String] = []
        let contentKey = payload["PayloadContent"] != nil ? "PayloadContent" : "payloadContent"
        switch payload[contentKey] {
        case .object(let content):
            domains = content.keys
            for member in content.members where member.value.objectValue == nil {
                warnings.append("Domain \"\(member.key)\" is a \(member.value.typeName), expected an object.")
            }
        case .some(let other):
            warnings.append("\(contentKey) is a \(other.typeName), expected an object keyed by preference domain.")
        case nil:
            warnings.append("No PayloadContent key. Keys present: \(payload.keys.joined(separator: ", ")).")
        }
        if contentKey == "payloadContent" && payload["payloadContent"] != nil {
            warnings.append("Uses \"payloadContent\" rather than \"PayloadContent\".")
        }

        return ManagedPreferencesPayloadLocation(
            path: path,
            payload: payload,
            payloadDisplayName: displayName,
            domains: domains,
            shapeWarnings: warnings
        )
    }
}
