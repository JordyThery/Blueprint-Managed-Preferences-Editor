import Foundation
import Testing
@testable import Blueprint_Managed_Preferences_Editor

/// Answers requests from a session with canned responses and records what was sent.
/// The handler is global, so suites using it must be serialized.
nonisolated final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: String)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            recorded = []
        }
    }

    static var requests: [URLRequest] {
        lock.withLock { recorded }
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock {
            Self.recorded.append(request)
            return Self.handler
        }
        let (status, body) = handler?(request) ?? (500, "{}")
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Update versions")
struct UpdateVersionTests {
    @Test("Versions compare numerically, component by component",
          arguments: [
              ("1.0.2", "1.0.1", true), ("1.1", "1.0.9", true), ("1.10", "1.9", true), ("2.0", "1.99.99", true),
              ("1.0.1", "1.0.1", false), ("1.0", "1.0.0", false), ("1.0.0", "1.0", false), ("1.0.1", "1.0.2", false),
          ])
    func isNewer(candidate: String, current: String, expected: Bool) {
        #expect(UpdateChecker.isNewer(candidate, than: current) == expected)
    }
}

private func releaseJSON(tag: String) -> String {
    """
    {"tag_name":"\(tag)","name":"Blueprint Managed Preferences Editor \(tag.dropFirst())","body":"**Fixed** things.",
     "html_url":"https://github.com/JordyThery/Blueprint-Managed-Preferences-Editor/releases/tag/\(tag)",
     "assets":[{"name":"Blueprint-Managed-Preferences-Editor-\(tag.dropFirst()).zip","browser_download_url":"https://github.com/download/bmpe.zip"}]}
    """
}

private func freshDefaults() -> UserDefaults {
    let name = "bmpe-update-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("Update checker", .serialized)
struct UpdateCheckerTests {
    @Test("A newer release is offered once, with notes and the zip asset")
    func offersNewerRelease() async throws {
        MockURLProtocol.install { _ in (200, releaseJSON(tag: "v99.0.0")) }
        let defaults = freshDefaults()
        let checker = UpdateChecker(defaults: defaults, session: MockURLProtocol.makeSession())

        await checker.checkAutomatically()

        let request = try #require(MockURLProtocol.requests.first)
        #expect(request.url == UpdateChecker.latestReleaseURL)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        guard case let .available(release) = checker.status else {
            Issue.record("expected an available release, got \(checker.status)")
            return
        }
        #expect(release.version == "99.0.0", "the leading v is dropped")
        #expect(release.downloadURL?.lastPathComponent == "bmpe.zip")
        #expect(release.notes == "**Fixed** things.")
        #expect(checker.isPresented)

        // The next day the same release is not offered again.
        defaults.set(Date.distantPast, forKey: UpdateChecker.lastCheckKey)
        checker.isPresented = false
        await checker.checkAutomatically()
        #expect(!checker.isPresented)
    }

    @Test("The current or an older release is not offered")
    func ignoresOlderRelease() async {
        MockURLProtocol.install { _ in (200, releaseJSON(tag: "v0.0.1")) }
        let checker = UpdateChecker(defaults: freshDefaults(), session: MockURLProtocol.makeSession())
        await checker.checkAutomatically()
        #expect(MockURLProtocol.requests.count == 1)
        #expect(!checker.isPresented)
    }

    @Test("Nothing is sent when the daily check is off, or already ran today")
    func respectsSettings() async {
        MockURLProtocol.install { _ in (500, "{}") }

        let off = freshDefaults()
        off.set(false, forKey: UpdateChecker.automaticCheckKey)
        await UpdateChecker(defaults: off, session: MockURLProtocol.makeSession()).checkAutomatically()

        let recent = freshDefaults()
        recent.set(Date(), forKey: UpdateChecker.lastCheckKey)
        await UpdateChecker(defaults: recent, session: MockURLProtocol.makeSession()).checkAutomatically()

        #expect(MockURLProtocol.requests.isEmpty)
    }

    @Test("A failed automatic check stays silent")
    func silentFailure() async {
        MockURLProtocol.install { _ in (503, "{}") }
        let checker = UpdateChecker(defaults: freshDefaults(), session: MockURLProtocol.makeSession())
        await checker.checkAutomatically()
        #expect(!checker.isPresented)
        #expect(checker.status == .idle)
    }
}
