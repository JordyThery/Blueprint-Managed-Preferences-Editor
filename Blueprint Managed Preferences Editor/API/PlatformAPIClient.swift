import Foundation
import JTKit

/// The HTTP methods and paths this app may send to the Jamf Platform API.
/// Checked before anything reaches the network; everything else is refused.
nonisolated enum RequestAllowList {
    static let blueprintsPath = ["blueprints", "v1", "blueprints"]

    /// Allowed:
    /// - any GET;
    /// - POST /auth/token;
    /// - PATCH /blueprints/v1/blueprints/{id};
    /// - POST /blueprints/v1/blueprints/{id}/deploy.
    /// No create, no DELETE, no undeploy.
    static func isPermitted(method: String, path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        // Each segment is judged by its percent-decoded form: no empty or dot
        // segments, and no encoded separators (%2F, %5C) that a server could
        // decode before routing and so change which resource is addressed.
        for segment in segments {
            guard let decoded = segment.removingPercentEncoding,
                  !decoded.isEmpty, decoded != ".", decoded != "..",
                  !decoded.contains("/"), !decoded.contains("\\") else { return false }
        }
        let isBlueprints = segments.starts(with: blueprintsPath)
        switch method {
        case "GET":
            return true
        case "POST":
            if segments == ["auth", "token"] { return true }
            return isBlueprints && segments.count == 5 && segments[4] == "deploy"
        case "PATCH":
            return isBlueprints && segments.count == 4
        default:
            return false
        }
    }
}

/// Makes JTKit's Jamf Platform API client for one tenant, with this app's
/// allow-list (`RequestAllowList`) and its own hint when a request is refused.
/// JTKit signs in, adds `X-Environment-Id`, retries by its rules, reads error
/// answers and writes each attempt, wait and refusal to the activity log.
nonisolated enum PlatformAPIClient {
    /// Shown below a refused request, before JTKit's standard hints.
    static let refusedHint = "The app only sends GET requests, token requests, and blueprint update and deploy requests; it never creates, deletes or undeploys."

    /// - Parameters:
    ///   - log: JTKit's activity log; nil records nothing (tests).
    ///   - sleep: the wait before a retry, injectable for tests.
    /// - Throws: `JamfPlatformError` when the Environment ID isn't a UUID.
    static func make(
        credentials: PlatformCredentials,
        session: URLSession = .shared,
        log: ActivityLog?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws -> JamfPlatform.Client {
        let secret = credentials.clientSecret
        return try JamfPlatform.Client(
            connection: credentials.connection,
            secret: { secret },
            recorder: recorder(for: credentials, session: session, log: log),
            permits: permits,
            hints: hints(for:),
            sleep: sleep
        )
    }

    /// Writes this tenant's requests to the activity log, under its name.
    static func recorder(for credentials: PlatformCredentials, session: URLSession = .shared, log: ActivityLog?) -> RequestRecorder {
        RequestRecorder(
            session: session,
            log: log,
            service: ConnectionService.jamfPlatform.displayName,
            connection: credentials.connectionName.isEmpty ? nil : credentials.connectionName
        )
    }

    /// The allow-list, as JTKit's client asks for it.
    static let permits: @Sendable (HTTPRequest) -> Bool = {
        RequestAllowList.isPermitted(method: $0.method.uppercased(), path: $0.path)
    }

    /// The app's own hints for an error.
    static func hints(for error: JamfPlatformError) -> [String] {
        if case .refused = error.kind { return [refusedHint] }
        return []
    }
}
