import XCTest
import JTKitUITestSupport

/// The two screenshots on jordythery.be (and the README's), taken in demo
/// mode with the sample tenant "Contoso (Demo)", in the light appearance.
/// Not part of the release check (it runs only `DemoSmokeUITests` and the
/// live tests), and the app's own scheme runs no UI tests, so ⌘U never
/// starts this. Run it by name; the screenshots are kept in the test result
/// as "blueprint-managed-preferences-editor" and
/// "blueprint-managed-preferences-editor-review".
final class WebsiteScreenshotUITests: JTKitUITestCase {
    private let microsoft365 = "Contoso – Microsoft 365 (migrated)"
    private let domain = "com.microsoft.autoupdate2"
    private let key = "EnableCheckForUpdatesButton"

    override var appName: String { "Blueprint Managed Preferences Editor" }

    override var demoLaunchArguments: [String] {
        ["-checksForUpdates", "NO", "-NSRequiresAquaSystemAppearance", "YES"]
    }

    override func launchApp() {
        launchInDemo()
    }

    override func setUpWithError() throws {
        try XCTSkipIf(Self.isReleaseCheck, "Website screenshots aren't part of the release check")
        try super.setUpWithError()
    }

    func testWebsiteScreenshots() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        zoom(main)

        // A sample Blueprint with a preference domain open in the outline editor.
        tap(text(microsoft365), timeout: 20)
        tap(text(domain), timeout: 20)
        let row = app.outlineRows.containing(NSPredicate(format: "value == %@ OR label == %@", key, key)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The domain's keys aren't shown")
        sleep(1)
        keep(main.screenshot(), named: "blueprint-managed-preferences-editor")

        // One edit, then the review of changes before Save.
        tap(row.popUpButtons.matching(NSPredicate(format: "value == 'false'")).firstMatch, timeout: 10)
        tap(app.menuItems["true"].firstMatch, timeout: 5)
        tap(app.buttons["Save…"].firstMatch, timeout: 10)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(text("Review Changes", in: sheet).waitForExistence(timeout: 10), "Review Changes didn't open")
        sleep(1)
        keep(main.screenshot(), named: "blueprint-managed-preferences-editor-review")
        tap(sheet.buttons["Cancel"].firstMatch, timeout: 5)
    }

    // MARK: Helpers

    /// Zooms the window to fill the screen (drags don't move or resize it).
    private func zoom(_ window: XCUIElement) {
        let before = window.frame
        tap(app.menuBars.menuBarItems["Window"].firstMatch)
        tap(app.menuItems["Zoom"].firstMatch)
        sleep(1)
        if window.frame.height <= before.height {
            // The window was already zoomed: zooming toggled it back.
            tap(app.menuBars.menuBarItems["Window"].firstMatch)
            tap(app.menuItems["Zoom"].firstMatch)
            sleep(1)
        }
    }

    private func keep(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A SwiftUI text, which exposes its string as the value (label empty).
    private func text(_ string: String, in root: XCUIElement? = nil) -> XCUIElement {
        (root ?? app).staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }
}
