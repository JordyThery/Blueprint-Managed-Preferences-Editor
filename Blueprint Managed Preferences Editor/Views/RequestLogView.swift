import SwiftUI

/// Shows every API request and response. Secrets are redacted before logging.
struct RequestLogView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: RequestLogEntry.ID?

    var body: some View {
        let entries = model.requestLog.entries
        NavigationSplitView {
            List(entries.reversed(), selection: $selection) { entry in
                RequestLogRow(entry: entry)
                    .tag(entry.id)
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 380)
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("No Requests Yet", systemImage: "network")
                }
            }
        } detail: {
            if let entry = entries.first(where: { $0.id == selection }) {
                MonospacedTextView(text: Self.transcript(for: entry))
            } else {
                ContentUnavailableView("Select a Request", systemImage: "arrow.left.arrow.right")
            }
        }
        .toolbar {
            Button("Clear", systemImage: "trash") {
                selection = nil
                model.requestLog.clear()
            }
            .disabled(entries.isEmpty)
        }
        .navigationTitle("Request Log")
    }

    private static func transcript(for entry: RequestLogEntry) -> String {
        var lines: [String] = []
        lines.append("\(entry.method) \(entry.url)")
        lines.append("Date: \(entry.date.formatted(.iso8601))   Attempt: \(entry.attempt)")
        if let duration = entry.duration {
            lines.append("Duration: \(Int(duration * 1000)) ms")
        }
        lines.append("")
        lines.append("── Request headers ──")
        lines.append(contentsOf: entry.requestHeaders.map { "\($0.0): \($0.1)" })
        if let body = entry.requestBody {
            lines.append("")
            lines.append("── Request body ──")
            lines.append(body)
        }
        lines.append("")
        if let error = entry.errorDescription {
            lines.append("── Error ──")
            lines.append(error)
        }
        if let status = entry.statusCode {
            lines.append("── Response: HTTP \(status) ──")
            lines.append(contentsOf: entry.responseHeaders.map { "\($0.0): \($0.1)" })
            if let body = entry.responseBody {
                lines.append("")
                lines.append(body)
            }
        }
        return lines.joined(separator: "\n")
    }
}

private struct RequestLogRow: View {
    let entry: RequestLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.method)
                    .font(.caption.monospaced().weight(.semibold))
                Text(statusText)
                    .font(.caption.monospaced())
                    .foregroundStyle(statusColor)
                Spacer()
                Text(entry.date.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(URL(string: entry.url).map { $0.path() + ($0.query().map { "?\($0)" } ?? "") } ?? entry.url)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var statusText: String {
        if let status = entry.statusCode { return String(status) }
        return entry.errorDescription == nil ? "…" : "ERR"
    }

    private var statusColor: Color {
        guard let status = entry.statusCode else { return .red }
        switch status {
        case 200..<300: return .green
        case 400..<500: return .orange
        default: return .red
        }
    }
}
