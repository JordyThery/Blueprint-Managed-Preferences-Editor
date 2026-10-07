import Foundation
import Observation

/// One logged HTTP exchange. Secrets are redacted before an entry is created.
nonisolated struct RequestLogEntry: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let method: String
    let url: String
    let requestHeaders: [(String, String)]
    let requestBody: String?
    var statusCode: Int?
    var responseHeaders: [(String, String)]
    var responseBody: String?
    var errorDescription: String?
    var duration: TimeInterval?
    var attempt: Int
}

/// In-memory log shown in the Request Log window.
@Observable
final class RequestLog {
    private(set) var entries: [RequestLogEntry] = []
    private let maxEntries = 500

    func append(_ entry: RequestLogEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    func clear() {
        entries.removeAll()
    }
}

/// Redaction helpers used by the API client before anything reaches the log.
nonisolated enum LogRedactor {
    static let placeholder = "<redacted>"
    /// Caps the body text retained per log entry, bounding the log's memory use.
    private static let maxBodyLength = 200_000
    private static let secretHeaders: Set<String> = ["authorization", "cookie", "set-cookie"]
    private static let secretFormFields: Set<String> = ["client_secret"]
    private static let secretJSONKeys: Set<String> = ["access_token", "refresh_token", "id_token", "client_secret"]

    static func headers(_ headers: [String: String]) -> [(String, String)] {
        headers.sorted { $0.key.lowercased() < $1.key.lowercased() }.map { key, value in
            if secretHeaders.contains(key.lowercased()) {
                let scheme = value.split(separator: " ").first.map(String.init) ?? ""
                return (key, scheme.isEmpty ? placeholder : "\(scheme) \(placeholder)")
            }
            return (key, value)
        }
    }

    static func formBody(_ body: String) -> String {
        body.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            if let name = parts.first, secretFormFields.contains(String(name)) {
                return "\(name)=\(placeholder)"
            }
            return String(pair)
        }.joined(separator: "&")
    }

    /// Redacts known secret keys in a JSON body and pretty-prints it.
    /// Non-JSON bodies are returned as text.
    static func body(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }
        let text: String
        if var json = try? JSONValue(data: data) {
            json = redactJSON(json)
            text = json.serializedString(pretty: true)
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        if text.count > maxBodyLength {
            return String(text.prefix(maxBodyLength)) + "\n… (truncated)"
        }
        return text
    }

    private static func redactJSON(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(var object):
            for index in object.members.indices {
                if secretJSONKeys.contains(object.members[index].key) {
                    object.members[index].value = .string(placeholder)
                } else {
                    object.members[index].value = redactJSON(object.members[index].value)
                }
            }
            return .object(object)
        case .array(let array):
            return .array(array.map(redactJSON))
        default:
            return value
        }
    }
}
