import SwiftUI

@main struct MyApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Blueprint Managed Preferences Editor", id: "main") {
            ContentView()
                .environment(model)
        }
        .commands {
            AppCommands(model: model)
        }

        Window("Request Log", id: WindowID.requestLog) {
            RequestLogView()
                .environment(model)
        }
        .defaultSize(width: 1000, height: 650)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let requestLog = "request-log"
}

private struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Refresh Blueprints") { model.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isBusy)
        }
        CommandGroup(after: .windowList) {
            Button("Request Log") { openWindow(id: WindowID.requestLog) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
