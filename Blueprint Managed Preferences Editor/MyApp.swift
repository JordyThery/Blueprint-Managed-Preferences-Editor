import JTKit
import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Blueprint Managed Preferences Editor", id: WindowID.main) {
            ContentView()
                .environment(model)
                .environment(model.updates)
                .task { await model.updates.checkAutomatically() }
        }
        .commands {
            AppCommands(model: model)
        }

        AboutWindow(configuration: .blueprintManagedPreferencesEditor)

        // JTKit's shared activity log (Window › Activity Log, ⇧⌘L).
        ActivityLogWindow(
            log: model.activityLog,
            emptyDescription: "Sign-ins, Jamf API calls and retries appear here as they happen."
        )

        // JTKit's Settings window: General (Appearance), Connections, Updates.
        SettingsWindow(updates: model.updates, opensTabsByName: true) {
            ConnectionsTab()
                .environment(model)
        }
    }
}

enum WindowID {
    static let main = "main"
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
        )
        CommandGroup(after: .toolbar) {
            Button("Refresh Blueprints") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
        }
    }
}
