import Foundation
import JTKit

/// What the About window shows (JTKit's `AboutWindow`). The app has no
/// third-party code, so there are no acknowledgements.
extension AboutConfiguration {
    static let blueprintManagedPreferencesEditor = AboutConfiguration(
        appName: "Blueprint Managed Preferences Editor",
        author: "Created by Jordy Thery",
        summary: "Edit the Managed Preferences that Jamf Pro’s blueprint UI can’t.",
        links: [
            AboutLink("github.com/JordyThery/Blueprint-Managed-Preferences-Editor", address: "https://github.com/JordyThery/Blueprint-Managed-Preferences-Editor"),
        ].compactMap { $0 }
    )
}
