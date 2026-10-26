import Foundation
import Testing
@testable import Blueprint_Managed_Preferences_Editor

@Suite("Backups")
struct BackupStoreTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "bmpe-backups-\(UUID().uuidString)")
    private let date = Date(timeIntervalSince1970: 1_792_740_000)

    @Test func writesExactBytes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try BlueprintDetail(data: Data(sampleBlueprintJSON.utf8))
        let url = try BackupStore.write(detail, date: date, root: root)
        #expect(try Data(contentsOf: url) == Data(sampleBlueprintJSON.utf8))
        #expect(url.deletingLastPathComponent().lastPathComponent == detail.id)
    }

    @Test func sameNameDoesNotOverwrite() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try BlueprintDetail(data: Data(sampleBlueprintJSON.utf8))
        let changedJSON = sampleBlueprintJSON.replacingOccurrences(of: "Microsoft AutoUpdate – Legacy", with: "Changed")
        let second = try BlueprintDetail(data: Data(changedJSON.utf8))
        let firstURL = try BackupStore.write(first, date: date, root: root)
        let secondURL = try BackupStore.write(second, date: date, root: root)
        #expect(firstURL != secondURL, "A second backup at the same instant replaced the first")
        #expect(try Data(contentsOf: firstURL) == Data(sampleBlueprintJSON.utf8))
        #expect(try Data(contentsOf: secondURL) == Data(changedJSON.utf8))
    }

    @Test func sameInstantBackupsListNewestFirst() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try BlueprintDetail(data: Data(sampleBlueprintJSON.utf8))
        // Ten backups in the same millisecond get "", "-2" … "-10"; one a second later is newest.
        let sameInstant = try (1...10).map { _ in try BackupStore.write(detail, date: date, root: root) }
        let later = try BackupStore.write(detail, date: date.addingTimeInterval(1), root: root)
        let listed = BackupStore.backups(for: detail.id, root: root).map { $0.url.lastPathComponent }
        let expected = ([later] + sameInstant.reversed()).map(\.lastPathComponent)
        #expect(listed == expected)
    }
}
