import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Raw JSON debug view: the GET response exactly as received or pretty-printed,
/// and, when there are unsaved edits, the exact PATCH body that Save would send.
struct RawJSONView: View {
    let detail: BlueprintDetail
    var pendingPatchBody: Data?

    @State private var format: Format = .pretty

    enum Format: String, CaseIterable, Identifiable {
        case pretty = "Pretty"
        case exact = "Exact Response"
        case patch = "Pending PATCH Body"
        var id: String { rawValue }
    }

    private var availableFormats: [Format] {
        pendingPatchBody == nil ? [.pretty, .exact] : Format.allCases
    }

    private var effectiveFormat: Format {
        format == .patch && pendingPatchBody == nil ? .pretty : format
    }

    private var data: Data {
        switch effectiveFormat {
        case .pretty: detail.json.serialized(pretty: true)
        case .exact: detail.rawData
        case .patch: pendingPatchBody.flatMap { try? JSONValue(data: $0).serialized(pretty: true) } ?? Data()
        }
    }

    var body: some View {
        let data = data
        VStack(spacing: 0) {
            HStack {
                Picker("Format", selection: $format) {
                    ForEach(availableFormats) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .labelsHidden()
                Text("\(data.count.formatted(.byteCount(style: .file))) · fetched \(detail.fetchedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
                }
                Button("Save…", systemImage: "square.and.arrow.down") {
                    save(data)
                }
            }
            .padding(8)
            if effectiveFormat == .patch {
                Text("This is the body Save sends with PATCH (Content-Type: application/merge-patch+json): the complete steps array, with only the edited payloads changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            Divider()
            MonospacedTextView(text: String(decoding: data, as: UTF8.self))
        }
        .onChange(of: pendingPatchBody) {
            // Leave the PATCH view when the pending body disappears (e.g. after a save),
            // so the picker selection always matches an offered format.
            if pendingPatchBody == nil && format == .patch { format = .pretty }
        }
    }

    private func save(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let safeName = detail.overview.name.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = effectiveFormat == .patch ? "\(safeName) PATCH.json" : "\(safeName).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Name, state and timestamps of a blueprint.
struct BlueprintHeader: View {
    let detail: BlueprintDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(detail.overview.name)
                    .font(.headline)
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer(minLength: 4)
                if let state = detail.overview.deploymentState?.state {
                    DeploymentStateBadge(state: state)
                }
            }
            if let updated = detail.overview.updated {
                Text("Updated \(detail.overview.updatedDate?.formatted(date: .abbreviated, time: .standard) ?? updated)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(updated)
            }
            if let deployment = detail.overview.deploymentState,
               let started = deployment.lastDeploymentStarted {
                Text("Last deployment \(PlatformDate.parse(started)?.formatted(date: .abbreviated, time: .shortened) ?? started)\(deployment.lastDeploymentState.map { " · \(DeploymentStateKind(rawValue: $0).displayName)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(started)
            }
            Text(detail.id)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
