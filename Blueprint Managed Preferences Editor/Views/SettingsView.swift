import JTKit
import SwiftUI

/// The Settings window: saved Jamf Platform API connections and the daily update check.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Connections", systemImage: "network") {
                ConnectionsSettingsView()
            }
            Tab("Updates", systemImage: "arrow.down.circle") {
                Form {
                    UpdateSettingsSection()
                }
                .formStyle(.grouped)
                .frame(width: 680, height: 180)
            }
        }
    }
}

/// Manage saved connections. Secrets are written to the Keychain only.
private struct ConnectionsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var editingID: UUID?
    @State private var pendingDeletionID: UUID?

    var body: some View {
        let store = model.profileStore
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(store.profiles, selection: $editingID) { profile in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text(profile.region.rawValue.uppercased())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if profile.id == store.selectedProfileID {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                                .help("Active connection")
                        }
                    }
                    .tag(profile.id)
                }
                Divider()
                HStack(spacing: 0) {
                    Button {
                        let profile = ConnectionProfile.newProfile()
                        try? store.save(profile, secret: nil)
                        editingID = profile.id
                    } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add connection")
                    Button {
                        pendingDeletionID = editingID
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .help("Delete connection and its Keychain secret")
                    .disabled(editingID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 200)

            Divider()

            if let editingID, let profile = store.profile(id: editingID) {
                ProfileEditor(profile: profile)
                    .id(editingID)
            } else {
                ContentUnavailableView(
                    "No Connection Selected",
                    systemImage: "network",
                    description: Text("Click + to add a Jamf Platform API connection.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 680, height: 420)
        .onAppear {
            editingID = editingID ?? store.selectedProfileID ?? store.profiles.first?.id
        }
        .confirmationDialog(
            "Delete “\(pendingDeletionID.flatMap { store.profile(id: $0)?.name } ?? "connection")”?",
            isPresented: Binding(get: { pendingDeletionID != nil }, set: { if !$0 { pendingDeletionID = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeletionID { store.delete(id: id) }
                pendingDeletionID = nil
                editingID = store.profiles.first?.id
            }
            Button("Cancel", role: .cancel) { pendingDeletionID = nil }
        } message: {
            Text("The connection and its Keychain secret are removed.")
        }
    }
}

private struct ProfileEditor: View {
    @Environment(AppModel.self) private var model

    @State private var draft: ConnectionProfile
    @State private var secret: String
    @State private var storedSecret: String
    @State private var testState: TestState = .idle
    @State private var saveError: String?
    @State private var isConfirmingSwitch = false

    enum TestState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    init(profile: ConnectionProfile) {
        _draft = State(initialValue: profile)
        let stored = KeychainStore.secret(for: profile.id) ?? ""
        _secret = State(initialValue: stored)
        _storedSecret = State(initialValue: stored)
    }

    private var savedProfile: ConnectionProfile? { model.profileStore.profile(id: draft.id) }
    private var hasChanges: Bool { savedProfile != draft || secret != storedSecret }
    private var isActive: Bool { model.profileStore.selectedProfileID == draft.id }

    var body: some View {
        Form {
            TextField("Name", text: $draft.name)
            Picker("Region", selection: $draft.region) {
                ForEach(PlatformRegion.allCases) { Text($0.displayName).tag($0) }
            }
            TextField("Environment ID", text: $draft.environmentID, prompt: Text("UUID"))
                .font(.body.monospaced())
            TextField("Client ID", text: $draft.clientID)
                .font(.body.monospaced())
            SecureField("Client Secret", text: $secret)
            LabeledContent("Token URL") {
                Text(draft.region.baseURL.appending(path: "auth/token").absoluteString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Section {
                HStack {
                    Button("Test Connection", action: testConnection)
                        .disabled(!canTest || testState == .testing)
                    testStatus
                    Spacer()
                }
                if let saveError {
                    Text(saveError).foregroundStyle(.red).font(.callout)
                }
                HStack {
                    if !isActive {
                        Button("Use This Connection") {
                            // Switching discards state loaded from the current tenant.
                            if model.hasUnsavedChanges {
                                isConfirmingSwitch = true
                            } else {
                                activate()
                            }
                        }
                    } else {
                        Label("Active connection", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Revert") {
                        if let savedProfile { draft = savedProfile }
                        secret = storedSecret
                    }
                    .disabled(!hasChanges)
                    Button("Save", action: save)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!hasChanges)
                }
            } footer: {
                Text("Requires an API client with blueprints:read, blueprints:update and blueprints:deploy. The client secret is stored in your login Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Switch connection and discard unsaved changes?", isPresented: $isConfirmingSwitch) {
            Button("Discard and Switch", role: .destructive, action: activate)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func activate() {
        save()
        model.profileStore.selectedProfileID = draft.id
    }

    @ViewBuilder
    private var testStatus: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(6)
        }
    }

    private var canTest: Bool { draft.isComplete && !secret.isEmpty }

    private func save() {
        saveError = nil
        do {
            try model.profileStore.save(draft, secret: secret != storedSecret ? secret : nil)
            storedSecret = secret
        } catch {
            saveError = error.localizedDescription
        }
    }

    /// Fetches a token, then calls GET /v1/blueprints?page-size=1, using the unsaved draft values.
    private func testConnection() {
        let credentials = PlatformCredentials(
            region: draft.region,
            environmentID: draft.environmentID.trimmingCharacters(in: .whitespaces),
            clientID: draft.clientID.trimmingCharacters(in: .whitespaces),
            clientSecret: secret
        )
        testState = .testing
        Task {
            let client = model.makeClient(credentials: credentials)
            do {
                try await client.refreshToken()
                let page = try await BlueprintService(client: client).listPage(page: 0, pageSize: 1)
                let count = page.totalCount.map { "\($0) blueprint\($0 == 1 ? "" : "s")" } ?? "blueprint list OK"
                testState = .success("Connected · \(count)")
            } catch {
                testState = .failure(error.localizedDescription)
            }
        }
    }
}
