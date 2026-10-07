import AppKit
import SwiftUI

/// Lists local backups of a blueprint and PATCHes the chosen backup's steps back.
struct RestoreBackupSheet: View {
    let editor: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [BlueprintBackup] = []
    @State private var selection: BlueprintBackup.ID?
    @State private var isConfirming = false

    private var selectedBackup: BlueprintBackup? {
        backups.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Restore from Backup").font(.title3.weight(.semibold))
                Text("A backup is written before every save. Restoring sends the backup's steps with PATCH; the current server state is backed up first.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()

            Divider()

            List(backups, selection: $selection) { backup in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.date.formatted(date: .abbreviated, time: .standard))
                        Text(backup.url.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(backup.size.formatted(.byteCount(style: .file)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(backup.id)
                .contextMenu {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([backup.url]) }
                }
            }
            .overlay {
                if backups.isEmpty {
                    ContentUnavailableView("No Backups", systemImage: "clock.arrow.circlepath", description: Text("Backups appear here after the first save."))
                }
            }

            Divider()

            HStack {
                if editor.isDirty {
                    Label("Unsaved edits will be discarded.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Restore…") { isConfirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedBackup == nil)
            }
            .padding()
        }
        .frame(width: 560, height: 420)
        .onAppear { backups = BackupStore.backups(for: editor.blueprintID) }
        .confirmationDialog(
            "Restore “\(editor.base.overview.name)” from this backup?",
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button("Restore", role: .destructive) {
                guard let backup = selectedBackup else { return }
                dismiss()
                Task { await editor.restore(from: backup) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The blueprint's steps are replaced with those from \(selectedBackup?.date.formatted(date: .abbreviated, time: .standard) ?? "the backup"). Deploy afterwards to apply them to devices.")
        }
    }
}
