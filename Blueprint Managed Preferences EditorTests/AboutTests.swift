import Foundation
import JTKit
import Testing
@testable import Blueprint_Managed_Preferences_Editor

@Suite("About window")
struct AboutTests {
    @Test func aboutShowsNameAndRepository() {
        let about = AboutConfiguration.blueprintManagedPreferencesEditor
        #expect(about.windowTitle == "About Blueprint Managed Preferences Editor")
        #expect(about.links.map(\.url.absoluteString) == ["https://github.com/JordyThery/Blueprint-Managed-Preferences-Editor"])
        #expect(about.acknowledgements.isEmpty)
    }
}
