import Foundation
import Testing
@testable import stackd

// MARK: - URLProtocol stub (no real network)

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func with<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// One-shot gate: `wait()` blocks (on a stub thread) until `open()`.
private final class Gate: Sendable {
    private let sem = DispatchSemaphore(value: 0)
    func open() { sem.signal() }
    func wait() { sem.wait() }
}

private struct Seen: Sendable {
    let url: String
    let authorization: String?
    let body: Data
}

private struct Reply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var redirectTo: String?
    var hold: Gate?
}

private final class StubProtocol: URLProtocol {
    struct State {
        var seen: [Seen] = []
        var handler: @Sendable (Int, Seen) -> Reply = { _, _ in Reply(status: 500) }
    }
    static let state = Locked(State())

    static func reset(_ handler: @escaping @Sendable (Int, Seen) -> Reply) {
        state.with { $0 = State(handler: handler) }
    }
    static var seen: [Seen] { state.with { $0.seen } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                body.append(buf, count: n)
            }
            stream.close()
        }
        let seen = Seen(url: request.url?.absoluteString ?? "", authorization: request.value(forHTTPHeaderField: "authorization"), body: body)
        let (index, handler) = Self.state.with { s -> (Int, @Sendable (Int, Seen) -> Reply) in
            s.seen.append(seen)
            return (s.seen.count - 1, s.handler)
        }
        let req = request
        nonisolated(unsafe) let me = self
        DispatchQueue.global().async {
            let reply = handler(index, seen)
            reply.hold?.wait()
            guard let url = req.url,
                  let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
            else { return }
            if let target = reply.redirectTo, let next = URL(string: target) {
                me.client?.urlProtocol(me, wasRedirectedTo: URLRequest(url: next), redirectResponse: resp)
                // If the client refuses the redirect, the 3xx response itself is the result.
            }
            me.client?.urlProtocol(me, didReceive: resp, cacheStoragePolicy: .notAllowed)
            me.client?.urlProtocol(me, didLoad: reply.body)
            me.client?.urlProtocolDidFinishLoading(me)
        }
    }
}

// MARK: - Helpers

private let tokenURL = "https://app.boxd.sh/api/v1/auth/token"
private let grpcPrefix = "https://boxd.sh:9443/boxd.api.v1.BoxdApi/"

private func makeClient() -> BoxdClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return BoxdClient(configuration: config)
}

private func tokenReply(_ token: String) -> Reply {
    let json = "{\"token\":\"\(token)\",\"expires_at\":\(Int(Date().addingTimeInterval(3600).timeIntervalSince1970))}"
    return Reply(headers: ["content-type": "application/json"], body: Data(json.utf8))
}

private func grpcReply(status: Int, hold: Gate? = nil) -> Reply {
    Reply(headers: ["grpc-status": String(status)], hold: hold)
}

private func apiKey(in seen: Seen) -> String? {
    (try? JSONSerialization.jsonObject(with: seen.body) as? [String: Any])?["api_key"] as? String
}

private func waitForRequests(_ n: Int) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while StubProtocol.seen.count < n, ContinuousClock.now < deadline { await Task.yield() }
}

// MARK: - Tests

@Suite(.serialized)
struct BoxdClientTests {

    @Test func tokenExchangeRedirectIsNotFollowed() async {
        StubProtocol.reset { _, seen in
            seen.url == tokenURL ? Reply(status: 307, redirectTo: "https://evil.example/collect") : Reply(status: 500)
        }
        let client = makeClient()
        var thrown: Error?
        do { try await client.setAPIKey("secret-key") } catch { thrown = error }
        guard case BoxdError.http(307)? = thrown else {
            Issue.record("expected BoxdError.http(307), got \(String(describing: thrown))")
            return
        }
        #expect(StubProtocol.seen.map(\.url) == [tokenURL]) // never contacted the redirect target
    }

    @Test func unauthenticatedRetriesOnceWithFreshJWTForSameKey() async throws {
        StubProtocol.reset { i, seen in
            if seen.url == tokenURL { return tokenReply(i == 0 ? "jwt-1" : "jwt-2") }
            return grpcReply(status: seen.authorization == "Bearer jwt-1" ? 16 : 0)
        }
        let client = makeClient()
        try await client.setAPIKey("k1")
        try await client.performVmAction(.stop, vmID: "vm-1")

        let seen = StubProtocol.seen
        #expect(seen.map(\.url) == [tokenURL, grpcPrefix + "StopVm", tokenURL, grpcPrefix + "StopVm"])
        #expect(seen.filter { $0.url != tokenURL }.map(\.authorization) == ["Bearer jwt-1", "Bearer jwt-2"])
        #expect(seen.filter { $0.url == tokenURL }.compactMap(apiKey(in:)) == ["k1", "k1"])
    }

    @Test func resetDuringFirstAttemptDropsTheRetry() async throws {
        let gate = Gate()
        StubProtocol.reset { _, seen in
            seen.url == tokenURL ? tokenReply("jwt-1") : grpcReply(status: 16, hold: gate)
        }
        let client = makeClient()
        try await client.setAPIKey("k1")
        let call = Task { try await client.performVmAction(.stop, vmID: "vm-1") }
        await waitForRequests(2) // token + held grpc request
        await client.reset()
        gate.open()

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(StubProtocol.seen.count == 2) // no second grpc request, no re-exchange
    }

    @Test func newKeyDuringFirstAttemptDropsTheRetry() async throws {
        let gate = Gate()
        StubProtocol.reset { _, seen in
            if seen.url == tokenURL { return tokenReply(apiKey(in: seen) == "k2" ? "jwt-2" : "jwt-1") }
            return seen.authorization == "Bearer jwt-1" ? grpcReply(status: 16, hold: gate) : grpcReply(status: 0)
        }
        let client = makeClient()
        try await client.setAPIKey("k1")
        let call = Task { try await client.performVmAction(.stop, vmID: "vm-1") }
        await waitForRequests(2)
        try await client.setAPIKey("k2")
        gate.open()

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(StubProtocol.seen.filter { $0.url != tokenURL }.count == 1) // only the original attempt
    }
}
