import JTKit
import SwiftUI

/// Shows old and new values per domain and key before saving.
struct ReviewChangesSheet: View {
    let editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDeploy = false

    /// Changes of one payload and domain, keyed by the payload's location so two
    /// payloads with the same display name stay separate.
    private struct ChangeGroup: Identifiable {
        let id: String
        let title: String
        var changes: [PreferenceChange]
    }

    private static func groups(from changes: [PreferenceChange]) -> [ChangeGroup] {
        var groups: [ChangeGroup] = []
        for change in changes {
            let id = "\(change.payloadID)|\(change.domain)"
            if let index = groups.firstIndex(where: { $0.id == id }) {
                groups[index].changes.append(change)
            } else {
                groups.append(ChangeGroup(id: id, title: "\(change.payloadName) — \(change.domain)", changes: [change]))
            }
        }
        return groups
    }

    var body: some View {
        let changes = editor.document.changes
        let groups = Self.groups(from: changes)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Review Changes").font(.title3.weight(.semibold))
                Text("“\(editor.base.overview.name)” · \(changes.count) change\(changes.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if changes.isEmpty {
                ContentUnavailableView("No Differences", systemImage: "equal.circle", description: Text("The edits cancel out; there is nothing to save."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups) { group in
                        Section(group.title) {
                            ForEach(group.changes) { change in
                                ChangeRow(change: change)
                            }
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Save sends PATCH with the complete steps array (only these changes differ) after checking the blueprint hasn't changed on the server and writing a backup. The blueprint then shows Out of Date until deployed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save & Deploy…") { isConfirmingDeploy = true }
                        .disabled(changes.isEmpty)
                    Button("Save") {
                        dismiss()
                        Task { await editor.save(andDeploy: false) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(changes.isEmpty)
                }
            }
            .padding()
        }
        .frame(width: 760, height: 540)
        .confirmationDialog(
            "Save and deploy “\(editor.base.overview.name)”?",
            isPresented: $isConfirmingDeploy,
            titleVisibility: .visible
        ) {
            Button("Save & Deploy") {
                dismiss()
                Task { await editor.save(andDeploy: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("After saving, the blueprint is deployed to its scope.\n\n\(editor.base.scopeDescription)")
        }
    }
}

private struct ChangeRow: View {
    let change: PreferenceChange

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(change.keyPath)
                    .font(.callout.monospaced().weight(.medium))
                    .textSelection(.enabled)
            }
            if let old = change.oldValue {
                valueLine(prefix: "−", text: old, color: .red)
            }
            if let new = change.newValue {
                valueLine(prefix: "+", text: new, color: .green)
            }
        }
        .padding(.vertical, 2)
    }

    private func valueLine(prefix: String, text: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(prefix)
                .font(.callout.monospaced().weight(.bold))
                .foregroundStyle(color)
            Text(text)
                .font(.callout.monospaced())
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(.leading, 22)
    }

    private var icon: String {
        switch change.kind {
        case .added: "plus.circle.fill"
        case .removed: "minus.circle.fill"
        case .changed: "pencil.circle.fill"
        }
    }

    private var color: Color {
        switch change.kind {
        case .added: .green
        case .removed: .red
        case .changed: .orange
        }
    }
}
