import AppKit
import SwiftUI

/// Blueprints → preference domains → key/value editor.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openWindow) private var openWindow
    @State private var isShowingFetchByID = false

    var body: some View {
        @Bindable var updates = updates
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } content: {
            if let id = model.selectedBlueprintID {
                BlueprintColumnView(blueprintID: id)
                    .id(id)
                    .navigationSplitViewColumnWidth(min: 260, ideal: 320)
            } else {
                Text("Select a blueprint")
                    .foregroundStyle(.secondary)
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
                    isShowingFetchByID = true
                } label: {
                    Label("Fetch by ID", systemImage: "number")
                }
                .help("Fetch one blueprint by ID")
                .disabled(model.profileStore.selectedProfile == nil)

                Button {
                    model.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Discover blueprints that contain Managed Preferences")
                .disabled(model.isBusy || model.profileStore.selectedProfile == nil)

                Button {
                    openWindow(id: WindowID.requestLog)
                } label: {
                    Label("Request Log", systemImage: "list.bullet.rectangle")
                }
                .help("Show every API request and response (secrets redacted)")
            }
        }
        .sheet(isPresented: $isShowingFetchByID) {
            FetchByIDSheet()
        }
        .sheet(isPresented: $updates.isPresented) {
            UpdateView()
        }
        .onChange(of: model.profileStore.selectedProfileID) {
            model.connectionDidChange()
        }
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
        } else if model.profileStore.selectedProfile == nil {
            ContentUnavailableView {
                Label("No Connection", systemImage: "network.slash")
            } description: {
                Text("Add a Jamf Platform API connection in Settings to get started.")
            } actions: {
                SettingsLink { Text("Open Settings…") }
            }
        } else {
            ContentUnavailableView(
                "No Blueprint Selected",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Refresh to discover blueprints, or fetch a known blueprint by ID.")
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

/// Toolbar menu for switching between saved connections. Asks first when there
/// are unsaved edits, since switching discards them.
private struct ProfilePicker: View {
    @Environment(AppModel.self) private var model
    @State private var pendingProfileID: UUID?

    var body: some View {
        let store = model.profileStore
        if store.profiles.isEmpty {
            SettingsLink { Label("Add Connection…", systemImage: "plus") }
        } else {
            Picker("Connection", selection: Binding(
                get: { store.selectedProfileID },
                set: { newValue in
                    guard newValue != store.selectedProfileID else { return }
                    if model.hasUnsavedChanges {
                        pendingProfileID = newValue
                    } else {
                        store.selectedProfileID = newValue
                    }
                }
            )) {
                ForEach(store.profiles) { profile in
                    Text("\(profile.name) (\(profile.region.rawValue))").tag(Optional(profile.id))
                }
            }
            .pickerStyle(.menu)
            .help("Active connection")
            .confirmationDialog(
                "Switch connection and discard unsaved changes?",
                isPresented: Binding(get: { pendingProfileID != nil }, set: { if !$0 { pendingProfileID = nil } })
            ) {
                Button("Discard and Switch", role: .destructive) {
                    store.selectedProfileID = pendingProfileID
                    pendingProfileID = nil
                }
                Button("Cancel", role: .cancel) { pendingProfileID = nil }
            }
        }
    }
}

/// Fetches a single blueprint by ID so its raw JSON can be inspected.
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
            Text("Loads GET /v1/blueprints/{id}, even if it contains no Managed Preferences payload.")
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
