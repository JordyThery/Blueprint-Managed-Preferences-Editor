import XCTest
import JTKitLiveCheck
import JTKitUITestSupport

/// The real app under JTKit's live-check switch (`launchLive`), against
/// jamf-test-a, run only by `Scripts/release-check.sh` in its live stage.
/// The test code makes a JTKTEST device group and Blueprint (the app has no
/// create); the app, launched with `-JTKitLiveCheck`, opens the Blueprint,
/// changes one preference value and saves; the test reads the value back,
/// checks the backup went to the run's folder (never the real Backups
/// folder) and removes both. Every request, the app's and the test's, goes
/// through the release check's gateway (`jtkit-live-gateway`), which decides
/// it by the release check's rules.
final class LiveUITests: JTKitUITestCase {
    private let role = "jamf-test-a"
    private let domain = "com.example.jtktest"
    private let key = "JTKTESTFlag"

    override var appName: String { "Blueprint Managed Preferences Editor" }
    override var launchesLive: Bool { true }

    override func didLaunch() {
        let main = app.windows.firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 20), "The main window did not open")
        if main.frame.width < 1300 {
            let zoom = app.menuBars.menuItems["Zoom"].firstMatch
            if zoom.exists { zoom.click() }
        }
    }

    func testEditAndSaveUnderTheSwitch() throws {
        let gateway = try liveGateway()
        let api = try LiveJamfPlatformAPI(gateway: gateway, role: role)
        let step = { (name: String) in "\(self.role): live UI: \(name)" }
        let prefix = livePrefix
        let name = "\(prefix) – Live UI Blueprint"

        // 1. The test's own objects: an empty static group and a Blueprint
        //    with one Managed Preferences payload (key false), scoped to it.
        let groupID = try liveCall {
            try await api.create("device-groups/v1/device-groups", json: [
                "name": "\(prefix) – Live UI Group", "deviceType": "COMPUTER", "groupType": "STATIC", "members": [String](),
            ])
        }
        var blueprintID: String?
        defer { removeTestObjects(api: api, blueprint: blueprintID, group: groupID, step: step) }
        blueprintID = try liveCall {
            try await api.create("blueprints/v1/blueprints", json: [
                "name": name, "description": "Release check test object; removed after the run",
                "scope": ["deviceGroups": [groupID]], "steps": [Self.step(domain: self.domain, key: self.key)],
            ])
        }
        recordLive(step: step("create a group and a Blueprint"), passed: blueprintID != nil)

        // 2. The real app under the switch, with only jamf-test-a's connection.
        try launchLive(roles: [role])
        let row = text(name, in: app)
        if !row.waitForExistence(timeout: 60) {
            app.typeKey("r", modifierFlags: .command)   // Refresh Blueprints
        }
        XCTAssertTrue(row.waitForExistence(timeout: 60), "The test Blueprint isn't listed")
        // the app reads every Blueprint's details first; select once it's done
        waitForNetwork()
        row.click()
        // the Blueprint's domain list (the sidebar's rows name the domains too)
        let domains = app.outlines.matching(NSPredicate(format: "label != %@", "Sidebar")).firstMatch
        let domainRow = domains.outlineRows.containing(NSPredicate(format: "value == %@ OR label == %@", domain, domain)).firstMatch
        XCTAssertTrue(domainRow.waitForExistence(timeout: 30), "The test Blueprint's domain isn't shown")
        waitForNetwork()

        // 3. Change the value and save.
        let outlineRow = app.outlineRows.containing(NSPredicate(format: "value == %@ OR label == %@", key, key)).firstMatch
        for _ in 0..<3 where !outlineRow.exists {
            // the row reports itself as not hittable; its middle is
            domainRow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
            _ = outlineRow.waitForExistence(timeout: 10)
        }
        if !outlineRow.waitForExistence(timeout: 10) {
            // what the editor shows instead (the test's own Blueprint and the app's labels)
            let shown = app.windows.firstMatch.staticTexts.allElementsBoundByIndex.compactMap { $0.value as? String }.filter { !$0.isEmpty }
            print("LIVE-UI-TEXTS: \(shown.suffix(25))")
        }
        XCTAssertTrue(outlineRow.exists, "\(key) isn't listed")
        tap(outlineRow.popUpButtons.matching(NSPredicate(format: "value == 'false'")).firstMatch, timeout: 10)
        tap(app.menuItems["true"].firstMatch, timeout: 5)
        tap(app.buttons["Save…"].firstMatch, timeout: 10)
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(text("“\(name)” · 1 change", in: sheet).waitForExistence(timeout: 10), "The review doesn't list exactly one change")
        tap(sheet.buttons["Save"], timeout: 10)
        let saved = app.descendants(matching: .any)
            .matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", "“\(name)” was saved", "“\(name)” was saved")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 60), "The save didn't finish with “Saved” in the window")
        waitForNetwork()
        recordLive(step: step("open the Blueprint in the app, change the value, save"), passed: true)

        // 4. Read back what Jamf has.
        let id = try XCTUnwrap(blueprintID)
        let blueprint = try liveCall { try await api.object("blueprints/v1/blueprints/\(id)") }
        let value = Self.value(in: blueprint, domain: domain, key: key)
        XCTAssertEqual(value, true, "Jamf has \(String(describing: value)) for \(key)")
        recordLive(step: step("read back: the saved value is true"), passed: value == true)

        // 5. The backup before the save is in the run's folder.
        let backups = gateway.appRunFolder.appending(path: "app-files/Backups/\(id)", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: backups.path(percentEncoded: false))) ?? []
        let backedUp = files.filter { $0.hasSuffix(".json") }.count == 1
        XCTAssertTrue(backedUp, "No backup in the run's folder: \(files)")
        recordLive(step: step("the backup is in the run's folder"), passed: backedUp)
        app.terminate()
    }

    // MARK: Helpers

    /// Removes the Blueprint, then the group (Jamf frees it once the
    /// Blueprint is gone), and checks the run left nothing.
    private func removeTestObjects(api: LiveJamfPlatformAPI, blueprint: String?, group: String, step: (String) -> String) {
        app?.terminate()
        let removed = (try? liveCall(timeout: 400) {
            if let blueprint {
                try await api.send("DELETE", "blueprints/v1/blueprints/\(blueprint)", accepting: [404])
            }
            let deadline = Date().addingTimeInterval(180)
            while true {
                let (status, body) = try await api.send("DELETE", "device-groups/v1/device-groups/\(group)", accepting: [404, 422])
                if status != 422 || Date() > deadline { return status < 300 || status == 404 }
                _ = body
                try await Task.sleep(for: .seconds(5))
            }
        }) ?? false
        let nothingLeft = (try? requireRunObjectsGone()) != nil
        recordLive(step: step("remove the Blueprint and the group"), passed: removed && nothingLeft)
        XCTAssertTrue(removed && nothingLeft, "The test objects weren't all removed")
    }

    /// A SwiftUI text, which exposes its string as the value (label empty).
    private func text(_ string: String, in root: XCUIElement) -> XCUIElement {
        root.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", string, string)).firstMatch
    }

    /// The step the unit live checks use: one Managed Preferences payload,
    /// a made-up domain with one key, false.
    static func step(domain: String, key: String) -> [String: Any] {
        ["name": "JTKTEST Managed Preferences", "activationPredicate": NSNull(), "components": [[
            "identifier": "com.jamf.ddm-configuration-profile",
            "configuration": [
                "payloadUUID": UUID().uuidString,
                "payloadIdentifier": "com.example.jtktest.profile",
                "payloadDisplayName": "JTKTEST Profile",
                "payloadContent": [[
                    "payloadType": "com.apple.ManagedClient.preferences",
                    "payloadUUID": UUID().uuidString,
                    "payloadVersion": 1,
                    "payloadIdentifier": "com.example.jtktest.payload",
                    "payloadDisplayName": "JTKTEST Preferences",
                    "PayloadContent": [domain: ["Forced": [["mcx_preference_settings": [key: false]]]]],
                ]],
            ],
        ]]]
    }

    /// The key's value in the Blueprint's first payload.
    static func value(in blueprint: [String: Any], domain: String, key: String) -> Bool? {
        let steps = blueprint["steps"] as? [[String: Any]]
        let component = (steps?.first?["components"] as? [[String: Any]])?.first
        let payload = ((component?["configuration"] as? [String: Any])?["payloadContent"] as? [[String: Any]])?.first
        let forced = ((payload?["PayloadContent"] as? [String: Any])?[domain] as? [String: Any])?["Forced"] as? [[String: Any]]
        return (forced?.first?["mcx_preference_settings"] as? [String: Any])?[key] as? Bool
    }
}
