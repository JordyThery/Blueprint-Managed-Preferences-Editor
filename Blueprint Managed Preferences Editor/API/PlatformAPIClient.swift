import Foundation

/// Talks to the Jamf Platform API for one tenant: OAuth2 client-credentials tokens,
/// request building (base URL + `X-Environment-Id`), error decoding, retry with
/// exponential backoff on 429/5xx, and redacted request logging.
actor PlatformAPIClient {
    nonisolated struct Response: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let data: Data
    }

    /// Which failures a request may be automatically retried on.
    nonisolated enum RetryPolicy: Sendable {
        /// Retry on 429, 5xx and transient network errors. Use for GET and the
        /// full-replacement PATCH, which are safe to repeat.
        case idempotent
        /// Retry only on 429, where the server guarantees it did not process the
        /// request. Use for actions with side effects, such as deploy.
        case rateLimitOnly
    }

    private struct CachedToken: Sendable {
        let value: String
        let expiry: Date
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double?
    }

    nonisolated let credentials: PlatformCredentials
    private let session: URLSession
    private let log: @MainActor @Sendable (RequestLogEntry) -> Void
    private var cachedToken: CachedToken?
    private var tokenTask: Task<CachedToken, Error>?

    private let maxAttempts = 4
    /// Refresh this long before the token actually expires.
    private let tokenRefreshMargin: TimeInterval = 60

    init(
        credentials: PlatformCredentials,
        session: URLSession = .shared,
        log: @escaping @MainActor @Sendable (RequestLogEntry) -> Void
    ) {
        self.credentials = credentials
        self.session = session
        self.log = log
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
    ) async throws -> Response {
        guard var components = URLComponents(url: credentials.region.baseURL, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse("Invalid base URL")
        }
        components.percentEncodedPath = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw APIError.invalidResponse("Invalid URL for path \(path)") }

        var didRefreshAfter401 = false
        var attempt = 1
        while true {
            let token = try await validToken()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.httpBody = body
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(credentials.environmentID, forHTTPHeaderField: "X-Environment-Id")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }

            let result: Response
            do {
                result = try await perform(request, attempt: attempt, logBody: LogRedactor.body(body))
            } catch let error as URLError {
                if retryPolicy == .idempotent && attempt < maxAttempts && Self.isTransient(error) {
                    try await Task.sleep(for: .seconds(backoffDelay(attempt: attempt, retryAfter: nil)))
                    attempt += 1
                    continue
                }
                throw APIError.transport(error.localizedDescription)
            }

            switch result.statusCode {
            case 200..<300:
                return result
            case 401 where !didRefreshAfter401:
                // The token may have been revoked or expired early: fetch a new one once.
                didRefreshAfter401 = true
                cachedToken = nil
                continue
            case 429 where attempt < maxAttempts,
                 500..<600 where retryPolicy == .idempotent && attempt < maxAttempts:
                let delay = backoffDelay(attempt: attempt, retryAfter: result.headers.first { $0.key.lowercased() == "retry-after" }?.value)
                try await Task.sleep(for: .seconds(delay))
                attempt += 1
                continue
            default:
                throw APIError.http(
                    status: result.statusCode,
                    details: PlatformErrorDetails(data: result.data),
                    body: String(data: result.data, encoding: .utf8)
                )
            }
        }
    }

    /// Fetches a fresh token, ignoring the cache. Used by "Test connection".
    func refreshToken() async throws {
        cachedToken = nil
        _ = try await validToken()
    }

    // MARK: Token handling

    private func validToken() async throws -> String {
        if let cachedToken, cachedToken.expiry.timeIntervalSinceNow > tokenRefreshMargin {
            return cachedToken.value
        }
        // Coalesce concurrent refreshes into a single token request.
        if let tokenTask {
            return try await tokenTask.value.value
        }
        let task = Task { try await self.fetchToken() }
        tokenTask = task
        defer { tokenTask = nil }
        let token = try await task.value
        cachedToken = token
        return token.value
    }

    private func fetchToken() async throws -> CachedToken {
        let url = credentials.region.baseURL.appending(path: "auth/token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let form = [
            ("grant_type", "client_credentials"),
            ("client_id", credentials.clientID),
            ("client_secret", credentials.clientSecret),
        ]
        let body = form.map { "\($0.0)=\(Self.formEncode($0.1))" }.joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let response: Response
        do {
            response = try await perform(request, attempt: 1, logBody: LogRedactor.formBody(body))
        } catch let error as URLError {
            throw APIError.transport(error.localizedDescription)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.authentication(status: response.statusCode, body: LogRedactor.body(response.data))
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: response.data) else {
            throw APIError.invalidResponse("The token response did not contain an access_token.")
        }
        let lifetime = decoded.expires_in ?? 300
        return CachedToken(value: decoded.access_token, expiry: Date().addingTimeInterval(lifetime))
    }

    // MARK: Transport

    private func perform(_ request: URLRequest, attempt: Int, logBody: String?) async throws -> Response {
        let start = Date()
        var entry = RequestLogEntry(
            date: start,
            method: request.httpMethod ?? "GET",
            url: request.url?.absoluteString ?? "",
            requestHeaders: LogRedactor.headers(request.allHTTPHeaderFields ?? [:]),
            requestBody: logBody,
            responseHeaders: [],
            attempt: attempt
        )
        do {
            let (data, urlResponse) = try await session.data(for: request)
            guard let http = urlResponse as? HTTPURLResponse else {
                throw APIError.invalidResponse("Not an HTTP response")
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }
            entry.statusCode = http.statusCode
            entry.responseHeaders = LogRedactor.headers(headers)
            entry.responseBody = LogRedactor.body(data)
            entry.duration = Date().timeIntervalSince(start)
            await log(entry)
            return Response(statusCode: http.statusCode, headers: headers, data: data)
        } catch let error as URLError {
            entry.errorDescription = error.localizedDescription
            entry.duration = Date().timeIntervalSince(start)
            await log(entry)
            if error.code == .cancelled { throw CancellationError() }
            throw error
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet]
            .contains(error.code)
    }

    /// Honors `Retry-After` (seconds) when present, otherwise 1s, 2s, 4s… with jitter, capped at 30s.
    private func backoffDelay(attempt: Int, retryAfter: String?) -> Double {
        if let retryAfter, let seconds = Double(retryAfter.trimmingCharacters(in: .whitespaces)) {
            return min(max(seconds, 0), 30)
        }
        let base = pow(2, Double(attempt - 1))
        return min(base + Double.random(in: 0...0.5), 30)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
