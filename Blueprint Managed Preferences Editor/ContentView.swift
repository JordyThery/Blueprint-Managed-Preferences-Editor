import AppKit
import JTKit
import SwiftUI

/// Blueprints → preference domains → key/value editor.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var updates = updates
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } content: {
            if let id = model.selectedBlueprintID {
                BlueprintColumnView(blueprintID: id)
                    .id(id)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } else {
                // Without a connection the detail column says what to do; this one stays empty.
                Group {
                    if model.hasActiveConnection {
                        ContentUnavailableView("Select a Blueprint", systemImage: "sidebar.left")
                    } else {
                        Color.clear
                    }
                }
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            }
        } detail: {
            detail
        }
        .navigationTitle("Blueprint Managed Preferences Editor")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ProfilePicker()
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isShowingFetchByID = true
                } label: {
                    Label("Fetch by ID", systemImage: "number")
                }
                .help("Fetch one Blueprint by ID")
                .disabled(!model.hasActiveConnection)

                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Discover Blueprints that contain Managed Preferences")
                .disabled(model.isBusy || !model.hasActiveConnection)

                Button {
                    openWindow(id: ActivityLogWindow.id)
                } label: {
                    Label("Activity Log", systemImage: "list.bullet.rectangle")
                }
                .help("Show sign-ins and Jamf API calls (secrets redacted)")
            }
        }
        .sheet(isPresented: $model.isShowingFetchByID) {
            FetchByIDSheet()
        }
        .sheet(isPresented: $updates.isPresented) {
            UpdateView()
        }
        // A connection change clears the old tenant's Blueprints in the model
        // (`AppModel.tenantDidChangeIfNeeded`). At launch in demo mode, the
        // sample Blueprints load straight away.
        .task { if model.demo.isOn && model.overviews.isEmpty { model.refresh() } }
        .alert(
            model.notice?.title ?? "",
            isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } }),
            presenting: model.notice
        ) { _ in
            Button("OK") {}
        } message: { notice in
            Text(notice.message)
        }
        .confirmsConnectionSwitch(from: .mainWindow)
        .confirmsDemoModeSwitch(model.demo)
        .background(WindowEditedMarker(isEdited: model.hasUnsavedChanges))
        .frame(minWidth: 1100, minHeight: 600)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedBlueprintID {
            if let editor = model.editors[id] {
                switch editor.selection {
                case .domain(let domainID):
                    DomainEditorView(editor: editor, domainID: domainID)
                        .id(domainID)
                case .rawJSON:
                    RawJSONView(detail: editor.base, pendingPatchBody: editor.isDirty ? editor.document.patchBody : nil)
                case nil:
                    ContentUnavailableView("Select a Domain", systemImage: "sidebar.squares.left", description: Text("Choose a preference domain to edit its keys."))
                }
            } else if let detail = model.details[id] {
                RawJSONView(detail: detail)
            } else {
                Color.clear
            }
        } else if !model.hasActiveConnection {
            ContentUnavailableView {
                Label("No Connection", systemImage: "network.slash")
            } description: {
                Text("Add a Jamf Platform API connection in Settings, or try the app with sample data.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
                Button("Try Demo Mode") { model.demo.requestSwitch(to: true) }
            }
        } else {
            ContentUnavailableView(
                "No Blueprint Selected",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Refresh to discover Blueprints, or fetch a known Blueprint by ID.")
            )
        }
    }
}

/// Sets the window's "edited" dot in the close button.
private struct WindowEditedMarker: NSViewRepresentable {
    let isEdited: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let edited = isEdited
        DispatchQueue.main.async {
            view.window?.isDocumentEdited = edited
        }
    }
}

/// Toolbar menu for switching between saved connections, with Edit Connections…
/// and Demo Mode (JTKit's `ConnectionPicker`, the same items as the Connection
/// menu). Reads "Contoso (Demo)" in demo mode. Asks first when there are
/// unsaved edits, since switching discards them.
private struct ProfilePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ConnectionPicker(
            store: model.profileStore.connections,
            selection: model.connectionSelection(from: .mainWindow),
            itemTitle: \.menuTitle,
            label: model.demo.isOn ? .demo(.demoJamfPlatform) : nil,
            help: model.demo.isOn ? DemoMode.helpText : nil
        ) {
            DemoModeToggle(demo: model.demo)
        }
    }
}

extension AppModel {
    /// The active connection for JTKit's picker, menu and Connections tab.
    /// Choosing another one while Blueprint edits are unsaved asks first. In
    /// demo mode the picker and menu show none chosen; choosing one there
    /// leaves demo mode. Settings › Connections keeps showing the saved choice.
    /// - Parameter whenAsking: runs when the question is shown, e.g. to
    ///   bring the main window forward for the Connection menu.
    func connectionSelection(from origin: ConnectionSwitchOrigin,
                             whenAsking: @escaping () -> Void = {}) -> Binding<UUID?> {
        Binding(
            get: { origin == .mainWindow && self.demo.isOn ? nil : self.profileStore.selectedProfileID },
            set: { if self.chooseConnection($0, from: origin) { whenAsking() } }
        )
    }
}

extension View {
    /// "Switch connection and discard unsaved changes?" for a connection
    /// chosen from `origin` while Blueprint edits are unsaved.
    func confirmsConnectionSwitch(from origin: AppModel.ConnectionSwitchOrigin) -> some View {
        modifier(ConnectionSwitchConfirmation(origin: origin))
    }
}

private struct ConnectionSwitchConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model
    let origin: AppModel.ConnectionSwitchOrigin

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Switch connection and discard unsaved changes?",
            isPresented: Binding(
                get: { model.pendingConnectionSwitch?.origin == origin },
                set: { if !$0 { model.pendingConnectionSwitch = nil } }
            )
        ) {
            Button("Discard and Switch", role: .destructive) { model.confirmConnectionSwitch() }
            Button("Cancel", role: .cancel) { model.pendingConnectionSwitch = nil }
        }
    }
}

/// Fetches a single Blueprint by ID so its raw JSON can be inspected.
private struct FetchByIDSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var blueprintID = ""
    @State private var isFetching = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fetch Blueprint by ID")
                .font(.headline)
            Text("Loads one Blueprint by ID, even if it has no Managed Preferences payload.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Blueprint ID", text: $blueprintID)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(fetch)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if isFetching { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Fetch", action: fetch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blueprintID.trimmingCharacters(in: .whitespaces).isEmpty || isFetching)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func fetch() {
        isFetching = true
        errorMessage = nil
        Task {
            defer { isFetching = false }
            do {
                try await model.fetchBlueprint(id: blueprintID)
                dismiss()
            } catch is CancellationError {
                // The connection changed while reading: the Blueprint belongs to the old one.
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    let model = AppModel()
    ContentView()
        .environment(model)
        .environment(model.updates)
}
