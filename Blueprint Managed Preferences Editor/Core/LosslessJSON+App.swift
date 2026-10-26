import Foundation
import JTKit

/// What this app needs from JTKit's `LosslessJSON` beyond what JTKit offers:
/// number conversions for plists, type names for warnings, and a tree search.

nonisolated extension LosslessJSON.Number {
    /// Returns nil for non-finite values, which JSON cannot represent.
    init?(_ value: Double) {
        guard value.isFinite else { return nil }
        self.init(literal: "\(value)")
    }

    var isInteger: Bool { !literal.contains { $0 == "." || $0 == "e" || $0 == "E" } }
    var doubleValue: Double? { Double(literal) }
}

nonisolated extension LosslessJSON {
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

    /// Depth-first search for every object for which `predicate` returns true.
    /// Returns each match with its path from `self`.
    func findObjects(
        where predicate: (Object) -> Bool
    ) -> [(path: [PathComponent], object: Object)] {
        var results: [(path: [PathComponent], object: Object)] = []
        func visit(_ value: LosslessJSON, path: [PathComponent]) {
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
