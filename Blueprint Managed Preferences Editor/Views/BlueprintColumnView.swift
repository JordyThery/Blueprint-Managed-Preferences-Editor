import AppKit
import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// Middle column: the domains of the selected Blueprint and its save/deploy actions.
struct BlueprintColumnView: View {
    let blueprintID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if let editor = model.editors[blueprintID] {
            EditorColumn(editor: editor)
        } else if let detail = model.details[blueprintID] {
            VStack(alignment: .leading, spacing: 12) {
                BlueprintHeader(detail: detail)
                ContentUnavailableView(
                    "No Managed Preferences",
                    systemImage: "doc.questionmark",
                    description: Text("This Blueprint has no Managed Preferences payload (\(ManagedPreferencesLocator.payloadType)). Its raw JSON is shown on the right.")
                )
            }
            .padding()
        } else if let error = model.detailErrors[blueprintID] {
            ContentUnavailableView {
                Label("Could Not Load Blueprint", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            }
        } else {
            ProgressView("Loading…")
        }
    }
}

private struct EditorColumn: View {
    @Bindable var editor: EditorModel
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    @State private var namePrompt: NamePrompt?
    @State private var isReviewing = false
    /// The review opens with the Save & Deploy question (Blueprint › Save & Deploy…).
    @State private var reviewStartsWithDeploy = false
    @State private var isRestoring = false
    @State private var isConfirmingDeploy = false
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingReload = false
    @State private var importSummary: ImportSummary?

    struct ImportSummary {
        let title: String
        let message: String
    }

    /// Add or rename a domain.
    struct NamePrompt: Identifiable {
        let id = UUID()
        let title: String
        /// The sheet's default button, e.g. "Add" or "Rename".
        let actionTitle: String
        let initial: String
        let domainID: PreferenceDomain.ID?
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                BlueprintHeader(detail: editor.base)
                statusBanner
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)
            Divider()
            domainList
            Divider()
            actionBar
        }
        .onAppear {
            editor.undoManager = undoManager
            carryOut(editor.request)
        }
        .onChange(of: undoManager) { editor.undoManager = undoManager }
        .onChange(of: editor.request) { carryOut(editor.request) }
        .sheet(item: $namePrompt) { prompt in
            NameSheet(
                title: prompt.title,
                actionTitle: prompt.actionTitle,
                initial: prompt.initial,
                validate: { name in
                    editor.validateDomainName(name, renaming: prompt.domainID, near: selectedDomainID)
                },
                commit: { name in
                    if let id = prompt.domainID {
                        editor.renameDomain(id, to: name)
                    } else {
                        editor.addDomain(name: name, near: selectedDomainID)
                    }
                }
            )
        }
        .sheet(isPresented: $isReviewing, onDismiss: { reviewStartsWithDeploy = false }) {
            ReviewChangesSheet(editor: editor, startsWithDeploy: reviewStartsWithDeploy)
        }
        .sheet(isPresented: $isRestoring) {
            RestoreBackupSheet(editor: editor)
        }
        .confirmationDialog(
            "Deploy “\(editor.base.overview.name)”?",
            isPresented: $isConfirmingDeploy,
            titleVisibility: .visible
        ) {
            Button("Deploy") { Task { await editor.deploy() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deployMessage)
        }
        .confirmationDialog("Discard all unsaved changes?", isPresented: $isConfirmingDiscard) {
            Button("Discard Changes", role: .destructive) { editor.discardChanges() }
        }
        .confirmationDialog("Reload and discard unsaved changes?", isPresented: $isConfirmingReload) {
            Button("Discard and Reload", role: .destructive) { Task { await editor.reload(discardingEdits: true) } }
        }
        .alert(
            editor.alert?.title ?? "",
            isPresented: Binding(get: { editor.alert != nil }, set: { if !$0 { editor.alert = nil } }),
            presenting: editor.alert
        ) { alert in
            switch alert.kind {
            case .conflict where editor.isDirty:
                Button("Reload and Discard Edits", role: .destructive) { Task { await editor.reload(discardingEdits: true) } }
                Button("Keep Editing", role: .cancel) {}
            case .conflict:
                Button("Reload") { Task { await editor.reload() } }
                Button("Cancel", role: .cancel) {}
            case .info, .error:
                Button("OK") {}
            }
        } message: { alert in
            Text(alert.message)
        }
        .alert(
            importSummary?.title ?? "",
            isPresented: Binding(get: { importSummary != nil }, set: { if !$0 { importSummary = nil } }),
            presenting: importSummary
        ) { _ in
            Button("OK") {}
        } message: { summary in
            Text(summary.message)
        }
    }

    /// A command from the menu bar (`EditorModel.Request`), the same as the
    /// window's own buttons and menus; Export is the domain editor's.
    private func carryOut(_ request: EditorModel.Request?) {
        guard let request, request != .exportDomain else { return }
        editor.request = nil
        switch request {
        case .review:
            if editor.isDirty && editor.canEdit { isReviewing = true }
        case .saveAndDeploy:
            if editor.isDirty && editor.canEdit {
                reviewStartsWithDeploy = true
                isReviewing = true
            }
        case .deploy:
            if editor.canDeploy { isConfirmingDeploy = true }
        case .restore:
            if !editor.isReadOnly && !editor.isBusy { isRestoring = true }
        case .newDomain:
            if editor.canEdit { newDomain() }
        case .renameDomain:
            if editor.canEdit { renameSelectedDomain() }
        case .removeDomain:
            if let id = selectedDomainID, editor.canEdit(domainID: id) { editor.removeDomain(id) }
        case .importDomains:
            if editor.canEdit { importDomains() }
        case .exportDomain:
            break
        }
    }

    private func newDomain() {
        namePrompt = NamePrompt(title: "New Domain", actionTitle: "Add", initial: "com.example.preferences", domainID: nil)
    }

    private func renameSelectedDomain() {
        if let id = selectedDomainID, let domain = editor.domain(withID: id) {
            namePrompt = NamePrompt(title: "Rename Domain", actionTitle: "Rename", initial: domain.name, domainID: id)
        }
    }

    private var selectedDomainID: PreferenceDomain.ID? {
        if case .domain(let id) = editor.selection { return id }
        return nil
    }

    private var deployMessage: String {
        "This deploys the saved Blueprint to its scope. If it changed on the server since it was loaded, nothing is deployed.\n\n\(editor.base.scopeDescription)"
    }

    private var deployHelp: String {
        if editor.isReadOnly { return JamfPlatform.APIError.divisionLocked }
        if editor.isDirty { return "Save your changes first; Save & Deploy in the review does both" }
        return "Deploy the saved Blueprint"
    }

    @ViewBuilder
    private var statusBanner: some View {
        if editor.isReadOnly {
            Label {
                Text(JamfPlatform.APIError.divisionLocked)
            } icon: {
                Image(systemName: "lock.fill").foregroundStyle(.orange)
            }
            .font(.caption)
        } else if editor.isBusy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(editor.operation.label).font(.caption)
                RetryWaitStatus(waits: model.editorWaits)
            }
        } else if let status = editor.status {
            // The last result, in the window rather than an alert.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label {
                    Text(status.message)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    if status.isDone {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .accessibilityLabel("\(status.title): \(status.message)")
                Spacer(minLength: 0)
                Button {
                    editor.status = nil
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Dismiss this message")
            }
        } else if editor.isDirty {
            Label {
                Text("Unsaved changes · save before deploying")
            } icon: {
                Image(systemName: "pencil.circle.fill").foregroundStyle(.tint)
            }
            .font(.caption)
        }
    }

    private var domainList: some View {
        List(selection: $editor.selection) {
            ForEach(editor.document.payloads) { payload in
                Section {
                    if let problem = payload.problem {
                        WarningLabel(problem)
                            .font(.caption)
                    }
                    ForEach(payload.domains) { domain in
                        DomainRow(domain: domain)
                            .tag(EditorSelection.domain(domain.id))
                            .contextMenu {
                                Button("Rename…") {
                                    namePrompt = NamePrompt(title: "Rename Domain", actionTitle: "Rename", initial: domain.name, domainID: domain.id)
                                }
                                .disabled(!editor.canEdit || !payload.isEditable)
                                Button("Remove", role: .destructive) { editor.removeDomain(domain.id) }
                                    .disabled(!editor.canEdit || !payload.isEditable)
                            }
                    }
                } header: {
                    Text(payload.displayName)
                }
            }
            Section("Blueprint JSON") {
                Label("Raw JSON", systemImage: "curlybraces")
                    .tag(EditorSelection.rawJSON)
            }
        }
        .onDeleteCommand {
            if let id = selectedDomainID, editor.canEdit { editor.removeDomain(id) }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            Menu {
                Button("New Domain…", action: newDomain)
                Button("Import Domains from File…", action: importDomains)
                Divider()
                Button("Rename Selected Domain…", action: renameSelectedDomain)
                .disabled(selectedDomainID == nil)
                Button("Remove Selected Domain", role: .destructive) {
                    if let id = selectedDomainID { editor.removeDomain(id) }
                }
                .disabled(selectedDomainID == nil)
            } label: {
                Label("Domains", systemImage: "plus").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add, import, rename or remove domains")
            .disabled(!editor.canEdit)

            Menu {
                Button("Reload from Server") {
                    if editor.isDirty { isConfirmingReload = true } else { Task { await editor.reload() } }
                }
                Button("Discard Changes…") { isConfirmingDiscard = true }
                    .disabled(!editor.isDirty)
                Divider()
                Button("Restore from Backup…") { isRestoring = true }
                    .disabled(editor.isReadOnly)
                Button("Show Backups in Finder") {
                    let directory = BackupStore.directory(for: editor.blueprintID, root: editor.backupRoot)
                    let url = FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) ? directory : editor.backupRoot
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Reload, discard changes, restore or show backups")
            .disabled(editor.isBusy)

            Spacer()

            Button("Deploy…") { isConfirmingDeploy = true }
                .disabled(!editor.canDeploy)
                .help(deployHelp)
            // ⌘S is Blueprint › Save… in the menu bar.
            Button("Save…") { isReviewing = true }
                .buttonStyle(.borderedProminent)
                .disabled(!editor.isDirty || !editor.canEdit)
                .help("Review the changes, then save them to Jamf Pro")
        }
        .controlSize(.regular)
        .padding(10)
    }

    private func importDomains() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList, .xml, UTType(filenameExtension: "mobileconfig") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .plist (one domain, named after the file) or a .mobileconfig."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try PlistImporter.domains(from: Data(contentsOf: url), fileName: url.lastPathComponent)
            guard !imported.isEmpty else {
                editor.show(EditorModel.Status(title: "Nothing Imported", message: "No preference domains were found in \(url.lastPathComponent)."))
                return
            }
            let summary = editor.importDomains(imported, near: selectedDomainID).summary(fileName: url.lastPathComponent)
            // A result, shown in the window like Saved; only a failure is an alert.
            editor.show(EditorModel.Status(title: summary.title, message: summary.message))
        } catch {
            importSummary = ImportSummary(title: "Import Failed", message: error.localizedDescription)
        }
    }
}

/// JTKit's wait before a retry ("Jamf asked to wait 40 s"), with Stop, which
/// ends the waits of this place only (the editors, discovery or Settings):
/// the request isn't sent again and the operation says what that left.
struct RetryWaitStatus: View {
    let waits: RequestWaits

    var body: some View {
        if let text = waits.statusText {
            HStack(spacing: 6) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Stop") { waits.cancelAll() }
                    .controlSize(.small)
                    .help("Stop waiting; the request isn’t sent again")
            }
        }
    }
}

private struct DomainRow: View {
    let domain: PreferenceDomain

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(domain.name)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 4) {
                if let entries = domain.entries {
                    ForEach(Array(Set(entries.map(\.mode))).sorted(), id: \.self) { mode in
                        StatusBadge(mode, style: .neutral)
                    }
                    let count = entries.reduce(0) { $0 + $1.settings.count }
                    Text("\(count) key\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    WarningLabel("Unexpected shape")
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Why typed text can't be used: primary text beside the system's error
/// symbol, readable at caption size (red caption text isn't), and read by
/// VoiceOver as an error.
struct ValidationMessage: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
        .font(.caption)
        .accessibilityLabel("Error: \(text)")
    }
}

/// A small sheet asking for a name, with validation.
struct NameSheet: View {
    let title: String
    let actionTitle: String
    let initial: String
    let validate: (String) -> String?
    let commit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        let error = validate(name)
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Preference domain", text: $name, prompt: Text("com.example.app"))
                .textFieldStyle(.roundedBorder)
                .font(.body.monospaced())
                .onSubmit(submit)
            if let error, !name.isEmpty {
                ValidationMessage(error)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle, action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(error != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { name = initial }
    }

    private func submit() {
        guard validate(name) == nil else { return }
        commit(name)
        dismiss()
    }
}
