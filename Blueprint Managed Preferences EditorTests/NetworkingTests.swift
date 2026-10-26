import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Blueprint_Managed_Preferences_Editor

@Suite("Request allow-list")
struct RequestAllowListTests {
    @Test(arguments: [
        ("GET", "/blueprints/v1/blueprints"),
        ("GET", "/blueprints/v1/blueprints/abc"),
        ("POST", "/auth/token"),
        ("PATCH", "/blueprints/v1/blueprints/abc"),
        ("POST", "/blueprints/v1/blueprints/abc/deploy"),
    ])
    func permits(method: String, path: String) {
        #expect(RequestAllowList.isPermitted(method: method, path: path))
    }

    @Test(arguments: [
        ("DELETE", "/blueprints/v1/blueprints/abc"),
        ("POST", "/blueprints/v1/blueprints/abc/undeploy"),
        ("POST", "/blueprints/v1/blueprints"),
        ("PUT", "/blueprints/v1/blueprints/abc"),
        ("PATCH", "/blueprints/v1/blueprints"),
        ("PATCH", "/device-groups/v1/device-groups/abc"),
        ("POST", "/blueprints/v1/blueprints/abc/deploy/extra"),
        ("PATCH", "/blueprints/v1/blueprints/../x"),
        ("POST", "/blueprints/v1/blueprints//deploy"),
        ("GET", "blueprints/v1/blueprints"),
        // Encoded traversal must be judged by the decoded segment.
        ("PATCH", "/blueprints/v1/blueprints/..%2F..%2Fv1%2Fdevices"),
        ("PATCH", "/blueprints/v1/blueprints/%2e%2e"),
        ("POST", "/blueprints/v1/blueprints/a%2Fb/deploy"),
        ("GET", "/blueprints/v1/%2e%2e/other"),
        ("GET", "/blueprints/v1/%zz"),
    ])
    func refuses(method: String, path: String) {
        #expect(!RequestAllowList.isPermitted(method: method, path: path))
    }

    /// Percent-encoding that does not hide a separator stays permitted.
    @Test func permitsHarmlessEncoding() {
        #expect(RequestAllowList.isPermitted(method: "PATCH", path: "/blueprints/v1/blueprints/a%20b"))
    }
}

/// Each test has its own JTKit `MockServer`, so these run alongside each other
/// and never touch the real network.
@Suite("Platform API client")
struct PlatformAPIClientTests {
    private let credentials = PlatformCredentials(
        region: .eu, environmentID: Self.environmentID, clientID: "id", clientSecret: "s3cr3t", connectionName: "Test Tenant"
    )
    private static let environmentID = "5f1e2d3c-4b5a-4968-8776-655443322110"
    private static let token = MockResponse.json(200, #"{"access_token":"tok","expires_in":900}"#)
    private static let emptyList = MockResponse.json(200, #"{"results":[],"totalCount":0}"#)

    private func makeClient(_ server: MockServer, sleeps: SleepRecorder = SleepRecorder(), log: ActivityLog? = nil) -> JamfPlatform.Client {
        // The test Environment ID is a UUID, so this never throws.
        try! PlatformAPIClient.make(
            credentials: credentials,
            session: server.session,
            log: log,
            sleep: { try await sleeps.sleep($0) }
        )
    }

    private func apiRequests(_ server: MockServer) -> [RecordedRequest] {
        server.requests.filter { $0.path != "/auth/token" }
    }

    @Test func deleteAndUndeployNeverReachTheNetwork() async {
        let server = MockServer { _ in Issue.record("No request may be sent"); return .json(500, "{}") }
        let client = makeClient(server)
        await #expect(throws: JamfPlatformError.self) {
            try await client.send(HTTPRequest(method: "DELETE", path: "/blueprints/v1/blueprints/abc"))
        }
        await #expect(throws: JamfPlatformError.self) {
            try await client.send(HTTPRequest(method: "POST", path: "/blueprints/v1/blueprints/abc/undeploy"))
        }
        #expect(server.requests.isEmpty)
    }

    @Test func refusalKeepsTheAppsMessage() async {
        let server = MockServer { _ in .json(500, "{}") }
        do {
            _ = try await makeClient(server).send(HTTPRequest(method: "DELETE", path: "/blueprints/v1/blueprints/abc"))
            Issue.record("Expected a refusal")
        } catch let error as JamfPlatformError {
            guard case .refused("DELETE", "/blueprints/v1/blueprints/abc") = error.kind else { Issue.record("Got \(error)"); return }
            #expect(error.localizedDescription.contains("never creates, deletes or undeploys"))
        } catch {
            Issue.record("Got \(error)")
        }
    }

    @Test func sendsTokenAndEnvironmentID() async throws {
        let server = MockServer { $0.path == "/auth/token" ? Self.token : Self.emptyList }
        _ = try await JamfPlatform.Blueprints(client: makeClient(server)).listPage()
        let signIn = try #require(server.requests.first)
        #expect(signIn.method == "POST")
        #expect(signIn.url.host() == "eu.api.jamfcloud.com")
        #expect(signIn.bodyString.contains("grant_type=client_credentials"))
        #expect(signIn.bodyString.contains("client_secret=s3cr3t"))
        let request = try #require(apiRequests(server).first)
        #expect(request.path == "/blueprints/v1/blueprints")
        #expect(request.queryValue("page-size") == "100")
        #expect(request.header("X-Environment-Id") == Self.environmentID)
        #expect(request.header("Authorization") == "Bearer tok")
    }

    @Test func tokenIsReusedAcrossRequests() async throws {
        let server = MockServer { $0.path == "/auth/token" ? Self.token : Self.emptyList }
        let service = JamfPlatform.Blueprints(client: makeClient(server))
        _ = try await service.listPage()
        _ = try await service.listPage()
        #expect(server.requests.filter { $0.path == "/auth/token" }.count == 1)
        #expect(apiRequests(server).count == 2)
    }

    @Test func refreshesTokenOnceAfter401() async throws {
        let tokens = Counter()
        let gets = Counter()
        let server = MockServer { request in
            if request.path == "/auth/token" {
                _ = tokens.next()
                return Self.token
            }
            return gets.next() == 1 ? .json(401, "{}") : Self.emptyList
        }
        _ = try await JamfPlatform.Blueprints(client: makeClient(server)).listPage()
        #expect(tokens.value == 2)
        #expect(gets.value == 2)
    }

    @Test func secondConsecutive401IsThrown() async {
        let server = MockServer { $0.path == "/auth/token" ? Self.token : .json(401, "{}") }
        await #expect(throws: JamfPlatformError.self) { try await JamfPlatform.Blueprints(client: makeClient(server)).listPage() }
        #expect(apiRequests(server).count == 2)
    }

    @Test func honours429RetryAfter() async throws {
        let gets = Counter()
        let sleeps = SleepRecorder()
        let server = MockServer { request in
            if request.path == "/auth/token" { return Self.token }
            return gets.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "7"]) : Self.emptyList
        }
        _ = try await JamfPlatform.Blueprints(client: makeClient(server, sleeps: sleeps)).listPage()
        #expect(gets.value == 2)
        #expect(sleeps.recorded == [.seconds(7)])
    }

    @Test func getIsRetriedOn5xx() async throws {
        let gets = Counter()
        let server = MockServer { request in
            if request.path == "/auth/token" { return Self.token }
            return gets.next() == 1 ? .json(502, "{}") : .json(200, selfServiceBlueprintJSON)
        }
        let detail = try await JamfPlatform.Blueprints(client: makeClient(server)).detail(id: "0a1b2c3d-1111-4111-8111-0123456789ab")
        #expect(gets.value == 2)
        #expect(detail.id == "0a1b2c3d-1111-4111-8111-0123456789ab")
    }

    @Test func givesUpAfterFourAttempts() async {
        let server = MockServer { $0.path == "/auth/token" ? Self.token : .json(503, "{}") }
        await #expect(throws: JamfPlatformError.self) { try await JamfPlatform.Blueprints(client: makeClient(server)).listPage() }
        #expect(apiRequests(server).count == 4)
    }

    @Test func patchSendsOnlyStepsAsMergePatch() async throws {
        let server = MockServer { $0.path == "/auth/token" ? Self.token : MockResponse(status: 204, body: Data()) }
        let blueprint = try LosslessJSON(string: selfServiceBlueprintJSON)
        let steps = try #require(blueprint["steps"])
        try await JamfPlatform.Blueprints(client: makeClient(server)).patchSteps(id: "abc", steps: steps)
        let request = try #require(apiRequests(server).first)
        #expect(request.method == "PATCH")
        #expect(request.path == "/blueprints/v1/blueprints/abc")
        #expect(request.header("Content-Type") == "application/merge-patch+json")
        #expect(request.bodyString == #"{"steps":"# + steps.serializedString() + "}")
        #expect(!request.bodyString.contains("divisionId"))
    }

    @Test func patchIsRetriedOn5xx() async throws {
        let patches = Counter()
        let server = MockServer { request in
            if request.path == "/auth/token" { return Self.token }
            return patches.next() == 1 ? .json(503, "{}") : MockResponse(status: 204, body: Data())
        }
        let steps = try #require(try LosslessJSON(string: rosettaBlueprintJSON)["steps"])
        try await JamfPlatform.Blueprints(client: makeClient(server)).patchSteps(id: "abc", steps: steps)
        #expect(patches.value == 2)
    }

    @Test func deployIsNotRetriedOn5xx() async {
        let server = MockServer { $0.path == "/auth/token" ? Self.token : .json(503, "{}") }
        await #expect(throws: JamfPlatformError.self) { try await JamfPlatform.Blueprints(client: makeClient(server)).deploy(id: "abc") }
        #expect(apiRequests(server).count == 1)
        #expect(apiRequests(server).first?.path == "/blueprints/v1/blueprints/abc/deploy")
    }

    @Test func deployIsRetriedOn429() async throws {
        let posts = Counter()
        let server = MockServer { request in
            if request.path == "/auth/token" { return Self.token }
            return posts.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "1"]) : .json(202, "")
        }
        try await JamfPlatform.Blueprints(client: makeClient(server)).deploy(id: "abc")
        #expect(posts.value == 2)
    }

    @Test func serverErrorKeepsPlatformDetails() async {
        let body = #"{"httpStatus":409,"traceId":"abc-123","errors":[{"code":"DIVISION_PATCH_NOT_ALLOWED"}]}"#
        let server = MockServer { $0.path == "/auth/token" ? Self.token : .json(409, body) }
        do {
            _ = try await JamfPlatform.Blueprints(client: makeClient(server)).detail(id: "abc")
            Issue.record("Expected an HTTP error")
        } catch let error as JamfPlatformError {
            #expect(error.hasCode(.divisionPatchNotAllowed))
            #expect(error.localizedDescription.contains("abc-123"))
        } catch {
            Issue.record("Got \(error)")
        }
    }

    /// JTKit checks the Environment ID before anything is sent.
    @Test func anEnvironmentIDThatIsNotAUUIDIsRefusedBeforeSending() {
        var credentials = credentials
        credentials.environmentID = "env-1"
        do {
            _ = try PlatformAPIClient.make(credentials: credentials, log: nil)
            Issue.record("Expected the Environment ID to be refused")
        } catch let error as JamfPlatformError {
            guard case .invalidEnvironmentID("env-1") = error.kind else { Issue.record("Got \(error)"); return }
            #expect(error.localizedDescription.contains("is not a UUID"))
        } catch {
            Issue.record("Got \(error)")
        }
    }

    @Test func failedSignInExplainsWhatToCheck() async {
        let server = MockServer { _ in .json(401, #"{"error":"invalid_client"}"#) }
        do {
            try await makeClient(server).signIn()
            Issue.record("Expected a sign-in error")
        } catch let error as JamfPlatformError {
            guard case .signIn(401, _, _) = error.kind else { Issue.record("Got \(error)"); return }
            #expect(error.localizedDescription.contains("Check the client ID, client secret and region"))
        } catch {
            Issue.record("Got \(error)")
        }
    }

    @Test @MainActor func refusedRequestIsLoggedAsWarning() async {
        let log = ActivityLog()
        let server = MockServer { _ in Issue.record("No request may be sent"); return .json(500, "{}") }
        await #expect(throws: JamfPlatformError.self) {
            try await makeClient(server, log: log).send(HTTPRequest(method: "DELETE", path: "/blueprints/v1/blueprints/abc"))
        }
        #expect(log.entries.count == 1)
        #expect(log.entries.first?.isWarning == true)
    }

    @Test @MainActor func waitBeforeRetryIsLogged() async throws {
        let log = ActivityLog()
        let gets = Counter()
        let server = MockServer { request in
            if request.path == "/auth/token" { return Self.token }
            return gets.next() == 1 ? .json(429, "{}", headers: ["Retry-After": "7"]) : Self.emptyList
        }
        _ = try await JamfPlatform.Blueprints(client: makeClient(server, log: log)).listPage()
        let wait = try #require(log.entries.first { $0.category == "Retry" })
        #expect(wait.isWarning)
        #expect(wait.note?.contains("waiting 7 s, attempt 2 of 4") == true)
    }

    /// Managed Preferences payloads can hold licence keys and tokens, so the
    /// default bodies rule applies: what is sent is never recorded, and what
    /// comes back only for errors.
    @Test @MainActor func secretsAndBodiesAreNotLogged() async throws {
        let log = ActivityLog()
        let server = MockServer { request in
            switch request.method {
            case "POST": return Self.token
            case "GET": return .json(200, emailBlueprintJSON)
            default: return MockResponse(status: 204, body: Data())
            }
        }
        let service = JamfPlatform.Blueprints(client: makeClient(server, log: log))
        let detail = try await service.detail(id: "0a1b2c3d-2222-4222-8222-0123456789ab")
        let steps = try #require(try LosslessJSON(string: emailBlueprintJSON)["steps"])
        try await service.patchSteps(id: detail.id, steps: steps)

        let entries = log.entries
        #expect(entries.map(\.category) == ["Sign-in", "API", "API"])
        #expect(entries.allSatisfy { $0.service == "Jamf Platform API" && $0.connection == "Test Tenant" })
        let text = entries.compactMap(\.request).map { details in
            [details.url, details.requestBody ?? "", details.responseBody ?? "",
             (details.requestHeaders + details.responseHeaders).map(\.value).joined(separator: " ")].joined(separator: " ")
        }.joined(separator: " ")
        #expect(!text.contains("s3cr3t"))
        #expect(!text.contains("\"tok\""))
        #expect(!text.contains("Bearer tok"))
        #expect(!text.contains("OfficeActivationEmailAddress"))
        #expect(entries.allSatisfy { $0.request?.requestBody == nil })
        #expect(entries.allSatisfy { $0.request?.responseBody == nil })
    }

    @Test @MainActor func errorResponseBodyIsLoggedRedacted() async throws {
        let log = ActivityLog()
        let server = MockServer { request in
            request.path == "/auth/token" ? Self.token : .json(400, #"{"message":"bad","access_token":"leak-me"}"#)
        }
        _ = try? await JamfPlatform.Blueprints(client: makeClient(server, log: log)).detail(id: "abc")
        let failure = try #require(log.entries.last)
        #expect(failure.status == 400)
        let body = try #require(failure.request?.responseBody)
        #expect(body.contains("bad"))
        #expect(!body.contains("leak-me"))
    }
}

/// Counts calls from the fake server's handler.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    /// Increments and returns the new value (first call returns 1).
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Stands in for the wait before a retry: records it and returns at once.
final class SleepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var durations: [Duration] = []

    var recorded: [Duration] { lock.withLock { durations } }

    func sleep(_ duration: Duration) async throws {
        lock.withLock { durations.append(duration) }
    }
}
