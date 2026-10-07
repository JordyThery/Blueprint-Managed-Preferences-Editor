import Foundation

/// A lossless JSON tree.
///
/// Unlike `JSONSerialization` or `Codable`, this type preserves
/// - object key order,
/// - the exact literal text of numbers (`1.0` stays `1.0`, big integers keep every digit),
/// - duplicate keys (never expected, but never silently dropped).
///
/// This lets the app round-trip parts of a blueprint it does not understand and
/// re-serialize them byte-for-byte, which is required because merge-patch replaces
/// the whole `steps` array.
nonisolated enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// A JSON number stored as its literal text.
nonisolated struct JSONNumber: Hashable, Sendable {
    let literal: String

    /// Creates a number from literal text that has already been validated by the parser.
    init(literal: String) {
        self.literal = literal
    }

    init(_ value: Int) {
        literal = String(value)
    }

    /// Returns nil for non-finite values, which JSON cannot represent.
    init?(_ value: Double) {
        guard value.isFinite else { return nil }
        literal = "\(value)"
    }

    var isInteger: Bool { !literal.contains { $0 == "." || $0 == "e" || $0 == "E" } }
    var intValue: Int? { Int(literal) }
    var doubleValue: Double? { Double(literal) }
}

/// An ordered JSON object.
nonisolated struct JSONObject: Hashable, Sendable {
    struct Member: Hashable, Sendable {
        var key: String
        var value: JSONValue
    }

    var members: [Member]

    init(_ members: [Member] = []) {
        self.members = members
    }

    init(_ pairs: KeyValuePairs<String, JSONValue>) {
        members = pairs.map { Member(key: $0.key, value: $0.value) }
    }

    var keys: [String] { members.map(\.key) }
    var isEmpty: Bool { members.isEmpty }
    var count: Int { members.count }

    /// Reading returns the first member with the key. Writing replaces it in place
    /// (keeping its position), appends a new member, or removes it when set to nil.
    subscript(key: String) -> JSONValue? {
        get { members.first { $0.key == key }?.value }
        set {
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    members[index].value = newValue
                } else {
                    members.remove(at: index)
                }
            } else if let newValue {
                members.append(Member(key: key, value: newValue))
            }
        }
    }
}

// MARK: - Convenience accessors

nonisolated extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: JSONNumber? {
        if case .number(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// A short, human-readable type name used in diagnostics and debug views.
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}

// MARK: - Paths

/// One step in a path through a JSON tree.
nonisolated enum JSONPathComponent: Hashable, Sendable, CustomStringConvertible {
    case key(String)
    case index(Int)

    var description: String {
        switch self {
        case .key(let key): ".\(key)"
        case .index(let index): "[\(index)]"
        }
    }
}

nonisolated extension Array where Element == JSONPathComponent {
    /// Renders a path like `steps[0].components[2].configuration`.
    var pathString: String {
        let joined = map(\.description).joined()
        return joined.hasPrefix(".") ? String(joined.dropFirst()) : joined
    }
}

nonisolated extension JSONValue {
    /// Returns the value at `path`, or nil if any component does not resolve.
    func value(at path: [JSONPathComponent]) -> JSONValue? {
        var current = self
        for component in path {
            switch component {
            case .key(let key):
                guard let next = current[key] else { return nil }
                current = next
            case .index(let index):
                guard let next = current[index] else { return nil }
                current = next
            }
        }
        return current
    }

    /// Replaces the value at `path`. Returns false (leaving `self` untouched) if the
    /// path does not resolve to an existing container. Object keys that don't exist
    /// yet are appended; array indices must already exist.
    @discardableResult
    mutating func setValue(_ newValue: JSONValue, at path: [JSONPathComponent]) -> Bool {
        guard let first = path.first else {
            self = newValue
            return true
        }
        let rest = Array(path.dropFirst())
        switch (self, first) {
        case (.object(var object), .key(let key)):
            var child = object[key] ?? .null
            if !rest.isEmpty && object[key] == nil { return false }
            guard child.setValue(newValue, at: rest) else { return false }
            object[key] = child
            self = .object(object)
            return true
        case (.array(var array), .index(let index)):
            guard array.indices.contains(index) else { return false }
            guard array[index].setValue(newValue, at: rest) else { return false }
            self = .array(array)
            return true
        default:
            return false
        }
    }

    /// Depth-first search for every object for which `predicate` returns true.
    /// Returns each match with its path from `self`.
    func findObjects(
        where predicate: (JSONObject) -> Bool
    ) -> [(path: [JSONPathComponent], object: JSONObject)] {
        var results: [(path: [JSONPathComponent], object: JSONObject)] = []
        func visit(_ value: JSONValue, path: [JSONPathComponent]) {
            switch value {
            case .object(let object):
                if predicate(object) { results.append((path, object)) }
                for member in object.members {
                    visit(member.value, path: path + [.key(member.key)])
                }
            case .array(let array):
                for (index, element) in array.enumerated() {
                    visit(element, path: path + [.index(index)])
                }
            default:
                break
            }
        }
        visit(self, path: [])
        return results
    }
}
