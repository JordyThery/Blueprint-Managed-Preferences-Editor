import Foundation
import JTKit
import Testing
@testable import Blueprint_Managed_Preferences_Editor

@Suite("About window")
struct AboutTests {
    @Test func aboutShowsNameAndRepository() {
        let about = AboutConfiguration.blueprintManagedPreferencesEditor
        #expect(about.windowTitle == "About Blueprint Managed Preferences Editor")
        #expect(about.links.map(\.url.absoluteString) == ["https://github.com/Jamf-Concepts/blueshift",
                                                         "https://github.com/JordyThery/Blueprint-Managed-Preferences-Editor"])
        #expect(about.acknowledgements.isEmpty)
    }

    /// The line JTKit writes; it matches what NSHumanReadableCopyright said before 0.4.1.
    @Test func aboutShowsTheCopyrightLine() {
        #expect(AboutConfiguration.blueprintManagedPreferencesEditor.copyright?.text == "© 2026 Jordy Thery. Released under the MIT License.")
    }

    /// The no-longer-maintained notice, also at the top of the main window.
    @Test func aboutSaysTheAppIsNoLongerMaintained() {
        let about = AboutConfiguration.blueprintManagedPreferencesEditor
        #expect(about.summary?.hasSuffix(ArchiveNotice.text) == true)
        #expect(about.links.first?.title == "Open Blueshift")
        #expect(about.links.first?.url == ArchiveNotice.blueshiftURL)
    }

    @Test func theNoticeNamesBlueshiftAndThatDeployingIsDoneInJamfPro() {
        #expect(ArchiveNotice.blueshiftURL?.absoluteString == "https://github.com/Jamf-Concepts/blueshift")
        #expect(ArchiveNotice.text.hasPrefix("Blueprint Managed Preferences Editor is no longer maintained."))
        #expect(ArchiveNotice.text.contains("Blueshift by Jamf Concepts"))
        #expect(ArchiveNotice.text.contains("Edit Values"))
        #expect(ArchiveNotice.text.contains("deploying is done in Jamf Pro"))
    }
}
