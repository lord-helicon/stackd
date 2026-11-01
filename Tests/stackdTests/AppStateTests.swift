import Foundation
import Testing
@testable import stackd

// MARK: - Fakes

/// Scriptable stand-in for `BoxdClient`. Every call is recorded; calls to a *gated* method suspend until
/// the test completes them, so every interleaving is driven by the test, never by timing.
actor FakeBoxd: BoxdAPI {
    enum Call: Equatable, Sendable {
        case setAPIKey(String)
        case resetStarted, resetFinished
        case whoami
        case listVms(org: String, allContexts: Bool)
        case action(VmAction, String)
    }

    enum Gate: Hashable, Sendable { case setAPIKey, reset, whoami, listVms, action }

    private(set) var calls: [Call] = []

    // Ungated responses.
    private var identity = Identity.make("user-1")
    private var listResult: Result<[Vm], any Error> = .success([])
    private var actionResult: Result<Void, any Error> = .success(())
    private var setAPIKeyResult: Result<Void, any Error> = .success(())

    private var gates: Set<Gate> = []
    private var listWaiters: [CheckedContinuation<[Vm], any Error>?] = []
    private var whoamiWaiters: [CheckedContinuation<Identity, any Error>?] = []
    private var actionWaiters: [CheckedContinuation<Void, any Error>?] = []
    private var setKeyWaiters: [CheckedContinuation<Void, any Error>?] = []
    private var resetWaiters: [CheckedContinuation<Void, Never>?] = []

    // MARK: Scripting

    func gate(_ g: Gate...) { gates.formUnion(g) }
    func script(identity: Identity? = nil, list: Result<[Vm], any Error>? = nil,
                action: Result<Void, any Error>? = nil, setAPIKey: Result<Void, any Error>? = nil) {
        if let identity { self.identity = identity }
        if let list { listResult = list }
        if let action { actionResult = action }
        if let setAPIKey { setAPIKeyResult = setAPIKey }
    }
    func clearCalls() { calls = [] }

    /// How many calls to the gated method have arrived so far (completed or not).
    func arrived(_ g: Gate) -> Int {
        switch g {
        case .listVms: return listWaiters.count
        case .whoami: return whoamiWaiters.count
        case .action: return actionWaiters.count
        case .setAPIKey: return setKeyWaiters.count
        case .reset: return resetWaiters.count
        }
    }

    func completeList(_ i: Int, _ r: Result<[Vm], any Error>) { listWaiters[i]?.resume(with: r); listWaiters[i] = nil }
    func completeWhoami(_ i: Int, _ r: Result<Identity, any Error>) { whoamiWaiters[i]?.resume(with: r); whoamiWaiters[i] = nil }
    func completeAction(_ i: Int, _ r: Result<Void, any Error> = .success(())) { actionWaiters[i]?.resume(with: r); actionWaiters[i] = nil }
    func completeReset(_ i: Int) { resetWaiters[i]?.resume(); resetWaiters[i] = nil }

    var listCalls: [Call] { calls.filter { if case .listVms = $0 { true } else { false } } }

    // MARK: BoxdAPI

    func setAPIKey(_ key: String) async throws {
        calls.append(.setAPIKey(key))
        if gates.contains(.setAPIKey) {
            try await withCheckedThrowingContinuation { setKeyWaiters.append($0) }
        }
        try setAPIKeyResult.get()
    }

    func reset() async {
        calls.append(.resetStarted)
        if gates.contains(.reset) {
            await withCheckedContinuation { resetWaiters.append($0) }
        }
        calls.append(.resetFinished)
    }

    func whoami() async throws -> Identity {
        calls.append(.whoami)
        if gates.contains(.whoami) {
            return try await withCheckedThrowingContinuation { whoamiWaiters.append($0) }
        }
        return identity
    }

    func listVms(org: String, allContexts: Bool) async throws -> [Vm] {
        calls.append(.listVms(org: org, allContexts: allContexts))
        if gates.contains(.listVms) {
            return try await withCheckedThrowingContinuation { listWaiters.append($0) }
        }
        return try listResult.get()
    }

    func performVmAction(_ action: VmAction, vmID: String) async throws {
        calls.append(.action(action, vmID))
        if gates.contains(.action) {
            try await withCheckedThrowingContinuation { actionWaiters.append($0) }
        }
        try actionResult.get()
    }
}

/// In-memory replacement for the Keychain.
final class FakeKeyStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: String?
    private var _saves: [String] = []
    private var _saveSucceeds = true

    var stored: String? {
        get { lock.withLock { _stored } }
        set { lock.withLock { _stored = newValue } }
    }
    var saves: [String] { lock.withLock { _saves } }
    var saveSucceeds: Bool {
        get { lock.withLock { _saveSucceeds } }
        set { lock.withLock { _saveSucceeds = newValue } }
    }

    var keyStore: KeyStore {
        KeyStore(
            load: { self.stored },
            save: { key in
                self.lock.withLock {
                    self._saves.append(key)
                    if self._saveSucceeds { self._stored = key }
                    return self._saveSucceeds
                }
            },
            delete: { self.stored = nil })
    }
}

extension Identity {
    static func make(_ id: String, name: String = "") -> Identity {
        var w = ProtoWriter()
        w.appendString(1, id)
        if !name.isEmpty { w.appendString(5, name) }
        // A well-formed message never fails to decode.
        return (try? Identity(proto: w.data)) ?? Identity.empty
    }

    private static var empty: Identity {
        (try? Identity(proto: Data())) ?? { fatalError("empty Identity must decode") }()
    }
}

private func makeVm(_ id: String, _ status: String = "running") throws -> Vm {
    var w = ProtoWriter()
    w.appendString(1, id)
    w.appendString(2, id)
    w.appendString(5, status)
    return try Vm(proto: w.data)
}

@MainActor final class Flag { var value = false }

// MARK: - Harness

@MainActor final class Harness {
    let fake = FakeBoxd()
    let keys = FakeKeyStore()
    let defaults: UserDefaults
    let state: AppState
    private let suite: String

    init(storedKey: String? = nil, scope: ScopeMode? = nil, org: String? = nil) {
        suite = "stackd-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite) ?? .standard // never .standard in practice; suite names are unique
        precondition(defaults !== UserDefaults.standard)
        if let scope { defaults.set(scope.rawValue, forKey: "scopeMode") }
        if let org { defaults.set(org, forKey: "orgName") }
        keys.stored = storedKey
        state = AppState(client: fake, keyStore: keys.keyStore, defaults: defaults, autostart: false)
    }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }

    /// Signs in through the public path and forgets the calls that took.
    func signIn(_ key: String = "k0") async {
        await state.submitAPIKey(key)
        #expect(state.auth == .authenticated(Identity.make("user-1")))
        await fake.clearCalls()
    }

    /// Yields until `condition` holds. Bounded (fails the test) but not timing-based.
    func waitUntil(_ what: String, sourceLocation: SourceLocation = #_sourceLocation,
                   _ condition: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()) {
            if ContinuousClock.now > deadline {
                Issue.record("timed out waiting for: \(what)", sourceLocation: sourceLocation)
                return
            }
            await Task.yield()
        }
    }

    func waitForArrival(_ g: FakeBoxd.Gate, _ n: Int, sourceLocation: SourceLocation = #_sourceLocation) async {
        await waitUntil("\(n) \(g) call(s)", sourceLocation: sourceLocation) { await fake.arrived(g) >= n }
    }

    /// Lets everything that can run, run. Used only to give a *wrong* implementation the chance to act
    /// before a "did not happen" assertion; positive expectations always use `waitUntil`.
    func settle() async {
        for _ in 0..<200 { await Task.yield() }
    }
}

// MARK: - Tests

@MainActor
struct AppStateTests {

    // MARK: 1. Coalescing refresh

    @Test func refreshDuringRefreshQueuesExactlyOneMoreRunAndAwaitsIt() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.gate(.listVms)

        let first = Task { await h.state.refresh() }
        await h.waitForArrival(.listVms, 1)
        #expect(h.state.isRefreshing)

        // Three more requests while the first is in flight: they coalesce into ONE extra run.
        let done = [Flag(), Flag(), Flag()]
        let others = done.map { flag in Task { await h.state.refresh(); flag.value = true } }
        await h.settle()
        #expect(await h.fake.arrived(.listVms) == 1)

        await h.fake.completeList(0, .success([try makeVm("a")]))
        await h.waitForArrival(.listVms, 2)
        #expect(h.state.vms.map(\.id) == ["a"])
        #expect(h.state.isRefreshing)
        #expect(done.allSatisfy { !$0.value }) // waiters wait for the queued run, not just the first

        await h.fake.completeList(1, .success([try makeVm("a"), try makeVm("b")]))
        await first.value
        for t in others { await t.value }

        #expect(await h.fake.listCalls.count == 2)
        #expect(h.state.vms.map(\.id) == ["a", "b"])
        #expect(!h.state.isRefreshing)
        #expect(done.allSatisfy { $0.value })
    }

    @Test func resultForOldScopeModeIsDroppedAndQueuedRunCoversNewScope() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.gate(.listVms)

        let r = Task { await h.state.refresh() }
        await h.waitForArrival(.listVms, 1)
        h.state.scopeMode = .personal // queues a refresh (didSet)
        await h.fake.completeList(0, .success([try makeVm("stale")]))
        await h.waitForArrival(.listVms, 2)
        #expect(h.state.vms.isEmpty) // old-scope result was not applied
        await h.fake.completeList(1, .success([try makeVm("fresh")]))
        await r.value
        await h.waitUntil("scope-change refresh settled") { !h.state.isRefreshing }

        #expect(await h.fake.listCalls == [
            .listVms(org: "", allContexts: true),   // allContexts (the default)
            .listVms(org: "", allContexts: false),  // personal
        ])
        #expect(h.state.vms.map(\.id) == ["fresh"])
    }

    @Test func resultForOldOrgNameIsDropped() async throws {
        let h = Harness(scope: .org, org: "acme")
        await h.signIn()
        await h.fake.gate(.listVms)

        let r = Task { await h.state.refresh() }
        await h.waitForArrival(.listVms, 1)
        h.state.orgName = "globex"
        await h.fake.completeList(0, .success([try makeVm("acme-vm")]))
        await h.waitForArrival(.listVms, 2)
        #expect(h.state.vms.isEmpty)
        await h.fake.completeList(1, .success([try makeVm("globex-vm")]))
        await r.value
        await h.waitUntil("org-change refresh settled") { !h.state.isRefreshing }

        #expect(await h.fake.listCalls == [
            .listVms(org: "acme", allContexts: false),
            .listVms(org: "globex", allContexts: false),
        ])
        #expect(h.state.vms.map(\.id) == ["globex-vm"])
    }

    @Test func resultAndErrorFromOldSessionAreDropped() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.gate(.listVms)

        let r = Task { await h.state.refresh() }
        await h.waitForArrival(.listVms, 1)
        h.state.signOut()
        #expect(!h.state.isRefreshing)
        await h.fake.completeList(0, .success([try makeVm("ghost")]))
        await r.value
        #expect(h.state.vms.isEmpty)
        #expect(h.state.auth == .unauthenticated)
    }

    @Test func errorFromOldSessionIsDropped() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.gate(.listVms)

        let r = Task { await h.state.refresh() }
        await h.waitForArrival(.listVms, 1)
        h.state.signOut()
        await h.fake.completeList(0, .failure(BoxdError.transport("late")))
        await r.value
        #expect(h.state.lastError == nil)
        #expect(h.state.auth == .unauthenticated)
    }

    // MARK: 2. Notices

    @Test func refreshClearsNoticesStampedBeforeItStarted() async throws {
        let h = Harness()
        await h.signIn()
        let vm = try makeVm("a")

        await h.state.perform(.start, on: vm) // notice "Starting…", then the post-action refresh
        #expect(h.state.notices.isEmpty)
        #expect(await h.fake.calls == [.action(.start, "a"), .listVms(org: "", allContexts: true)])
    }

    @Test func refreshKeepsNoticesStampedAfterItStarted() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.gate(.listVms, .action)
        let vm = try makeVm("b")

        let r = Task { await h.state.refresh() }
        await h.waitForArrival(.listVms, 1)

        let p = Task { await h.state.perform(.hibernate, on: vm) } // stamps a notice mid-refresh
        await h.waitForArrival(.action, 1)
        #expect(h.state.notices["b"] == "Hibernating…")

        await h.fake.completeList(0, .success([vm])) // the in-flight refresh began before the notice
        await r.value
        #expect(h.state.notices["b"] == "Hibernating…")

        await h.fake.completeAction(0) // action done -> post-action refresh (began after the notice)
        await h.waitForArrival(.listVms, 2)
        await h.fake.completeList(1, .success([vm]))
        await p.value
        #expect(h.state.notices.isEmpty)
    }

    // MARK: 3. Sign-out race

    @Test func submitAPIKeyAwaitsPendingResetBeforeSettingKey() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.gate(.reset)

        h.state.signOut()
        await h.waitForArrival(.reset, 1)
        let submit = Task { await h.state.submitAPIKey("new-key") }
        await h.settle()
        #expect(await h.fake.calls == [.resetStarted]) // setAPIKey must not run yet

        await h.fake.completeReset(0)
        await submit.value

        #expect(await h.fake.calls == [
            .resetStarted, .resetFinished,
            .setAPIKey("new-key"), .whoami, .listVms(org: "", allContexts: true),
        ])
        #expect(h.state.auth == .authenticated(Identity.make("user-1")))
        #expect(h.keys.stored == "new-key")
    }

    @Test func bootstrapAwaitsPendingResetBeforeSettingKey() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.gate(.reset)

        h.state.signOut()
        h.keys.stored = "saved-key" // a key is back in the store by the time bootstrap runs
        await h.waitForArrival(.reset, 1)
        let boot = Task { await h.state.retryBootstrap() }
        await h.settle()
        #expect(await h.fake.calls == [.resetStarted])

        await h.fake.completeReset(0)
        await boot.value

        #expect(await h.fake.calls == [
            .resetStarted, .resetFinished,
            .setAPIKey("saved-key"), .whoami, .listVms(org: "", allContexts: true),
        ])
        #expect(h.state.auth == .authenticated(Identity.make("user-1")))
    }

    @Test func bootstrapWithoutSavedKeyGoesUnauthenticated() async {
        let h = Harness()
        await h.state.retryBootstrap()
        #expect(h.state.auth == .unauthenticated)
        #expect(await h.fake.calls.isEmpty)
    }

    // MARK: 4. Submission generation

    @Test func newerSubmissionWinsWhenItFinishesFirst() async throws {
        let h = Harness()
        await h.fake.gate(.whoami)
        let a = Task { await h.state.submitAPIKey("A") }
        await h.waitForArrival(.whoami, 1)
        let b = Task { await h.state.submitAPIKey("B") }
        await h.waitForArrival(.whoami, 2)

        await h.fake.completeWhoami(1, .success(Identity.make("user-B")))
        await h.waitUntil("B signed in") { h.state.auth == .authenticated(Identity.make("user-B")) }
        await h.fake.completeWhoami(0, .success(Identity.make("user-A"))) // superseded
        await a.value
        await b.value

        #expect(h.keys.saves == ["B"])
        #expect(h.state.auth == .authenticated(Identity.make("user-B")))
        #expect(await h.fake.listCalls.count == 1) // only B refreshed
        #expect(h.state.lastError == nil)
    }

    @Test func olderSubmissionFinishingFirstChangesNothing() async throws {
        let h = Harness()
        await h.fake.gate(.whoami)
        let a = Task { await h.state.submitAPIKey("A") }
        await h.waitForArrival(.whoami, 1)
        let b = Task { await h.state.submitAPIKey("B") }
        await h.waitForArrival(.whoami, 2)

        await h.fake.completeWhoami(0, .success(Identity.make("user-A")))
        await a.value
        #expect(h.keys.saves.isEmpty)
        #expect(h.state.auth == .loading) // still B's in-flight state

        await h.fake.completeWhoami(1, .success(Identity.make("user-B")))
        await b.value
        #expect(h.keys.saves == ["B"])
        #expect(h.state.auth == .authenticated(Identity.make("user-B")))
    }

    @Test func supersededSubmissionFailureDoesNotTouchAuthOrError() async throws {
        let h = Harness()
        await h.fake.gate(.whoami)
        let a = Task { await h.state.submitAPIKey("A") }
        await h.waitForArrival(.whoami, 1)
        let b = Task { await h.state.submitAPIKey("B") }
        await h.waitForArrival(.whoami, 2)

        await h.fake.completeWhoami(0, .failure(BoxdError.authRejected))
        await a.value
        #expect(h.state.auth == .loading)
        #expect(h.state.lastError == nil)

        await h.fake.completeWhoami(1, .success(Identity.make("user-B")))
        await b.value
        #expect(h.state.auth == .authenticated(Identity.make("user-B")))
        #expect(h.keys.saves == ["B"])
    }

    @Test func failedSubmissionShowsErrorAndSavesNothing() async {
        let h = Harness()
        await h.fake.script(setAPIKey: .failure(BoxdError.authRejected))
        await h.state.submitAPIKey("  bad\n")
        #expect(h.state.auth == .unauthenticated)
        #expect(h.state.lastError == BoxdError.authRejected.errorDescription)
        #expect(h.keys.saves.isEmpty)
        #expect(await h.fake.calls == [.setAPIKey("bad")]) // trimmed
    }

    @Test func keychainSaveFailureWarnsAndWarningSurvivesRefresh() async {
        let h = Harness()
        h.keys.saveSucceeds = false
        await h.state.submitAPIKey("k")
        #expect(h.state.auth == .authenticated(Identity.make("user-1")))
        let warning = h.state.lastError
        #expect(warning?.hasPrefix("Couldn't save the API key") == true)
        await h.state.refresh()
        #expect(h.state.lastError == warning)
    }

    // MARK: 5. Cancellation is silent

    @Test func cancellationFromListVmsNeverSetsLastError() async {
        let h = Harness()
        await h.signIn()
        await h.fake.script(list: .failure(CancellationError()))
        await h.state.refresh()
        #expect(h.state.lastError == nil)
        await h.fake.script(list: .failure(URLError(.cancelled)))
        await h.state.refresh()
        #expect(h.state.lastError == nil)
        #expect(h.state.auth == .authenticated(Identity.make("user-1")))

        // Control: a real error does surface.
        await h.fake.script(list: .failure(BoxdError.transport("offline")))
        await h.state.refresh()
        #expect(h.state.lastError == "offline")
    }

    @Test func cancellationDuringSubmitIsSilent() async {
        let h = Harness()
        await h.fake.script(setAPIKey: .failure(CancellationError()))
        await h.state.submitAPIKey("k")
        #expect(h.state.auth == .unauthenticated)
        #expect(h.state.lastError == nil)
    }

    @Test func cancellationDuringActionClearsNoticeWithoutErrorOrRefresh() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.script(action: .failure(CancellationError()))
        await h.state.perform(.stop, on: try makeVm("a"))
        #expect(h.state.notices.isEmpty)
        #expect(h.state.lastError == nil)
        #expect(await h.fake.calls == [.action(.stop, "a")])
    }

    // MARK: 6. Auth rejected

    @Test func authRejectedDuringRefreshSignsOut() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.script(list: .failure(BoxdError.authRejected))
        await h.state.refresh()
        #expect(h.state.auth == .unauthenticated)
        #expect(h.state.lastError == BoxdError.authRejected.errorDescription)
        #expect(!h.state.isRefreshing)

        // The session is dead: further refreshes do nothing.
        await h.fake.clearCalls()
        await h.state.refresh()
        #expect(await h.fake.calls.isEmpty)
    }

    // MARK: 7. Actions

    @Test func performSetsProgressNoticeCallsClientThenRefreshes() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.gate(.action)
        let vm = try makeVm("vm-1", "stopped")
        await h.fake.script(list: .success([try makeVm("vm-1", "starting")]))

        let p = Task { await h.state.perform(.start, on: vm) }
        await h.waitForArrival(.action, 1)
        #expect(h.state.notices["vm-1"] == "Starting…")
        #expect(await h.fake.calls == [.action(.start, "vm-1")]) // no refresh before the action returns

        await h.fake.completeAction(0)
        await p.value
        #expect(await h.fake.calls == [.action(.start, "vm-1"), .listVms(org: "", allContexts: true)])
        #expect(h.state.vms.map(\.id) == ["vm-1"])
        #expect(h.state.notices.isEmpty)
    }

    @Test func performPassesTheRequestedAction() async throws {
        let h = Harness()
        await h.signIn()
        for action in [VmAction.reboot, .destroy, .wake] {
            await h.state.perform(action, on: try makeVm("x"))
        }
        let actions = await h.fake.calls.compactMap { call -> VmAction? in
            if case .action(let a, "x") = call { a } else { nil }
        }
        #expect(actions == [.reboot, .destroy, .wake])
    }

    @Test func actionFailureNoticeSurvivesPostActionRefresh() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.script(list: .success([try makeVm("a", "running")]),
                            action: .failure(BoxdError.grpc(status: 9, message: "boom")))

        await h.state.perform(.hibernate, on: try makeVm("a"))

        #expect(await h.fake.calls == [.action(.hibernate, "a"), .listVms(org: "", allContexts: true)])
        #expect(h.state.vms.map(\.id) == ["a"]) // state was synced first...
        #expect(h.state.notices["a"] == "boom") // ...then the failure surfaced, uncleared
    }

    @Test func signOutDuringActionSkipsRefreshAndNotice() async throws {
        let h = Harness()
        await h.signIn()
        await h.fake.gate(.action)
        let vm = try makeVm("a")
        let p = Task { await h.state.perform(.stop, on: vm) }
        await h.waitForArrival(.action, 1)

        h.state.signOut()
        await h.fake.completeAction(0, .failure(BoxdError.transport("late")))
        await p.value

        #expect(h.state.notices.isEmpty)
        #expect(h.state.lastError == nil)
        #expect(await h.fake.calls.filter { if case .listVms = $0 { true } else { false } }.isEmpty)
    }
}
