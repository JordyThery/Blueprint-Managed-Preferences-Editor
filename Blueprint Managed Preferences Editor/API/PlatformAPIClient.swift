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

/// Talks to the Jamf Platform API for one tenant through JTKit: its Jamf token
/// provider signs in, and its HTTP client adds `X-Environment-Id`, checks every
/// request against `RequestAllowList`, retries by JTKit's rules and writes each
/// attempt, wait and refusal to the activity log. JTKit's errors become `APIError`,
/// so the app's messages stay the same.
nonisolated struct PlatformAPIClient: Sendable {
    /// Which failures a request may be automatically retried on.
    enum RetryPolicy: Sendable {
        /// Retry on 429, 5xx and short network drops. Use for GET and the
        /// full-replacement PATCH, which are safe to repeat.
        case idempotent
        /// Retry only on 429, where the server guarantees it did not process the
        /// request. Use for actions with side effects, such as deploy.
        case rateLimitOnly
    }

    let credentials: PlatformCredentials
    private let tokens: JamfTokenProvider
    private let http: HTTPClient

    /// - Parameters:
    ///   - log: JTKit's activity log; nil records nothing (tests).
    ///   - sleep: the wait before a retry, injectable for tests.
    init(
        credentials: PlatformCredentials,
        session: URLSession = .shared,
        log: ActivityLog?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.credentials = credentials
        let recorder = RequestRecorder(
            session: session,
            log: log,
            service: ConnectionService.jamfPlatform.displayName,
            connection: credentials.connectionName.isEmpty ? nil : credentials.connectionName
        )
        let secret = credentials.clientSecret
        tokens = JamfTokenProvider(
            tokenURL: credentials.region.baseURL.appending(path: "auth/token"),
            method: .apiClient(clientID: credentials.clientID),
            secret: { secret },
            recorder: recorder
        )
        http = HTTPClient(
            baseURL: credentials.region.baseURL,
            tokens: tokens,
            recorder: recorder,
            headers: ["X-Environment-Id": credentials.environmentID],
            permits: { RequestAllowList.isPermitted(method: $0.method.uppercased(), path: $0.path) },
            sleep: sleep
        )
    }

    // MARK: Public API

    /// Sends a request to `{region}.api.jamfcloud.com{path}` and returns the response
    /// for any 2xx status. Non-2xx statuses are thrown as `APIError.http`.
    /// `path` must already be valid percent-encoded path text; it is not encoded again.
    func send(
        method: String,
        path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil,
        retryPolicy: RetryPolicy = .idempotent
    ) async throws -> HTTPResponse {
        let request = HTTPRequest(
            method: method,
            path: path,
            query: query,
            body: body,
            contentType: contentType,
            safeToRepeat: retryPolicy == .idempotent
        )
        do {
            return try await http.send(request)
        } catch let error as HTTPError {
            throw Self.apiError(error)
        }
    }

    /// Fetches a fresh token, ignoring the cache. Used by "Test connection".
    func refreshToken() async throws {
        await tokens.forgetToken()
        do {
            _ = try await tokens.token()
        } catch let error as HTTPError {
            throw Self.apiError(error)
        }
    }

    /// JTKit's error as the app's, with any server text redacted.
    static func apiError(_ error: HTTPError) -> APIError {
        switch error {
        case let .refused(method, path):
            return .refused(method: method, path: path)
        case let .transport(_, _, _, message):
            return .transport(message)
        case let .status(response, _, _, duringSignIn):
            let body = Redaction.body(response.data, contentType: response.header("Content-Type"))
            return duringSignIn
                ? .authentication(status: response.status, body: body)
                : .http(status: response.status, details: PlatformErrorDetails(data: response.data), body: body)
        case let .invalidURL(message), let .decoding(message):
            return .invalidResponse(message)
        }
    }
}
