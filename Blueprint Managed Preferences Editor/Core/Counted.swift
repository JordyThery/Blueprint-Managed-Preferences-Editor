import Foundation

/// A count with its noun: "1 domain", "3 domains".
nonisolated func counted(_ count: Int, _ singular: String, plural: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : plural ?? singular + "s")"
}
