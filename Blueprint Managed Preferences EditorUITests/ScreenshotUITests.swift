import XCTest
import JTKitUITestSupport

/// Makes the README screenshot in demo mode (Contoso sample data only).
/// Not part of the release check: run it by hand when the interface changes.
/// The image is attached to the test result under its `docs/` file name; get it with
/// `xcrun xcresulttool export attachments --path <result bundle> --output-path <folder>`.
final class ScreenshotUITests: JTKitUITestCase {
    private let microsoft365 = "Contoso – Microsoft 365 (migrated)"
    private let domain = "com.microsoft.autoupdate2"

    override var appName: String { "Blueprint Managed Preferences Editor" }

    override var demoLaunchArguments: [String] {
        // A fixed window size (in points), so every screenshot has the same
        // proportions, whatever frame the main window last had.
        ["-checksForUpdates", "NO", "-NSWindow Frame main", "100 100 1408 855 0 0 1800 1130 "]
    }

    override func launchApp() {
        launchInDemo()
    }

    func testReadmeScreenshot() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")

        tap(text(microsoft365), timeout: 20)
        tap(text(domain), timeout: 20)
        XCTAssertTrue(app.outlineRows.firstMatch.waitForExistence(timeout: 20), "The domain's keys aren't shown")
        sleep(1)

        save(main.screenshot(), as: "screenshot.png")
    }

    // MARK: Helpers

    private func save(_ screenshot: XCUIScreenshot, as name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A SwiftUI text, which exposes its string as the value (label empty).
    private func text(_ string: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }
}
