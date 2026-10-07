import AppKit
import SwiftUI

/// An editable outline of plist nodes with Key, Type and Value columns, in the
/// style of Xcode's property list editor.
struct PlistOutlineView: View {
    struct Actions {
        var setKey: (PlistNode.ID, String) -> Void
        /// Returns an error message, or nil if the key is valid.
        var validateKey: (PlistNode.ID, String) -> String?
        var setValue: (PlistNode.ID, PlistValue) -> Void
        var setType: (PlistNode.ID, PlistType) -> Void
        var delete: () -> Void
        var duplicate: () -> Void
    }

    /// A display row. Array elements are labelled "Item n" instead of a key.
    struct Row: Identifiable {
        let node: PlistNode
        let arrayIndex: Int?
        let children: [Row]?
        var id: PlistNode.ID { node.id }

        static func rows(from nodes: [PlistNode], inArray: Bool) -> [Row] {
            nodes.enumerated().map { index, node in
                let children = node.value.children.map { rows(from: $0, inArray: node.value.type == .array) }
                return Row(node: node, arrayIndex: inArray ? index : nil, children: children?.isEmpty == true ? nil : children)
            }
        }
    }

    let nodes: [PlistNode]
    @Binding var selection: Set<PlistNode.ID>
    let isEditable: Bool
    let actions: Actions

    var body: some View {
        Table(Row.rows(from: nodes, inArray: false), children: \.children, selection: $selection) {
            TableColumn("Key") { row in
                if let index = row.arrayIndex {
                    Text("Item \(index)")
                        .foregroundStyle(.secondary)
                } else {
                    CommitTextField(
                        text: row.node.key,
                        placeholder: "Key",
                        isEditable: isEditable,
                        validate: { actions.validateKey(row.id, $0) },
                        commit: { actions.setKey(row.id, $0) }
                    )
                }
            }
            .width(min: 140, ideal: 260)

            TableColumn("Type") { row in
                TypeCell(value: row.node.value, isEditable: isEditable) { actions.setType(row.id, $0) }
            }
            .width(min: 95, ideal: 110, max: 140)

            TableColumn("Value") { row in
                ValueCell(value: row.node.value, isEditable: isEditable) { actions.setValue(row.id, $0) }
            }
        }
        .contextMenu(forSelectionType: PlistNode.ID.self) { ids in
            if !ids.isEmpty {
                Button("Duplicate") { selection = ids; actions.duplicate() }
                    .disabled(!isEditable)
                Button("Delete", role: .destructive) { selection = ids; actions.delete() }
                    .disabled(!isEditable)
            }
        }
        .onDeleteCommand {
            if isEditable { actions.delete() }
        }
        .overlay {
            if nodes.isEmpty {
                ContentUnavailableView("No Keys", systemImage: "list.bullet.indent", description: Text("Click + to add a key."))
            }
        }
    }
}

private struct TypeCell: View {
    let value: PlistValue
    let isEditable: Bool
    let change: (PlistType) -> Void

    var body: some View {
        Picker("Type", selection: Binding<PlistType?>(
            get: { value.type },
            set: { if let type = $0, type != value.type { change(type) } }
        )) {
            ForEach(PlistType.allCases) { Text($0.rawValue).tag(Optional($0)) }
            if value.type == nil {
                Text("Null").tag(PlistType?.none)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .disabled(!isEditable)
    }
}

private struct ValueCell: View {
    let value: PlistValue
    let isEditable: Bool
    let commit: (PlistValue) -> Void

    var body: some View {
        switch value {
        case .boolean(let flag):
            Picker("Value", selection: Binding(get: { flag }, set: { if $0 != flag { commit(.boolean($0)) } })) {
                Text("true").tag(true)
                Text("false").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
            .disabled(!isEditable)
        case .array, .dictionary:
            Text(value.editText)
                .foregroundStyle(.secondary)
        case .null:
            Text("null")
                .foregroundStyle(.secondary)
                .help("A JSON null. Change the type to edit it.")
        case .string, .integer, .real, .date, .data:
            if let type = value.type {
                CommitTextField(
                    text: value.editText,
                    placeholder: placeholder(for: type),
                    isEditable: isEditable,
                    monospaced: type == .data,
                    validate: { text in
                        if case .failure(let error) = PlistParsing.value(from: text, as: type) { return error.message }
                        return nil
                    },
                    commit: { text in
                        if case .success(let parsed) = PlistParsing.value(from: text, as: type) { commit(parsed) }
                    }
                )
            }
        }
    }

    private func placeholder(for type: PlistType) -> String {
        switch type {
        case .date: "2026-01-31T09:00:00Z"
        case .data: "Base64"
        case .integer: "0"
        case .real: "0.0"
        default: ""
        }
    }
}

/// A text field that commits on Return or when focus leaves, validates first,
/// and reverts on Escape. Invalid input stays visible in red with the reason as a tooltip.
struct CommitTextField: View {
    let text: String
    var placeholder: String = ""
    var isEditable: Bool = true
    var monospaced: Bool = false
    let validate: (String) -> String?
    let commit: (String) -> Void

    @State private var draft = ""
    @State private var error: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(monospaced ? .body.monospaced() : .body)
            .foregroundStyle(error == nil ? Color.primary : Color.red)
            .focused($isFocused)
            .disabled(!isEditable)
            .help(error ?? "")
            .onAppear { draft = text }
            .onChange(of: text) { draft = text; error = nil }
            .onSubmit(commitDraft)
            .onChange(of: isFocused) { _, focused in
                if !focused { commitDraft() }
            }
            .onExitCommand {
                draft = text
                error = nil
            }
            .overlay(alignment: .trailing) {
                if error != nil {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .help(error ?? "")
                }
            }
    }

    private func commitDraft() {
        guard draft != text else {
            error = nil
            return
        }
        if let message = validate(draft) {
            error = message
            NSSound.beep()
            return
        }
        error = nil
        commit(draft)
    }
}
