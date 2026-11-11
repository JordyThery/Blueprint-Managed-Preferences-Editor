import Foundation
import JTKit

/// What the About window shows (JTKit's `AboutWindow`). The app has no
/// third-party code, so there are no acknowledgements.
extension AboutConfiguration {
    static let blueprintManagedPreferencesEditor = AboutConfiguration(
        appName: "Blueprint Managed Preferences Editor",
        copyright: AboutCopyright(year: "2026", holder: "Jordy Thery"),
        author: "Created by Jordy Thery",
        summary: "Edit the Managed Preferences that Jamf Pro’s Blueprint UI can’t.\n\n\(ArchiveNotice.text)",
        links: [
            ArchiveNotice.blueshiftURL.map { AboutLink(ArchiveNotice.buttonTitle, url: $0) },
            AboutLink("github.com/JordyThery/Blueprint-Managed-Preferences-Editor", address: "https://github.com/JordyThery/Blueprint-Managed-Preferences-Editor"),
        ].compactMap { $0 }
    )
}
