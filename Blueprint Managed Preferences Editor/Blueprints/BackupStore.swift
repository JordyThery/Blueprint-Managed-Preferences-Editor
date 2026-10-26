import Foundation
import JTKit

nonisolated struct BlueprintBackup: Identifiable, Hashable, Sendable {
    let url: URL
    let blueprintID: String
    let date: Date
    let size: Int

    var id: URL { url }
}

/// Writes the full JamfPlatform.BlueprintDetail JSON before every PATCH to
/// `~/Library/Application Support/Blueprint Managed Preferences Editor/Backups/<blueprintId>/<timestamp>.json`.
nonisolated enum BackupStore {
    struct BackupError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var rootURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Blueprint Managed Preferences Editor", directoryHint: .isDirectory)
            .appending(path: "Backups", directoryHint: .isDirectory)
    }

    static func directory(for blueprintID: String, root: URL = rootURL) -> URL {
        let safe = blueprintID.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return root.appending(path: safe, directoryHint: .isDirectory)
    }

    /// File names sort chronologically and contain no colons: `2026-10-07T14-03-11.123Z.json`.
    private static let fileNameFormat = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)T\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)-\(second: .twoDigits).\(secondFraction: .fractional(3))Z",
        timeZone: .gmt,
        calendar: Calendar(identifier: .gregorian)
    )

    /// Writes the exact bytes of `detail` as received from the server.
    @discardableResult
    static func write(_ detail: JamfPlatform.BlueprintDetail, date: Date = Date(), root: URL = rootURL) throws -> URL {
        let directory = directory(for: detail.id, root: root)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory.appending(path: "\(date.formatted(fileNameFormat)).json")
            var counter = 2
            while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                url = directory.appending(path: "\(date.formatted(fileNameFormat))-\(counter).json")
                counter += 1
            }
            // `.withoutOverwriting` creates the file exclusively, so an existing
            // backup is never replaced. Foundation rejects it combined with `.atomic`.
            try detail.rawData.write(to: url, options: .withoutOverwriting)
            return url
        } catch {
            throw BackupError(message: "Could not write backup to \(directory.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    /// Backups for one blueprint, newest first.
    static func backups(for blueprintID: String, root: URL = rootURL) -> [BlueprintBackup] {
        let directory = directory(for: blueprintID, root: root)
        let keys: [URLResourceKey] = [.fileSizeKey, .creationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return BlueprintBackup(
                    url: url,
                    blueprintID: blueprintID,
                    date: values?.creationDate ?? .distantPast,
                    size: values?.fileSize ?? 0
                )
            }
            // Numeric comparison of the name without ".json", so a same-millisecond
            // "-2" counter sorts after its base name instead of before it.
            .sorted {
                $0.url.deletingPathExtension().lastPathComponent
                    .compare($1.url.deletingPathExtension().lastPathComponent, options: .numeric) == .orderedDescending
            }
    }

    static func load(_ backup: BlueprintBackup) throws -> JamfPlatform.BlueprintDetail {
        let data = try Data(contentsOf: backup.url)
        let detail = try JamfPlatform.BlueprintDetail(data: data)
        guard detail.id == backup.blueprintID else {
            throw BackupError(message: "The backup belongs to blueprint \(detail.id), not \(backup.blueprintID).")
        }
        return detail
    }
}
