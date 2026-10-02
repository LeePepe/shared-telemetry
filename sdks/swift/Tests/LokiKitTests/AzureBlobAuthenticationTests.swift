import Foundation
import Synchronization
import XCTest
@testable import LokiKit

final class AzureBlobAuthenticationTests: XCTestCase {
    private let privacy = AzureBlobPrivacyPolicy(events: ["synthetic.auth": [:], "synthetic.isolation": [:], "synthetic.cancelled": [:]],
        apps: ["synthetic"], builds: ["auth-test", "isolation-test", "cancellation-test"])
    func testConnectionLevelChallengesCannotUseForeignSessionCredentials() async throws {
        for method in [NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate,
                       NSURLAuthenticationMethodClientCertificate] {
            try await assertChallengeRefused(method)
        }
    }

    func testTaskLevelChallengesCannotUseForeignSessionCredentials() async throws {
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest] {
            try await assertChallengeRefused(method)
        }
    }

    func testCallerHeadersCookiesAndPrivateCredentialStoreAreNotInherited() async throws {
        let fixture = BlobAuthenticationFixture(method: nil)
        defer { fixture.close() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlobAuthenticationProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "Bearer synthetic-only",
            "Proxy-Authorization": "Basic synthetic-only", "Cookie": "caller=synthetic-only",
            "X-Caller-Header": "synthetic-only"]
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        // Ephemeral configuration stores are private, memory-only, not shared/Keychain.
        let cookies = try XCTUnwrap(configuration.httpCookieStorage)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: fixture.container.host!,
            .path: "/", .name: "caller", .value: "synthetic-only", .secure: "TRUE"]))
        cookies.setCookie(cookie)
        let credentials = try XCTUnwrap(configuration.urlCredentialStorage)
        let space = URLProtectionSpace(host: fixture.container.host!, port: 443, protocol: "https",
            realm: "synthetic", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        credentials.setDefaultCredential(URLCredential(user: "synthetic-only", password: "synthetic-only", persistence: .forSession), for: space)
        XCTAssertEqual(credentials.defaultCredential(for: space)?.user, "synthetic-only", "Fixture must contain a credential before transport")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BlobIsolation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.isolation"))
        let transport = try AzureBlobTransport(containerURL: fixture.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "synthetic", build: "isolation-test", installID: UUID(), privacy: privacy, configuration: configuration)
        // Mutating a caller's configuration after construction cannot change the seam.
        configuration.protocolClasses = []
        configuration.httpAdditionalHeaders = ["X-Later-Caller-Header": "synthetic-only"]
        try await transport.flush(queue)
        let request = try XCTUnwrap(fixture.state.withLock { $0.requests.first })
        for header in ["Authorization", "Proxy-Authorization", "Cookie", "X-Caller-Header", "X-Later-Caller-Header"] {
            XCTAssertNil(request.value(forHTTPHeaderField: header), "Must not inherit \(header)")
        }
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-blob-type"), "BlockBlob")
        XCTAssertEqual(cookies.cookies?.map(\.name), ["caller"], "No Blob response cookies enter caller storage")
        XCTAssertEqual(credentials.defaultCredential(for: space)?.user, "synthetic-only", "Caller store is untouched")
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    func testBothDelegateLevelsUseDefaultSystemServerTrustWithoutSupplyingCredentials() throws {
        let fixture = BlobAuthenticationFixture(method: NSURLAuthenticationMethodServerTrust)
        defer { fixture.close() }
        let policy = BlobRequestDelegate()
        let task = fixture.session.dataTask(with: fixture.container) // Never resumed.
        defer { task.cancel() }
        let space = URLProtectionSpace(host: fixture.container.host!, port: 443, protocol: "https",
            realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
        let sender = BlobAuthenticationProtocol(request: URLRequest(url: fixture.container), cachedResponse: nil, client: nil)
        let challenge = URLAuthenticationChallenge(protectionSpace: space,
            proposedCredential: URLCredential(user: "synthetic-only", password: "synthetic-only", persistence: .none),
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: sender)
        let decisions = Mutex<[URLSession.AuthChallengeDisposition]>([])
        let completion: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, credential in
            decisions.withLock { $0.append(disposition) }
            XCTAssertNil(credential, "System trust evaluation must not be replaced by a credential")
        }
        policy.urlSession(fixture.session, didReceive: challenge, completionHandler: completion)
        policy.urlSession(fixture.session, task: task, didReceive: challenge, completionHandler: completion)
        XCTAssertEqual(decisions.withLock { $0 }, [.performDefaultHandling, .performDefaultHandling])
        // This proves policy dispatch, not a live TLS handshake or certificate acceptance.
    }

    func testBothDelegateLevelsRejectNonTrustChallengesEvenWithProposedCredentials() throws {
        let fixture = BlobAuthenticationFixture(method: nil)
        defer { fixture.close() }
        let policy = BlobRequestDelegate()
        let task = fixture.session.dataTask(with: fixture.container) // Never resumed.
        defer { task.cancel() }
        let sender = BlobAuthenticationProtocol(request: URLRequest(url: fixture.container), cachedResponse: nil, client: nil)
        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest,
                       NSURLAuthenticationMethodNTLM, NSURLAuthenticationMethodNegotiate,
                       NSURLAuthenticationMethodClientCertificate, NSURLAuthenticationMethodDefault, "synthetic-unknown"] {
            let space = URLProtectionSpace(host: fixture.container.host!, port: 443, protocol: "https",
                realm: "synthetic", authenticationMethod: method)
            let challenge = URLAuthenticationChallenge(protectionSpace: space,
                proposedCredential: URLCredential(user: "synthetic-only", password: "synthetic-only", persistence: .none),
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: sender)
            let decisions = Mutex<[URLSession.AuthChallengeDisposition]>([])
            let completion: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, credential in
                decisions.withLock { $0.append(disposition) }
                XCTAssertNil(credential)
            }
            policy.urlSession(fixture.session, didReceive: challenge, completionHandler: completion)
            policy.urlSession(fixture.session, task: task, didReceive: challenge, completionHandler: completion)
            XCTAssertEqual(decisions.withLock { $0 }, [.cancelAuthenticationChallenge, .cancelAuthenticationChallenge], method)
        }
    }

    func testCancelledOwnedSessionStopsRequestRetainsBatchAndNextFlushWorks() async throws {
        let fixture = BlobAuthenticationFixture(method: nil)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BlobCancellation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.cancelled"))
        let transport = try AzureBlobTransport(containerURL: fixture.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "synthetic", build: "cancellation-test", installID: UUID(), privacy: privacy, configuration: fixture.session.configuration)
        let entered = expectation(description: "mock request started")
        let stopped = expectation(description: "mock request cancelled")
        fixture.state.withLock { $0.holdOpen = true; $0.onRequest = { entered.fulfill() }; $0.onStop = { stopped.fulfill() } }
        let sending = Task { try await transport.flush(queue) }
        await fulfillment(of: [entered], timeout: 3)
        sending.cancel()
        do { try await sending.value; XCTFail("Cancelled upload must remain unconfirmed") }
        catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        await fulfillment(of: [stopped], timeout: 3)
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).count, 1)
        fixture.state.withLock { $0.holdOpen = false; $0.onRequest = nil; $0.onStop = nil }
        try await transport.flush(queue)
        let requests = fixture.state.withLock { $0.requests }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url, requests.last?.url)
        XCTAssertTrue(try queue.batchesForFlush().isEmpty)
    }

    private func assertChallengeRefused(_ method: String) async throws {
        let fixture = BlobAuthenticationFixture(method: method)
        defer { fixture.close() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BlobAuth-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let queue = TelemetryQueue(storeDirectory: directory)
        queue.enqueue(TelemetryEvent(name: "synthetic.auth"))
        let transport = try AzureBlobTransport(containerURL: fixture.container, sasQuery: "sr=c&sp=c&sig=synthetic-only",
            app: "synthetic", build: "auth-test", installID: UUID(), privacy: privacy, configuration: fixture.session.configuration)
        do { try await transport.flush(queue); XCTFail("Authentication challenge is not delivery") }
        catch { XCTAssertEqual(error as? AzureBlobError, .networkFailure) }
        let state = fixture.state.withLock { $0 }
        XCTAssertEqual(state.challengesIssued, 1, "Exercise actual Foundation routing for \(method)")
        XCTAssertEqual(state.credentialsUsed, 0, "No synthetic credential may reach the challenge sender for \(method)")
        XCTAssertEqual(fixture.foreignDelegate.challenges.withLock { $0 }, 0, "Foreign delegate must not be consulted for \(method)")
        XCTAssertEqual(try queue.batchesForFlush().flatMap(\.events).map(\.name), ["synthetic.auth"])
    }
}

// Port of the independent reviewer's URLProtocol challenge-sender probe. Only the
// routing registry is shared; each fixture owns its state/session/synthetic delegate.
private final class BlobAuthenticationFixture: @unchecked Sendable {
    struct State {
        var challengesIssued = 0
        var credentialsUsed = 0
        var requests: [URLRequest] = []
        var holdOpen = false
        var onRequest: (@Sendable () -> Void)?
        var onStop: (@Sendable () -> Void)?
    }
    let state = Mutex(State())
    let method: String?
    let container = URL(string: "https://\(UUID().uuidString.lowercased()).example.invalid/container")!
    let foreignDelegate = ForeignAuthenticationDelegate()
    let session: URLSession

    init(method: String?) {
        self.method = method
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlobAuthenticationProtocol.self]
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: foreignDelegate, delegateQueue: nil)
        BlobAuthenticationProtocol.fixtures.withLock { $0[container.host!] = self }
    }

    func close() {
        session.invalidateAndCancel()
        _ = BlobAuthenticationProtocol.fixtures.withLock { $0.removeValue(forKey: container.host!) }
    }
}

private final class ForeignAuthenticationDelegate: NSObject, URLSessionDelegate, Sendable {
    let challenges = Mutex(0)
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        challenges.withLock { $0 += 1 }
        completionHandler(.useCredential, URLCredential(user: "synthetic-only", password: "synthetic-only", persistence: .none))
    }
}

private final class BlobAuthenticationProtocol: URLProtocol, URLAuthenticationChallengeSender, @unchecked Sendable {
    static let fixtures = Mutex<[String: BlobAuthenticationFixture]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var fixture: BlobAuthenticationFixture? { Self.fixtures.withLock { $0[request.url?.host ?? ""] } }

    override func startLoading() {
        guard let fixture else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let behavior = fixture.state.withLock { state in
            state.requests.append(request)
            return (state.holdOpen, state.onRequest)
        }
        behavior.1?()
        if behavior.0 { return }
        guard let method = fixture.method else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: "HTTP/1.1",
                headerFields: ["Set-Cookie": "server-cookie=synthetic-only; Path=/; Secure"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        fixture.state.withLock { $0.challengesIssued += 1 }
        let space = URLProtectionSpace(host: fixture.container.host!, port: 443, protocol: "https",
            realm: "synthetic", authenticationMethod: method)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: self)
        client?.urlProtocol(self, didReceive: challenge)
    }

    override func stopLoading() { fixture?.state.withLock { $0.onStop }?() }
    private func finish() {
        client?.urlProtocol(self, didFailWithError: URLError(.userCancelledAuthentication))
    }
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        fixture?.state.withLock { $0.credentialsUsed += 1 }
        finish()
    }
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { finish() }
    func cancel(_ challenge: URLAuthenticationChallenge) { finish() }
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) { finish() }
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) { finish() }
}
