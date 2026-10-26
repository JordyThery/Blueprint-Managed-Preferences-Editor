import Foundation
import JTKit

/// The value types offered by the key/value editor.
nonisolated enum PlistType: String, CaseIterable, Identifiable, Sendable {
    case string = "String"
    case integer = "Integer"
    case real = "Real"
    case boolean = "Boolean"
    case date = "Date"
    case data = "Data"
    case array = "Array"
    case dictionary = "Dictionary"

    var id: String { rawValue }
    var isContainer: Bool { self == .array || self == .dictionary }
}

/// A property-list value as it travels in the Blueprints API JSON.
///
/// JSON has no Date or Data type, so those travel as ISO 8601 and Base64 strings.
/// They are only typed as `.date` / `.data` when the user chooses so; on load every
/// string is a `.string`. Numbers keep their literal text so unchanged values
/// round-trip exactly. `.null` only exists to preserve unexpected JSON nulls.
nonisolated enum PlistValue: Hashable, Sendable {
    case string(String)
    case integer(LosslessJSON.Number)
    case real(LosslessJSON.Number)
    case boolean(Bool)
    case date(String)
    case data(String)
    case array([PlistNode])
    case dictionary([PlistNode])
    case null

    var type: PlistType? {
        switch self {
        case .string: .string
        case .integer: .integer
        case .real: .real
        case .boolean: .boolean
        case .date: .date
        case .data: .data
        case .array: .array
        case .dictionary: .dictionary
        case .null: nil
        }
    }

    var children: [PlistNode]? {
        switch self {
        case .array(let nodes), .dictionary(let nodes): nodes
        default: nil
        }
    }

    /// Text shown in, and parsed from, the value column for scalar types.
    var editText: String {
        switch self {
        case .string(let text), .date(let text), .data(let text): text
        case .integer(let number), .real(let number): number.literal
        case .boolean(let value): value ? "true" : "false"
        case .array(let nodes), .dictionary(let nodes): "\(nodes.count) item\(nodes.count == 1 ? "" : "s")"
        case .null: "null"
        }
    }
}

/// One row of the key/value tree. Array elements have an empty, ignored key.
nonisolated struct PlistNode: Identifiable, Hashable, Sendable {
    var id = UUID()
    var key: String
    var value: PlistValue

    init(id: UUID = UUID(), key: String, value: PlistValue) {
        self.id = id
        self.key = key
        self.value = value
    }

    /// A deep copy with fresh identifiers throughout.
    func duplicated(key newKey: String? = nil) -> PlistNode {
        PlistNode(key: newKey ?? key, value: value.withFreshIDs())
    }
}

nonisolated extension PlistValue {
    func withFreshIDs() -> PlistValue {
        switch self {
        case .array(let nodes): .array(nodes.map { $0.duplicated() })
        case .dictionary(let nodes): .dictionary(nodes.map { $0.duplicated() })
        default: self
        }
    }
}

// MARK: - JSON conversion

nonisolated extension PlistValue {
    /// Infers Boolean, Integer, Real, String, Array and Dictionary from JSON.
    init(json: LosslessJSON) {
        switch json {
        case .null: self = .null
        case .bool(let value): self = .boolean(value)
        case .number(let number): self = number.isInteger ? .integer(number) : .real(number)
        case .string(let text): self = .string(text)
        case .array(let elements):
            self = .array(elements.map { PlistNode(key: "", value: PlistValue(json: $0)) })
        case .object(let object):
            self = .dictionary(object.members.map { PlistNode(key: $0.key, value: PlistValue(json: $0.value)) })
        }
    }

    var json: LosslessJSON {
        switch self {
        case .string(let text), .date(let text), .data(let text): .string(text)
        case .integer(let number), .real(let number): .number(number)
        case .boolean(let value): .bool(value)
        case .array(let nodes): .array(nodes.map(\.value.json))
        case .dictionary(let nodes): .object(LosslessJSON.Object(nodes.map { .init(key: $0.key, value: $0.value.json) }))
        case .null: .null
        }
    }
}

nonisolated extension Array where Element == PlistNode {
    /// Nodes of a dictionary from a JSON object, in order.
    init(jsonObject: LosslessJSON.Object) {
        self = jsonObject.members.map { PlistNode(key: $0.key, value: PlistValue(json: $0.value)) }
    }

    var jsonObject: LosslessJSON.Object {
        LosslessJSON.Object(map { .init(key: $0.key, value: $0.value.json) })
    }
}

// MARK: - Validation and type conversion

nonisolated struct PlistValidationError: Error, LocalizedError, Equatable, Sendable {
    let message: String
    var errorDescription: String? { message }
}

nonisolated enum PlistParsing {
    private static let integerPattern = /^-?[0-9]+$/
    private static let jsonNumberPattern = /^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$/

    /// Parses user-entered text for a scalar type, validating it.
    static func value(from text: String, as type: PlistType) -> Result<PlistValue, PlistValidationError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .string:
            return .success(.string(text))
        case .integer:
            guard trimmed.wholeMatch(of: integerPattern) != nil else {
                return .failure(PlistValidationError(message: "“\(text)” is not an integer."))
            }
            return .success(.integer(LosslessJSON.Number(literal: normalizedInteger(trimmed))))
        case .real:
            guard let double = Double(trimmed), double.isFinite else {
                return .failure(PlistValidationError(message: "“\(text)” is not a number."))
            }
            var literal = trimmed.wholeMatch(of: jsonNumberPattern) != nil ? trimmed : (LosslessJSON.Number(double)?.literal ?? "0.0")
            // Keep it a real on the next load: a literal without "." or exponent reads back as an integer.
            if !literal.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) { literal += ".0" }
            return .success(.real(LosslessJSON.Number(literal: literal)))
        case .boolean:
            switch trimmed.lowercased() {
            case "true", "yes", "1": return .success(.boolean(true))
            case "false", "no", "0": return .success(.boolean(false))
            default: return .failure(PlistValidationError(message: "Use true or false."))
            }
        case .date:
            guard JamfPlatform.date(from: trimmed) != nil else {
                return .failure(PlistValidationError(message: "“\(text)” is not an ISO 8601 date, for example 2026-01-31T09:00:00Z."))
            }
            return .success(.date(trimmed))
        case .data:
            let compact = text.filter { !$0.isWhitespace }
            guard Data(base64Encoded: compact) != nil else {
                return .failure(PlistValidationError(message: "Not valid Base64."))
            }
            return .success(.data(compact))
        case .array, .dictionary:
            return .failure(PlistValidationError(message: "Containers have no text value."))
        }
    }

    /// Strips leading zeros ("007" → "7", "-0" stays "-0").
    private static func normalizedInteger(_ text: String) -> String {
        let negative = text.hasPrefix("-")
        let digits = text.drop(while: { $0 == "-" }).drop(while: { $0 == "0" })
        let body = digits.isEmpty ? "0" : String(digits)
        return negative ? "-" + body : body
    }

    static func isoString(from date: Date) -> String {
        date.formatted(.iso8601)
    }
}

nonisolated extension PlistValue {
    /// Best-effort conversion when the user changes a value's type.
    func converted(to type: PlistType) -> PlistValue {
        if self.type == type { return self }
        switch type {
        case .string:
            return .string(children == nil && self != .null ? editText : "")
        case .integer:
            switch self {
            case .boolean(let value): return .integer(LosslessJSON.Number(value ? 1 : 0))
            case .real(let number):
                if let double = number.doubleValue, let int = Int(exactly: double.rounded(.towardZero)) {
                    return .integer(LosslessJSON.Number(int))
                }
                return .integer(LosslessJSON.Number(0))
            default:
                if case .success(let value) = PlistParsing.value(from: editText, as: .integer) { return value }
                return .integer(LosslessJSON.Number(0))
            }
        case .real:
            if case .boolean(let value) = self { return .real(LosslessJSON.Number(literal: value ? "1.0" : "0.0")) }
            if children == nil, case .success(let value) = PlistParsing.value(from: editText, as: .real) { return value }
            return .real(LosslessJSON.Number(literal: "0.0"))
        case .boolean:
            if children == nil, case .success(let value) = PlistParsing.value(from: editText, as: .boolean) { return value }
            if case .integer(let number) = self { return .boolean(number.intValue != 0) }
            return .boolean(false)
        case .date:
            if case .string(let text) = self, case .success(let value) = PlistParsing.value(from: text, as: .date) {
                return value
            }
            return .date(PlistParsing.isoString(from: Date()))
        case .data:
            if case .string(let text) = self, case .success(let value) = PlistParsing.value(from: text, as: .data) {
                return value
            }
            return .data("")
        case .array:
            if case .dictionary(let nodes) = self {
                return .array(nodes.map { PlistNode(id: $0.id, key: "", value: $0.value) })
            }
            return .array([])
        case .dictionary:
            if case .array(let nodes) = self {
                return .dictionary(nodes.enumerated().map { PlistNode(id: $1.id, key: "Item \($0)", value: $1.value) })
            }
            return .dictionary([])
        }
    }
}

// MARK: - Tree operations

/// Where a node sits in the tree.
nonisolated struct PlistNodeLocation: Equatable, Sendable {
    /// nil for the root dictionary.
    let parentID: UUID?
    let index: Int
}

nonisolated extension Array where Element == PlistNode {
    func node(withID id: UUID) -> PlistNode? {
        for node in self {
            if node.id == id { return node }
            if let found = node.value.children?.node(withID: id) { return found }
        }
        return nil
    }

    func location(of id: UUID, parentID: UUID? = nil) -> PlistNodeLocation? {
        for (index, node) in enumerated() {
            if node.id == id { return PlistNodeLocation(parentID: parentID, index: index) }
            if let children = node.value.children,
               let found = children.location(of: id, parentID: node.id) { return found }
        }
        return nil
    }

    /// Mutates the node with `id`. Returns false if not found.
    @discardableResult
    mutating func modifyNode(withID id: UUID, _ body: (inout PlistNode) -> Void) -> Bool {
        for index in indices {
            if self[index].id == id {
                body(&self[index])
                return true
            }
            switch self[index].value {
            case .array(var children):
                if children.modifyNode(withID: id, body) {
                    self[index].value = .array(children)
                    return true
                }
            case .dictionary(var children):
                if children.modifyNode(withID: id, body) {
                    self[index].value = .dictionary(children)
                    return true
                }
            default:
                break
            }
        }
        return false
    }

    /// Mutates the children of `parentID` (or the root when nil).
    /// The closure receives whether the container is an array.
    @discardableResult
    mutating func modifyChildren(of parentID: UUID?, _ body: (inout [PlistNode], Bool) -> Void) -> Bool {
        guard let parentID else {
            body(&self, false)
            return true
        }
        var handled = false
        modifyNode(withID: parentID) { parent in
            switch parent.value {
            case .array(var children):
                body(&children, true)
                parent.value = .array(children)
                handled = true
            case .dictionary(var children):
                body(&children, false)
                parent.value = .dictionary(children)
                handled = true
            default:
                break
            }
        }
        return handled
    }

    mutating func removeNodes(withIDs ids: Set<UUID>) {
        removeAll { ids.contains($0.id) }
        for index in indices {
            switch self[index].value {
            case .array(var children):
                children.removeNodes(withIDs: ids)
                self[index].value = .array(children)
            case .dictionary(var children):
                children.removeNodes(withIDs: ids)
                self[index].value = .dictionary(children)
            default:
                break
            }
        }
    }

    /// Moves a node up (-1) or down (+1) among its siblings.
    @discardableResult
    mutating func moveNode(withID id: UUID, by offset: Int) -> Bool {
        guard let location = location(of: id) else { return false }
        var moved = false
        modifyChildren(of: location.parentID) { siblings, _ in
            let target = location.index + offset
            guard siblings.indices.contains(target) else { return }
            siblings.swapAt(location.index, target)
            moved = true
        }
        return moved
    }

    /// Returns `base`, or `base 2`, `base 3`… so that it is unique among these nodes' keys.
    func uniqueKey(base: String) -> String {
        let keys = Set(map(\.key))
        guard keys.contains(base) else { return base }
        var counter = 2
        while keys.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }
}
