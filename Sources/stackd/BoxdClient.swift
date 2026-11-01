import Foundation
import os

/// Never log keys or tokens. View with: log stream --level debug --predicate 'subsystem == "li.rol.dev.stackd"'
let log = Logger(subsystem: "li.rol.dev.stackd", category: "api")

enum BoxdError: LocalizedError {
    case noAPIKey
    case authRejected
    case http(Int)
    case grpc(status: Int, message: String)
    case transport(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured."
        case .authRejected:
            return "API key was rejected. Create a new one (boxd auth keys create stackd) and paste it in settings."
        case .http(let status):
            return "HTTP \(status) from the boxd API."
        case .grpc(let status, let message):
            return message.isEmpty ? "gRPC error \(status)" : message
        case .transport(let message):
            return message
        case .badResponse(let detail):
            return "Unexpected response from boxd (\(detail))."
        }
    }
}

/// grpc-web transport + JWT exchange for the boxd API. Dependency-free:
/// requests are hand-framed (`[flag:1][len:4 BE][payload]`) and posted as
/// `application/grpc-web+proto` to https://boxd.sh:9443.
///
/// Verified server quirk: `grpc-status`/`grpc-message` arrive EITHER in a 0x80
/// trailer frame in the body OR as plain HTTP response headers (empty body) —
/// both sources are checked, body first.
actor BoxdClient {
    private let apiURL: URL
    private let consoleURL: URL

    private var apiKey: String?
    private var jwt: String?
    private var jwtExpiresAt = Date.distantPast
    private let session = URLSession.shared

    private struct Token: Sendable {
        let token: String
        let expiresAt: Date
    }

    /// The single in-flight token exchange. `id` lets a finishing exchange tell
    /// whether it is still the current one (reset / a newer setAPIKey replace it).
    private var inflight: (id: UInt64, key: String, task: Task<Token, any Error>)?
    private var nextExchangeID: UInt64 = 0

    /// Exchange window: re-exchange when < 10 min of JWT life remain.
    private static let jwtRefreshSkew: TimeInterval = 600
    /// Used when neither `expires_at` nor the JWT `exp` claim is usable.
    private static let fallbackJWTLifetime: TimeInterval = 55 * 60

    init() {
        // Literals are known-valid; fall back to a bare URL rather than crash.
        apiURL = URL(string: "https://boxd.sh:9443") ?? URL(fileURLWithPath: "/")
        consoleURL = URL(string: "https://app.boxd.sh") ?? URL(fileURLWithPath: "/")
    }

    // MARK: Credentials

    /// Stores the key only after a successful token exchange (i.e. the key works).
    /// Supersedes any in-flight exchange; if another setAPIKey/reset lands while
    /// this one is running, its result is discarded and `CancellationError` is thrown.
    func setAPIKey(_ key: String) async throws {
        _ = try await startExchange(for: key, commitsKey: true)
    }

    func reset() {
        inflight?.task.cancel()
        inflight = nil
        apiKey = nil
        jwt = nil
        jwtExpiresAt = .distantPast
    }

    // MARK: Public RPCs

    func whoami() async throws -> Identity {
        try Identity(proto: await grpcCall("Whoami", payload: Data()))
    }

    func listVms(org: String, allContexts: Bool) async throws -> [Vm] {
        try Vm.decodeList(await grpcCall("ListVms", payload: BoxdRequests.listVms(org: org, allContexts: allContexts)))
    }

    /// State verb; success is grpc-status == 0 (responses are empty or carry
    /// timing fields we don't use).
    func performVmAction(_ action: VmAction, vmID: String) async throws {
        _ = try await grpcCall(action.methodName, payload: BoxdRequests.vmID(vmID))
    }

    // MARK: JWT exchange

    /// `rejected`: a token the server just answered with UNAUTHENTICATED. If the
    /// current token differs, someone already refreshed and we reuse it; otherwise
    /// the exchange is forced (joining one already in flight).
    private func ensureJWT(rejected: String? = nil) async throws -> String {
        if let jwt, jwt != rejected, jwtExpiresAt.timeIntervalSinceNow > Self.jwtRefreshSkew {
            return jwt
        }
        guard let apiKey else { throw BoxdError.noAPIKey }
        if let inflight, inflight.key == apiKey {
            return try await awaitToken(inflight.task)
        }
        return try await startExchange(for: apiKey, commitsKey: false)
    }

    private func awaitToken(_ task: Task<Token, any Error>) async throws -> String {
        let t = try await task.value
        try Task.checkCancellation() // the shared task ignores this caller's cancellation
        return t.token
    }

    /// Replaces any in-flight exchange with a new one for `key`. The task commits
    /// its own result, and only while it is still the current exchange.
    private func startExchange(for key: String, commitsKey: Bool) async throws -> String {
        inflight?.task.cancel()
        nextExchangeID += 1
        let id = nextExchangeID
        let task = Task { [self] in
            let t = try await exchange(apiKey: key)
            return try commit(t, key: key, id: id, commitsKey: commitsKey)
        }
        inflight = (id, key, task)
        // Clear the slot on failure too, so the next caller retries.
        defer { if inflight?.id == id { inflight = nil } }
        return try await awaitToken(task)
    }

    private func commit(_ t: Token, key: String, id: UInt64, commitsKey: Bool) throws -> Token {
        guard !Task.isCancelled, inflight?.id == id else { throw CancellationError() }
        if commitsKey { apiKey = key }
        jwt = t.token
        jwtExpiresAt = t.expiresAt
        return t
    }

    /// POST {api_key} → {token, expires_at, user_id}. 401/403 → .authRejected.
    private func exchange(apiKey: String) async throws -> Token {
        var req = URLRequest(url: consoleURL.appendingPathComponent("api/v1/auth/token"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["api_key": apiKey])
        req.timeoutInterval = 20

        let (data, resp) = try await perform(req)
        guard (200..<300).contains(resp.statusCode) else {
            if resp.statusCode == 401 || resp.statusCode == 403 { throw BoxdError.authRejected }
            throw BoxdError.http(resp.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["token"] as? String, !token.isEmpty
        else { throw BoxdError.badResponse("token exchange") }

        let expiresAt = Self.parseExpiry(obj["expires_at"])
            ?? Self.jwtExpiry(token)
            ?? Date().addingTimeInterval(Self.fallbackJWTLifetime)
        return Token(token: token, expiresAt: expiresAt)
    }

    // MARK: Expiry parsing

    /// Unix timestamp as number or numeric string; values > 1e12 are milliseconds.
    /// Non-positive or already-past values are treated as unusable.
    private static func parseExpiry(_ raw: Any?) -> Date? {
        var value: Double?
        switch raw {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): value = n.doubleValue
        case let s as String: value = Double(s.trimmingCharacters(in: .whitespaces))
        default: break
        }
        guard var v = value, v.isFinite, v > 0 else { return nil }
        if v > 1e12 { v /= 1000 }
        let date = Date(timeIntervalSince1970: v)
        return date > Date() ? date : nil
    }

    /// `exp` claim of the JWT payload (base64url, unpadded).
    private static func jwtExpiry(_ jwt: String) -> Date? {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return parseExpiry(claims["exp"])
    }

    // MARK: grpc-web transport

    /// Retries once with a fresh JWT on UNAUTHENTICATED (16).
    private func grpcCall(_ method: String, payload: Data) async throws -> Data {
        let token = try await ensureJWT()
        do {
            return try await grpcRoundTrip(method, payload: payload, token: token)
        } catch BoxdError.grpc(16, _) {
            let fresh = try await ensureJWT(rejected: token)
            return try await grpcRoundTrip(method, payload: payload, token: fresh)
        }
    }

    private func grpcRoundTrip(_ method: String, payload: Data, token: String) async throws -> Data {
        var frame = Data(capacity: payload.count + 5)
        frame.append(0) // flag: uncompressed message
        let len = UInt32(payload.count)
        frame.append(UInt8((len >> 24) & 0xff))
        frame.append(UInt8((len >> 16) & 0xff))
        frame.append(UInt8((len >> 8) & 0xff))
        frame.append(UInt8(len & 0xff))
        frame.append(payload)

        var req = URLRequest(url: apiURL.appendingPathComponent("boxd.api.v1.BoxdApi/\(method)"))
        req.httpMethod = "POST"
        req.setValue("application/grpc-web+proto", forHTTPHeaderField: "content-type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        req.httpBody = frame
        req.timeoutInterval = 20

        let (body, resp) = try await perform(req)
        guard (200..<300).contains(resp.statusCode) else { throw BoxdError.http(resp.statusCode) }

        var message = Data()
        var trailers: [String: String] = [:]
        var pos = 0
        while pos + 5 <= body.count {
            let flag = body[pos]
            let flen = Int(UInt32(body[pos + 1]) << 24 | UInt32(body[pos + 2]) << 16
                | UInt32(body[pos + 3]) << 8 | UInt32(body[pos + 4]))
            pos += 5
            guard pos + flen <= body.count else { throw BoxdError.badResponse("truncated grpc-web frame") }
            if flag & 0x80 != 0 {
                trailers = parseTrailers(body[pos..<pos + flen])
            } else {
                message.append(contentsOf: body[pos..<pos + flen])
            }
            pos += flen
        }

        let statusStr = trailers["grpc-status"] ?? resp.value(forHTTPHeaderField: "grpc-status")
        log.debug("\(method, privacy: .public): HTTP \(resp.statusCode) body=\(body.count)B message=\(message.count)B grpc-status=\(statusStr ?? "nil", privacy: .public) (from \(trailers["grpc-status"] != nil ? "trailer" : "header", privacy: .public))")
        guard let statusStr, let status = Int(statusStr)
        else { throw BoxdError.badResponse("missing grpc-status") }

        guard status == 0 else {
            let raw = trailers["grpc-message"] ?? resp.value(forHTTPHeaderField: "grpc-message") ?? ""
            throw BoxdError.grpc(status: status, message: raw.removingPercentEncoding ?? raw)
        }
        return message
    }

    /// Trailer frame payload: `key: value\r\n` lines.
    private func parseTrailers(_ bytes: Data.SubSequence) -> [String: String] {
        var out: [String: String] = [:]
        for line in String(decoding: bytes, as: UTF8.self).split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[key] = value
        }
        return out
    }

    private func perform(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw BoxdError.badResponse("non-HTTP response") }
            return (data, http)
        } catch let error as BoxdError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw BoxdError.transport(error.localizedDescription)
        }
    }
}
