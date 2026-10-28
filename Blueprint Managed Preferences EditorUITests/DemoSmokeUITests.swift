import XCTest
import JTKitUITestSupport

/// The release check's UI smoke tests (JTKit ROADMAP step 11), in demo mode:
/// the same answers every run, no tenant, nothing saved. Run one at a time by
/// `Scripts/release-check.sh`; minutes, not hours.
final class DemoSmokeUITests: JTKitUITestCase {
    private let microsoft365 = "Contoso – Microsoft 365 (migrated)"

    override var appName: String { "Blueprint Managed Preferences Editor" }

    override var demoLaunchArguments: [String] {
        ["-checksForUpdates", "NO"]
    }

    override func launchApp() {
        launchInDemo()
    }

    override func didLaunch() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        if main.frame.width < 1300 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    func test1Launch() {
        XCTAssertTrue(window(titled: appName).waitForExistence(timeout: 20), "The main window did not open")
        openMicrosoft365()
    }

    func test2About() {
        checkAbout()
    }

    func test3SettingsTabs() {
        checkSettingsTabs(["General", "Connections", "Updates"])
    }

    func test4ConnectionsEditor() {
        // Made-up values: the connection lives only in this run's in-memory list.
        checkConnectionsEditor { settings in
            self.type(UUID().uuidString, into: settings.textFields.matching(NSPredicate(format: "placeholderValue == 'From Jamf Account'")).firstMatch)
            let fields = settings.textFields.allElementsBoundByIndex
            if let clientID = fields.last { self.type("jtktest-client", into: clientID) }
            self.type("jtktest-secret", into: settings.secureTextFields.firstMatch)
        }
    }

    /// Edit a Microsoft AutoUpdate key and save it; the review lists only
    /// that one change. (That the save sends everything else back byte for
    /// byte is checked by the unit tests against the same demo server.)
    func test5MainTask() {
        openMicrosoft365()
        tap(text("com.microsoft.autoupdate2", in: app), timeout: 20)

        // The Value picker in EnableCheckForUpdatesButton's row (the Type
        // picker beside it reads "Boolean").
        let key = "EnableCheckForUpdatesButton"
        let row = app.outlineRows.containing(NSPredicate(format: "value == %@ OR label == %@", key, key)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(key) isn't listed")
        let value = row.popUpButtons.matching(NSPredicate(format: "value == 'false'")).firstMatch
        tap(value, timeout: 10)
        tap(app.menuItems["true"].firstMatch, timeout: 5)
        XCTAssertTrue(text("Unsaved changes", in: app).waitForExistence(timeout: 10), "The edit didn't make the Blueprint dirty")

        tap(app.buttons["Save…"].firstMatch, timeout: 10)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(text("Review Changes", in: sheet).waitForExistence(timeout: 10), "Review Changes didn't open")
        XCTAssertTrue(text("“\(microsoft365)” · 1 change", in: sheet).waitForExistence(timeout: 5),
                      "The review doesn't list exactly one change")
        tap(sheet.buttons["Save"], timeout: 10)

        let saved = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "“\(microsoft365)” was saved", "“\(microsoft365)” was saved")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 20), "The save didn't finish with “Saved”")
        tap(dialogButton("OK"))
        XCTAssertFalse(app.buttons["Save…"].firstMatch.isEnabled, "Save is still enabled after saving")
    }

    func test6ActivityLog() {
        openMicrosoft365()
        checkActivityLog()
    }

    func test7DemoTitles() {
        tap(app.menuBars.menuBarItems[appName])
        tap(app.menuItems["About \(appName)"])
        XCTAssertTrue(window(titled: "About \(appName)").waitForExistence(timeout: 10))
        app.typeKey("l", modifierFlags: [.command, .shift])
        XCTAssertTrue(window(titled: "Activity Log").waitForExistence(timeout: 10))
        openSettings()
        checkDemoTitles()
    }

    // MARK: Helpers

    /// The sidebar lists Contoso's Microsoft 365 Blueprint; select it.
    private func openMicrosoft365(file: StaticString = #filePath, line: UInt = #line) {
        let row = text(microsoft365, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Contoso's Blueprints aren't listed", file: file, line: line)
        row.click()
        XCTAssertTrue(text("com.microsoft.autoupdate2", in: app).waitForExistence(timeout: 20),
                      "The Microsoft 365 Blueprint's domains aren't shown", file: file, line: line)
    }

    /// A SwiftUI text, which exposes its string as the value (label empty).
    private func text(_ string: String, in root: XCUIElement) -> XCUIElement {
        root.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }
}
