import AppKit
import JTKit
import SwiftUI
import UniformTypeIdentifiers

/// Detail column: one preference domain's management mode and key/value tree.
struct DomainEditorView: View {
    @Bindable var editor: EditorModel
    let domainID: PreferenceDomain.ID

    @State private var selection = Set<PlistNode.ID>()
    @State private var isPasting = false
    @State private var message: ImportMessage?
    @State private var otherDomain: OtherDomainImport?

    struct ImportMessage {
        let title: String
        let text: String
    }

    /// A file without settings for this domain, waiting for "Use …".
    struct OtherDomainImport {
        let imported: ImportedDomain
        let fileName: String
    }

    /// Edits are allowed and the domain's payload has the expected shape.
    private var canEdit: Bool { editor.canEdit(domainID: domainID) }

    var body: some View {
        if let domain = editor.domain(withID: domainID) {
            VStack(spacing: 0) {
                header(domain)
                Divider()
                switch domain.content {
                case .unsupported(let raw, let reason):
                    VStack(alignment: .leading, spacing: 8) {
                        Label("This domain has an unexpected shape and is shown read-only. It is saved back unchanged.\n\(reason)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .padding([.horizontal, .top])
                        MonospacedTextView(text: raw.serializedString(pretty: true))
                    }
                case .entries:
                    if let entry = editor.currentEntry(of: domain) {
                        PlistOutlineView(
                            nodes: entry.settings,
                            selection: $selection,
                            isEditable: canEdit,
                            actions: actions(entry: entry)
                        )
                        Divider()
                        toolbar(domain: domain, entry: entry)
                    }
                }
            }
            .alert(
                message?.title ?? "",
                isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } }),
                presenting: message
            ) { _ in
                Button("OK") {}
            } message: { message in
                Text(message.text)
            }
            .confirmationDialog(
                "Use the settings of “\(otherDomain?.imported.name ?? "")”?",
                isPresented: Binding(get: { otherDomain != nil }, set: { if !$0 { otherDomain = nil } }),
                titleVisibility: .visible,
                presenting: otherDomain
            ) { pending in
                Button("Replace Settings") {
                    if let entry = editor.currentEntry(of: domain) {
                        replace(domain: domain, entry: entry, with: pending.imported, fileName: pending.fileName)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text("\(pending.fileName) has no settings for \(domain.name). Its settings for \(pending.imported.name) would replace this domain’s settings.")
            }
            .sheet(isPresented: $isPasting) {
                PastePlistSheet { nodes in
                    if let entry = editor.currentEntry(of: domain) { replaceSettings(entry: entry, with: nodes) }
                }
            }
        } else {
            ContentUnavailableView("Domain Not Found", systemImage: "questionmark.folder")
        }
    }

    // MARK: Header

    private func header(_ domain: PreferenceDomain) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(domain.name)
                .font(.title3.monospaced().weight(.semibold))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let entries = domain.entries, let entry = editor.currentEntry(of: domain) {
                if entries.count > 1 {
                    Picker("Entry", selection: Binding(
                        get: { entry.id },
                        set: { editor.selectedEntryIDs[domain.id] = $0 }
                    )) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, item in
                            Text("\(item.mode) #\(index + 1)").tag(item.id)
                        }
                    }
                    .fixedSize()
                    .help("This domain has several entries for one mode; choose which to edit")
                }
                Picker("Management", selection: Binding(
                    get: { entry.mode },
                    set: { editor.setMode($0, domainID: domain.id, entryID: entry.id) }
                )) {
                    ForEach(modes(including: entry.mode), id: \.self) { Text($0).tag($0) }
                }
                .fixedSize()
                .disabled(!canEdit)
                .help("Forced: always enforced; Set-Once: applied once, users may change it; Often: applied again at every login")
            }
        }
        .padding(12)
    }

    private func modes(including current: String) -> [String] {
        ManagementMode.all.contains(current) ? ManagementMode.all : ManagementMode.all + [current]
    }

    // MARK: Toolbar

    private func toolbar(domain: PreferenceDomain, entry: MCXEntry) -> some View {
        let single = selection.count == 1 ? selection.first : nil
        let selectedNode = single.flatMap { entry.settings.node(withID: $0) }
        return HStack(spacing: 4) {
            Group {
                Button { addItem(entry: entry) } label: { Label("Add Item", systemImage: "plus").labelStyle(.iconOnly) }
                    .help("Add item after the selection")
                Button { addChild(entry: entry) } label: { Label("Add Child", systemImage: "plus.square.on.square").labelStyle(.iconOnly) }
                    .help("Add child to the selected array or dictionary")
                    .disabled(selectedNode?.value.type?.isContainer != true)
                Button { delete(entry: entry) } label: { Label("Delete", systemImage: "minus").labelStyle(.iconOnly) }
                    .help("Delete selected items")
                    .disabled(selection.isEmpty)
                Button { duplicate(entry: entry) } label: { Label("Duplicate", systemImage: "plus.rectangle.on.rectangle").labelStyle(.iconOnly) }
                    .help("Duplicate selected items")
                    .disabled(selection.isEmpty)
                Divider().frame(height: 16)
                Button { move(entry: entry, by: -1) } label: { Label("Move Up", systemImage: "arrow.up").labelStyle(.iconOnly) }
                    .help("Move up")
                    .disabled(single == nil)
                Button { move(entry: entry, by: 1) } label: { Label("Move Down", systemImage: "arrow.down").labelStyle(.iconOnly) }
                    .help("Move down")
                    .disabled(single == nil)
            }
            .disabled(!canEdit)
            Spacer()
            Menu("Import") {
                Button("Replace Settings from File…") { importFromFile(domain: domain, entry: entry) }
                Button("Paste Property List…") { isPasting = true }
            }
            .fixedSize()
            .disabled(!canEdit)
            Button("Export…") { export(domain: domain, entry: entry) }
        }
        .buttonStyle(.borderless)
        .padding(8)
    }

    // MARK: Tree actions

    private func actions(entry: MCXEntry) -> PlistOutlineView.Actions {
        PlistOutlineView.Actions(
            setKey: { id, key in
                editor.modifySettings("Rename Key", domainID: domainID, entryID: entry.id) { nodes in
                    nodes.modifyNode(withID: id) { $0.key = key }
                }
            },
            validateKey: { id, key in
                let trimmed = key.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return "The key can’t be empty." }
                return siblingKeys(of: id, in: entry.settings).contains(key) ? "“\(key)” already exists at this level." : nil
            },
            setValue: { id, value in
                editor.modifySettings("Edit Value", domainID: domainID, entryID: entry.id) { nodes in
                    nodes.modifyNode(withID: id) { $0.value = value }
                }
            },
            setType: { id, type in
                editor.modifySettings("Change Type", domainID: domainID, entryID: entry.id) { nodes in
                    nodes.modifyNode(withID: id) { $0.value = $0.value.converted(to: type) }
                }
            },
            delete: { delete(entry: entry) },
            duplicate: { duplicate(entry: entry) }
        )
    }

    private func siblingKeys(of id: PlistNode.ID, in nodes: [PlistNode]) -> [String] {
        guard let location = nodes.location(of: id) else { return [] }
        let siblings = location.parentID.flatMap { nodes.node(withID: $0)?.value.children } ?? nodes
        return siblings.filter { $0.id != id }.map(\.key)
    }

    private func addItem(entry: MCXEntry) {
        let newID = UUID()
        editor.modifySettings("Add Item", domainID: domainID, entryID: entry.id) { nodes in
            if let selected = selection.first, selection.count == 1, let location = nodes.location(of: selected) {
                nodes.modifyChildren(of: location.parentID) { siblings, isArray in
                    let key = isArray ? "" : siblings.uniqueKey(base: "New Item")
                    siblings.insert(PlistNode(id: newID, key: key, value: .string("")), at: location.index + 1)
                }
            } else {
                nodes.append(PlistNode(id: newID, key: nodes.uniqueKey(base: "New Item"), value: .string("")))
            }
        }
        selection = [newID]
    }

    private func addChild(entry: MCXEntry) {
        guard let parentID = selection.first, selection.count == 1 else { return }
        let newID = UUID()
        editor.modifySettings("Add Child", domainID: domainID, entryID: entry.id) { nodes in
            nodes.modifyChildren(of: parentID) { children, isArray in
                let key = isArray ? "" : children.uniqueKey(base: "New Item")
                children.append(PlistNode(id: newID, key: key, value: .string("")))
            }
        }
        selection = [newID]
    }

    private func delete(entry: MCXEntry) {
        guard !selection.isEmpty else { return }
        let ids = selection
        editor.modifySettings(ids.count == 1 ? "Delete Item" : "Delete Items", domainID: domainID, entryID: entry.id) { nodes in
            nodes.removeNodes(withIDs: ids)
        }
        selection = []
    }

    private func duplicate(entry: MCXEntry) {
        guard !selection.isEmpty else { return }
        var newIDs = Set<PlistNode.ID>()
        let ids = selection
        editor.modifySettings("Duplicate", domainID: domainID, entryID: entry.id) { nodes in
            for id in ids {
                guard let location = nodes.location(of: id) else { continue }
                nodes.modifyChildren(of: location.parentID) { siblings, isArray in
                    guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
                    let original = siblings[index]
                    let copy = original.duplicated(key: isArray ? "" : siblings.uniqueKey(base: "\(original.key) copy"))
                    siblings.insert(copy, at: index + 1)
                    newIDs.insert(copy.id)
                }
            }
        }
        selection = newIDs
    }

    private func move(entry: MCXEntry, by offset: Int) {
        guard let id = selection.first, selection.count == 1 else { return }
        editor.modifySettings(offset < 0 ? "Move Up" : "Move Down", domainID: domainID, entryID: entry.id) { nodes in
            nodes.moveNode(withID: id, by: offset)
        }
    }

    @discardableResult
    private func replaceSettings(entry: MCXEntry, with nodes: [PlistNode]) -> Bool {
        let applied = editor.modifySettings("Replace Settings", domainID: domainID, entryID: entry.id) { $0 = nodes }
        selection = []
        return applied
    }

    // MARK: Import / export

    private func importFromFile(domain: PreferenceDomain, entry: MCXEntry) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList, .xml, UTType(filenameExtension: "mobileconfig") ?? .data]
        panel.message = "Choose a .plist or .mobileconfig. Its settings replace this domain’s settings."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let fileName = url.lastPathComponent
        do {
            let imported = try PlistImporter.domains(from: Data(contentsOf: url), fileName: fileName)
            switch PlistImporter.settingsMatch(forDomain: domain.name, mode: entry.mode, in: imported) {
            case .sameDomain(let match):
                replace(domain: domain, entry: entry, with: match, fileName: fileName)
            case .otherDomain(let match):
                // A single .plist is named after its file, so it rarely matches: ask first.
                otherDomain = OtherDomainImport(imported: match, fileName: fileName)
            case .none:
                message = ImportMessage(title: "Nothing Imported", text: "No settings were found in \(fileName).")
            }
        } catch {
            message = ImportMessage(title: "Import Failed", text: error.localizedDescription)
        }
    }

    private func replace(domain: PreferenceDomain, entry: MCXEntry, with match: ImportedDomain, fileName: String) {
        if replaceSettings(entry: entry, with: match.settings) {
            message = ImportMessage(title: "Imported", text: "Replaced the settings of \(domain.name) with \(counted(match.settings.count, "key")) from \(fileName). Use Undo to revert.")
        } else {
            message = ImportMessage(title: "Nothing Imported", text: "\(fileName) matches the current settings; nothing changed.")
        }
    }

    private func export(domain: PreferenceDomain, entry: MCXEntry) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "\(domain.name).plist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PlistExporter.xmlData(for: entry.settings).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Accepts pasted XML property list (or JSON object) text.
private struct PastePlistSheet: View {
    let commit: ([PlistNode]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste Property List").font(.headline)
            Text("Paste an XML property list dictionary (or a JSON object). It replaces this domain’s settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 260)
                .border(.separator)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Replace Settings", action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func apply() {
        let data = Data(text.utf8)
        if let json = try? LosslessJSON(data: data), let object = json.objectValue {
            commit(Array(jsonObject: object))
            dismiss()
            return
        }
        do {
            guard let first = try PlistImporter.domains(from: data, fileName: "pasted").first else {
                error = "No dictionary found."
                return
            }
            commit(first.settings)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
