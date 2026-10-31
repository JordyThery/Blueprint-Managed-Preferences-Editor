import AppKit
import JTKit
import SwiftUI

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window("Blueprint Managed Preferences Editor", id: WindowID.main) {
            ContentView()
                .environment(model)
                .environment(model.updates)
                .task { if !model.demo.isSandbox { await model.updates.checkAutomatically() } }
        }
        .environment(model.demo)
        .commands {
            AppCommands(model: model)
        }

        AboutWindow(configuration: .blueprintManagedPreferencesEditor)
            .environment(model.demo)

        // JTKit's shared activity log (Window › Activity Log, ⇧⌘L).
        ActivityLogWindow(
            log: model.activityLog,
            emptyDescription: "Sign-ins, Jamf API calls and retries appear here as they happen."
        )
        .environment(model.demo)

        // JTKit's Settings window: General (Appearance), Connections, Updates.
        SettingsWindow(updates: model.updates, opensTabsByName: true) {
            ConnectionsTab()
                .environment(model)
        }
        .environment(model.demo)
    }
}

enum WindowID {
    static let main = "main"
}

/// Owns the app's model, so Quit can ask before unsaved edits are lost or
/// while a change is still being sent.
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel.forLaunch()

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let question = model.quitQuestion else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.message
        // No default button: Return doesn't quit by accident, and Cancel (Escape) stays on the leading side.
        let quit = alert.addButton(withTitle: question.quitButton)
        quit.hasDestructiveAction = true
        quit.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

private struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        AppInfoCommands(appName: "Blueprint Managed Preferences Editor") {
            // The update sheet is presented on the main window.
            openWindow(id: WindowID.main)
            model.updates.checkManually()
        }
        // The toolbar picker's items, as JTKit's Connection menu. With unsaved
        // edits the question appears on the main window, so bring it forward.
        ConnectionCommands(
            store: model.profileStore.connections,
            selection: model.connectionSelection(from: .mainWindow) {
                openWindow(id: WindowID.main)
            },
            itemTitle: \.menuTitle
        ) {
            DemoModeToggle(demo: model.demo) { openWindow(id: WindowID.main) }
        }
        // The toolbar's Fetch by ID and Refresh, also in the menu bar.
        CommandGroup(after: .toolbar) {
            Button("Refresh Blueprints") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy || !model.hasActiveConnection)
            Button("Fetch Blueprint by ID…") {
                openWindow(id: WindowID.main)
                model.isShowingFetchByID = true
            }
            .disabled(!model.hasActiveConnection)
        }
    }
}
