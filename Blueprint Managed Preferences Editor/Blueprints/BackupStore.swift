import Foundation
import JTKit

nonisolated struct BlueprintBackup: Identifiable, Hashable, Sendable {
    let url: URL
    let blueprintID: String
    let date: Date
    let size: Int

    var id: URL { url }
}

/// Writes the full Blueprint JSON before every save and restore, with JTKit's
/// `TimestampedBackupStore`, to
/// `~/Library/Application Support/Blueprint Managed Preferences Editor/Backups/<blueprintId>/<timestamp>.json`:
/// the exact bytes received, never overwritten, readable by the user only.
/// Backups written by earlier versions have the same folder and file names,
/// so they stay listed and restorable.
nonisolated enum BackupStore {
    struct BackupError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The usual place. Under JTKit's live-check switch (release check) the
    /// run's own folder instead, never the real Backups folder.
    static var rootURL: URL {
        LiveLaunch.appFilesFolder("Backups") ?? savedRootURL
    }

    /// Where backups of real connections are kept on an ordinary launch.
    static var savedRootURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Blueprint Managed Preferences Editor", directoryHint: .isDirectory)
            .appending(path: "Backups", directoryHint: .isDirectory)
    }

    /// The Blueprint's own folder, always directly inside `root`.
    static func directory(for blueprintID: String, root: URL = rootURL) -> URL {
        TimestampedBackupStore(root: root).directory(for: blueprintID)
    }

    /// Writes the exact bytes of `detail` as received from the server; a
    /// second backup in the same millisecond gets "-2", "-3" ….
    @discardableResult
    static func write(_ detail: JamfPlatform.BlueprintDetail, date: Date = Date(), root: URL = rootURL) throws -> URL {
        try TimestampedBackupStore(root: root).write(detail.rawData, for: detail.id, date: date)
    }

    /// Backups for one Blueprint, newest first ("-2" … "-10" in order).
    static func backups(for blueprintID: String, root: URL = rootURL) -> [BlueprintBackup] {
        TimestampedBackupStore(root: root).backups(for: blueprintID).map {
            BlueprintBackup(url: $0.url, blueprintID: blueprintID, date: $0.date, size: $0.size)
        }
    }

    static func load(_ backup: BlueprintBackup) throws -> JamfPlatform.BlueprintDetail {
        let data = try Data(contentsOf: backup.url)
        let detail = try JamfPlatform.BlueprintDetail(data: data)
        guard detail.id == backup.blueprintID else {
            throw BackupError(message: "The backup belongs to Blueprint \(detail.id), not \(backup.blueprintID).")
        }
        return detail
    }
}
