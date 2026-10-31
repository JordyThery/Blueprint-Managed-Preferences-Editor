import Foundation
import JTKit

/// MCX management modes.
nonisolated enum ManagementMode {
    static let forced = "Forced"
    static let all = ["Forced", "Set-Once", "Often"]
    static let settingsKey = "mcx_preference_settings"
}

/// One item of a domain's mode array:
/// `{ "mcx_preference_settings": { ... }, "mcx_data_timestamp": ... }`.
nonisolated struct MCXEntry: Identifiable, Hashable, Sendable {
    var id = UUID()
    var mode: String
    var settings: [PlistNode]
    /// The item as loaded. Keys other than `mcx_preference_settings` (such as
    /// `mcx_data_timestamp`) are written back unchanged and in their original order.
    var item: LosslessJSON.Object

    init(mode: String, settings: [PlistNode], item: LosslessJSON.Object = LosslessJSON.Object()) {
        self.mode = mode
        self.settings = settings
        self.item = item
    }

    var serializedItem: LosslessJSON.Object {
        var result = item
        result[ManagementMode.settingsKey] = .object(settings.jsonObject)
        return result
    }
}

/// A preference domain such as `com.microsoft.OneDrive`.
nonisolated struct PreferenceDomain: Identifiable, Hashable, Sendable {
    enum Content: Hashable, Sendable {
        /// The expected `{ mode: [ { mcx_preference_settings } ] }` shape, one entry per item.
        case entries([MCXEntry])
        /// Anything else: kept verbatim and shown read-only.
        case unsupported(LosslessJSON, reason: String)
    }

    var id = UUID()
    var name: String
    var content: Content

    var entries: [MCXEntry]? {
        if case .entries(let entries) = content { return entries }
        return nil
    }

    var isEditable: Bool { entries != nil }

    static func new(name: String, mode: String = ManagementMode.forced, settings: [PlistNode] = []) -> PreferenceDomain {
        PreferenceDomain(name: name, content: .entries([MCXEntry(mode: mode, settings: settings)]))
    }

    init(id: UUID = UUID(), name: String, content: Content) {
        self.id = id
        self.name = name
        self.content = content
    }

    /// Parses a domain value, falling back to `.unsupported` for unexpected shapes.
    init(name: String, json: LosslessJSON) {
        self.name = name
        guard let object = json.objectValue else {
            content = .unsupported(json, reason: "The domain value is a \(json.typeName), not an object of management modes.")
            return
        }
        // Duplicate keys would be merged on serialization; keep them verbatim instead.
        guard Set(object.keys).count == object.count else {
            content = .unsupported(json, reason: "The domain has duplicate management mode keys.")
            return
        }
        var entries: [MCXEntry] = []
        for member in object.members {
            guard let items = member.value.arrayValue else {
                content = .unsupported(json, reason: "Mode “\(member.key)” is a \(member.value.typeName), expected an array.")
                return
            }
            for item in items {
                guard let itemObject = item.objectValue,
                      let settings = itemObject[ManagementMode.settingsKey]?.objectValue else {
                    content = .unsupported(json, reason: "An item under “\(member.key)” has no \(ManagementMode.settingsKey) object.")
                    return
                }
                entries.append(MCXEntry(mode: member.key, settings: Array(jsonObject: settings), item: itemObject))
            }
        }
        if entries.isEmpty {
            content = .unsupported(json, reason: "The domain has no management mode entries.")
            return
        }
        content = .entries(entries)
    }

    /// Groups entries by mode, in order of first appearance.
    var json: LosslessJSON {
        switch content {
        case .unsupported(let raw, _):
            return raw
        case .entries(let entries):
            var object = LosslessJSON.Object()
            for entry in entries {
                var items = object[entry.mode]?.arrayValue ?? []
                items.append(.object(entry.serializedItem))
                object[entry.mode] = .array(items)
            }
            return .object(object)
        }
    }
}

/// An editable `com.apple.ManagedClient.preferences` payloadContent item.
nonisolated struct ManagedPreferencesPayload: Identifiable, Hashable, Sendable {
    /// Absolute path from the Blueprint root to the payloadContent item.
    let path: [LosslessJSON.PathComponent]
    /// The item as loaded; every key except `PayloadContent` is written back unchanged.
    let item: LosslessJSON.Object
    let displayName: String
    var domains: [PreferenceDomain]
    /// Set when the payload cannot be edited; it is then never modified.
    let problem: String?

    static let contentKey = "PayloadContent"

    var id: String { path.pathString }
    var isEditable: Bool { problem == nil }

    init(location: ManagedPreferencesPayloadLocation) {
        path = location.path
        item = location.payload
        displayName = location.payload["payloadDisplayName"]?.stringValue
            ?? location.payloadDisplayName
            ?? "Managed Preferences"
        if let content = location.payload[Self.contentKey]?.objectValue {
            domains = content.members.map { PreferenceDomain(name: $0.key, json: $0.value) }
            // Save sends only the steps array, so a payload elsewhere could never be saved.
            if case .key("steps") = location.path.first {
                problem = nil
            } else {
                problem = "Found outside the steps array, so it can’t be saved; shown read-only."
            }
        } else {
            domains = []
            problem = location.shapeWarnings.first ?? "PayloadContent is missing or not an object."
        }
    }

    var serializedItem: LosslessJSON.Object {
        var result = item
        result[Self.contentKey] = .object(LosslessJSON.Object(domains.map { .init(key: $0.name, value: $0.json) }))
        return result
    }
}

/// The editable state of one blueprint: the detail it was loaded from plus the
/// edited payloads. Everything outside the payloads' `PayloadContent` comes from
/// `base.json` untouched.
nonisolated struct BlueprintEditDocument: Sendable {
    let base: JamfPlatform.BlueprintDetail
    var payloads: [ManagedPreferencesPayload]

    init(detail: JamfPlatform.BlueprintDetail) {
        base = detail
        payloads = detail.managedPreferencePayloads.map(ManagedPreferencesPayload.init(location:))
    }

    /// The Blueprint JSON with each editable payload replaced at its path.
    var updatedBlueprintJSON: LosslessJSON {
        var json = base.json
        for payload in payloads where payload.isEditable {
            json.setValue(.object(payload.serializedItem), at: payload.path)
        }
        return json
    }

    /// The complete steps array to send. Merge-patch replaces arrays wholesale,
    /// so this always contains every step and component.
    var updatedSteps: LosslessJSON? { updatedBlueprintJSON["steps"] }

    var hasChanges: Bool { updatedSteps != base.steps }

    /// `{"steps": [...]}`. Never includes divisionId or any other field.
    var patchBody: Data? {
        guard let steps = updatedSteps else { return nil }
        return LosslessJSON.object(LosslessJSON.Object(["steps": steps])).serialized()
    }

    // MARK: Lookup and mutation helpers

    func domain(withID id: PreferenceDomain.ID) -> PreferenceDomain? {
        for payload in payloads {
            if let domain = payload.domains.first(where: { $0.id == id }) { return domain }
        }
        return nil
    }

    func payloadIndex(containing domainID: PreferenceDomain.ID) -> Int? {
        payloads.firstIndex { $0.domains.contains { $0.id == domainID } }
    }

    @discardableResult
    mutating func modifyDomain(withID id: PreferenceDomain.ID, _ body: (inout PreferenceDomain) -> Void) -> Bool {
        for payloadIndex in payloads.indices where payloads[payloadIndex].isEditable {
            if let domainIndex = payloads[payloadIndex].domains.firstIndex(where: { $0.id == id }) {
                body(&payloads[payloadIndex].domains[domainIndex])
                return true
            }
        }
        return false
    }

    /// Mutates one entry's settings tree.
    @discardableResult
    mutating func modifySettings(
        domainID: PreferenceDomain.ID,
        entryID: MCXEntry.ID,
        _ body: (inout [PlistNode]) -> Void
    ) -> Bool {
        var found = false
        modifyDomain(withID: domainID) { domain in
            guard case .entries(var entries) = domain.content,
                  let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
            body(&entries[index].settings)
            domain.content = .entries(entries)
            found = true
        }
        return found
    }

    // MARK: Diff

    /// Old/new values per domain and key path, for the review sheet.
    var changes: [PreferenceChange] {
        var result: [PreferenceChange] = []
        for payload in payloads where payload.isEditable {
            let oldContent = base.json.value(at: payload.path)?[ManagedPreferencesPayload.contentKey]?.objectValue ?? LosslessJSON.Object()
            let newContent = payload.serializedItem[ManagedPreferencesPayload.contentKey]?.objectValue ?? LosslessJSON.Object()
            result += PreferenceChange.diff(old: oldContent, new: newContent, payloadName: payload.displayName, payloadID: payload.id)
        }
        return result
    }
}

/// One line of the review diff.
nonisolated struct PreferenceChange: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable { case added, removed, changed }

    let payloadName: String
    /// The owning payload's location id, which keys changes uniquely even when
    /// several payloads share a display name.
    let payloadID: String
    let domain: String
    /// For example `Forced › KFMSilentOptIn` or `Forced › steps [2] › title`.
    let keyPath: String
    let kind: Kind
    let oldValue: String?
    let newValue: String?

    var id: String { "\(payloadID)|\(domain)|\(keyPath)" }

    /// Compares domain by domain. A name used twice is compared as its own
    /// domain ("name (2)"), and a change of order alone is listed too, so the
    /// review shows a change whenever Save would send one.
    static func diff(old: LosslessJSON.Object, new: LosslessJSON.Object, payloadName: String, payloadID: String) -> [PreferenceChange] {
        var result: [PreferenceChange] = []
        func change(_ domain: String, _ keyPath: String, _ kind: Kind, _ before: LosslessJSON?, _ after: LosslessJSON?) -> PreferenceChange {
            PreferenceChange(payloadName: payloadName, payloadID: payloadID, domain: domain, keyPath: keyPath, kind: kind,
                             oldValue: before?.serializedString(), newValue: after?.serializedString())
        }
        let oldDomains = labeledMembers(old)
        let newDomains = labeledMembers(new)
        let oldByName = Dictionary(oldDomains, uniquingKeysWith: { first, _ in first })
        let newByName = Dictionary(newDomains, uniquingKeysWith: { first, _ in first })
        for domain in orderedUnion(oldDomains.map(\.0), newDomains.map(\.0)) {
            let oldLeaves = flatten(oldByName[domain])
            let newLeaves = flatten(newByName[domain])
            let oldMap = Dictionary(oldLeaves.map { ($0.path, $0.value) }, uniquingKeysWith: { first, _ in first })
            let newMap = Dictionary(newLeaves.map { ($0.path, $0.value) }, uniquingKeysWith: { first, _ in first })
            let countBefore = result.count
            for path in orderedUnion(oldLeaves.map(\.path), newLeaves.map(\.path)) {
                let before = oldMap[path]
                let after = newMap[path]
                guard before != after else { continue }
                let kind: Kind = before == nil ? .added : (after == nil ? .removed : .changed)
                result.append(change(domain, path.isEmpty ? "(domain)" : path, kind, before, after))
            }
            // Same keys and values in another order (or an empty domain added or removed).
            if result.count == countBefore, oldByName[domain] != newByName[domain] {
                let kind: Kind = oldByName[domain] == nil ? .added : (newByName[domain] == nil ? .removed : .changed)
                result.append(change(domain, kind == .changed ? "(order of keys)" : "(domain)", kind, nil, nil))
            }
        }
        if result.isEmpty, old != new {
            result.append(change("(all domains)", "(order of domains)", .changed, nil, nil))
        }
        return result
    }

    /// The members of `object`, with a repeated name labeled "name (2)", "name (3)".
    private static func labeledMembers(_ object: LosslessJSON.Object) -> [(String, LosslessJSON)] {
        var seen: [String: Int] = [:]
        return object.members.map { member in
            seen[member.key, default: 0] += 1
            let count = seen[member.key] ?? 1
            return (count == 1 ? member.key : "\(member.key) (\(count))", member.value)
        }
    }

    /// Flattens to leaf values keyed by a readable path. The `mcx_preference_settings`
    /// level is hidden, and item indices are only shown when a mode has several items.
    private static func flatten(_ value: LosslessJSON?) -> [(path: String, value: LosslessJSON)] {
        guard let value else { return [] }
        var leaves: [(path: String, value: LosslessJSON)] = []
        func visit(_ value: LosslessJSON, _ components: [String]) {
            switch value {
            case .object(let object) where !object.isEmpty:
                for member in object.members {
                    let next = member.key == ManagementMode.settingsKey ? components : components + [member.key]
                    visit(member.value, next)
                }
            case .array(let array) where !array.isEmpty:
                // Mode arrays (directly under the domain) hold MCX items; hide the
                // index when there is a single item.
                let isModeArray = components.count == 1
                for (index, element) in array.enumerated() {
                    if isModeArray && array.count == 1 {
                        visit(element, components)
                    } else if let last = components.last {
                        visit(element, components.dropLast() + ["\(last) [\(index)]"])
                    } else {
                        visit(element, ["[\(index)]"])
                    }
                }
            default:
                leaves.append((components.joined(separator: " › "), value))
            }
        }
        visit(value, [])
        return leaves
    }

    private static func orderedUnion(_ first: [String], _ second: [String]) -> [String] {
        var seen = Set<String>()
        return (first + second).filter { seen.insert($0).inserted }
    }
}
