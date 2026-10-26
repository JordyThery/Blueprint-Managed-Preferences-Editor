import Foundation
import JTKit

/// The Platform API error body: `{ httpStatus, traceId, errors: { code, field, description } }`.
/// `errors` is parsed defensively as either a single object or an array of objects.
nonisolated struct PlatformErrorDetails: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        var code: String?
        var field: String?
        var description: String?
    }

    var httpStatus: Int?
    var traceId: String?
    var errors: [Item]

    init?(data: Data) {
        guard let json = try? JSONValue(data: data), let object = json.objectValue else { return nil }
        httpStatus = object["httpStatus"]?.numberValue?.intValue
        traceId = object["traceId"]?.stringValue
        func item(_ value: JSONValue) -> Item? {
            guard value.objectValue != nil else { return nil }
            return Item(
                code: value["code"]?.stringValue,
                field: value["field"]?.stringValue,
                description: value["description"]?.stringValue
            )
        }
        switch object["errors"] {
        case .array(let array): errors = array.compactMap(item)
        case .some(let value): errors = item(value).map { [$0] } ?? []
        case nil: errors = []
        }
        guard httpStatus != nil || traceId != nil || !errors.isEmpty else { return nil }
    }

    func contains(code: String) -> Bool {
        errors.contains { $0.code == code }
    }
}

nonisolated enum APIError: Error, LocalizedError, Sendable {
    case missingCredentials
    /// Refused by the request allow-list before anything reached the network.
    case refused(method: String, path: String)
    case transport(String)
    case invalidResponse(String)
    case authentication(status: Int, body: String?)
    case http(status: Int, details: PlatformErrorDetails?, body: String?)

    var details: PlatformErrorDetails? {
        if case .http(_, let details, _) = self { return details }
        return nil
    }

    func hasErrorCode(_ code: String) -> Bool {
        details?.contains(code: code) ?? false
    }

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "No complete connection is configured. Open Settings and add a region, Environment ID, Client ID and Client Secret."
        case .refused(let method, let path):
            return "Blocked \(method) \(path). The app only sends GET requests, token requests, and blueprint update and deploy requests; it never creates, deletes or undeploys."
        case .transport(let message):
            return "Network error: \(message)"
        case .invalidResponse(let message):
            return "Unexpected response: \(message)"
        case .authentication(let status, let body):
            var message = "Authentication failed (HTTP \(status)). Check the Client ID, Client Secret and region."
            if let body, !body.isEmpty { message += "\n\(body.prefix(500))" }
            return Redaction.text(message)
        case .http(let status, let details, let body):
            var lines = ["HTTP \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)"]
            if let details {
                for item in details.errors {
                    var line = item.code ?? "ERROR"
                    if let field = item.field, !field.isEmpty { line += " (\(field))" }
                    if let description = item.description, !description.isEmpty { line += ": \(description)" }
                    lines.append(line)
                }
                if let traceId = details.traceId { lines.append("Trace ID: \(traceId)") }
            } else if let body, !body.isEmpty {
                lines.append(String(body.prefix(500)))
            }
            return Redaction.text(lines.joined(separator: "\n"))
        }
    }
}
