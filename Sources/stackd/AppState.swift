import AppKit
import Foundation
import Observation

enum ScopeMode: String, CaseIterable, Hashable {
    case personal, allContexts, org
}

/// Cancellation (task cancelled, URLSession cancelled) is never a user-visible error.
private func isCancellation(_ error: Error) -> Bool {
    error is CancellationError || (error as? URLError)?.code == .cancelled
}

/// The slice of `BoxdClient` that `AppState` uses; tests substitute a fake.
protocol BoxdAPI: Sendable {
    func setAPIKey(_ key: String) async throws
    func reset() async
    func whoami() async throws -> Identity
    func listVms(org: String, allContexts: Bool) async throws -> [Vm]
    func performVmAction(_ action: VmAction, vmID: String) async throws
}

extension BoxdClient: BoxdAPI {}

/// Where the API key lives. Production uses the Keychain; tests substitute an in-memory store.
struct KeyStore: Sendable {
    var load: @Sendable () -> String?
    var save: @Sendable (String) -> Bool
    var delete: @Sendable () -> Void

    static let keychain = KeyStore(
        load: { KeychainStore.loadAPIKey() },
        save: { KeychainStore.saveAPIKey($0) },
        delete: { KeychainStore.deleteAPIKey() })
}

/// Root state: auth, VM list, poll loop, actions. Lives for the app's lifetime.
@Observable @MainActor final class AppState {
    enum AuthState: Hashable {
        case loading
        case unauthenticated
        case authenticated(Identity)
    }

    private(set) var auth: AuthState = .loading
    private(set) var vms: [Vm] = []
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    var lastError: String?
    /// Transient per-VM feedback ("Starting…", error text). A refresh clears only notices set before it began.
    var notices: [String: String] = [:]

    // Settings (persisted). didSet side effects are skipped while `restoring` and when the value didn't change.
    var pollInterval: Double = 15 {
        didSet {
            guard !restoring, pollInterval != oldValue else { return }
            defaults.set(pollInterval, forKey: "pollInterval")
            startPolling()
        }
    }
    var scopeMode: ScopeMode = .allContexts {
        didSet {
            guard !restoring, scopeMode != oldValue else { return }
            defaults.set(scopeMode.rawValue, forKey: "scopeMode")
            Task { await refresh() }
        }
    }
    var orgName: String = "" {
        didSet {
            guard !restoring, orgName != oldValue else { return }
            defaults.set(orgName, forKey: "orgName")
            if scopeMode == .org { Task { await refresh() } }
        }
    }

    private let client: any BoxdAPI
    @ObservationIgnored private let keyStore: KeyStore
    @ObservationIgnored private let defaults: UserDefaults
    /// False in tests: no wake observer, no bootstrap at init, no poll loop.
    @ObservationIgnored private let runsBackgroundWork: Bool
    @ObservationIgnored private var restoring = true
    /// True only for instances built by `demo(...)`: never touches the network, Keychain or defaults.
    @ObservationIgnored private let isDemo: Bool
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var bootstrapRetryTask: Task<Void, Never>?
    @ObservationIgnored private var bootstrapAttempts = 0
    @ObservationIgnored private var pendingRefresh = false
    /// Bumped on sign-out, auth rejection and successful sign-in; results from an older session are dropped.
    @ObservationIgnored private var sessionGen = 0
    /// Bumped by every `submitAPIKey`; only the latest submission may save the key or touch auth state.
    @ObservationIgnored private var submissionGen = 0
    /// Client reset queued by `signOut()`; sign-in paths await it so it can't wipe a newer key.
    @ObservationIgnored private var pendingReset: Task<Void, Never>?
    @ObservationIgnored private var noticeStamps: [String: Date] = [:]
    @ObservationIgnored private var lastActionDone: Date?
    @ObservationIgnored private var lastIdentityCheck: Date?
    @ObservationIgnored private var identityInFlight = false
    /// Survives successful refreshes (which reset `lastError`) until sign-out.
    @ObservationIgnored private var keychainWarning: String?

    private static let fastPollInterval: Double = 3
    private static let fastPollWindow: TimeInterval = 30
    private static let identityPollAge: TimeInterval = 300
    private static let bootstrapBackoff: [Double] = [2, 4, 8, 16, 30]

    /// The one instance. `init` has side effects (sign-in, wake observer), and SwiftUI may build the
    /// `App` struct — and evaluate a `@State` initial value — more than once, so the app must not
    /// construct AppState itself (a discarded second instance caused an extra sign-in at launch).
    static let shared: AppState = {
        migrateLegacySettings(into: .standard)
        return AppState()
    }()

    /// One-time migration of settings from the legacy boxd-bar defaults domain.
    private static func migrateLegacySettings(into d: UserDefaults) {
        let settingKeys = ["pollInterval", "scopeMode", "orgName"]
        if !settingKeys.contains(where: { d.object(forKey: $0) != nil }),
           let old = UserDefaults(suiteName: "sh.boxd.bar") {
            for k in settingKeys {
                if let v = old.object(forKey: k) { d.set(v, forKey: k) }
            }
        }
    }

    private convenience init() {
        self.init(client: BoxdClient(), keyStore: .keychain, defaults: .standard, autostart: true)
    }

    /// `autostart: false` (tests) skips the wake observer, the initial `bootstrap` and the poll loop.
    init(client: any BoxdAPI, keyStore: KeyStore, defaults: UserDefaults, autostart: Bool) {
        isDemo = false
        self.client = client
        self.keyStore = keyStore
        self.defaults = defaults
        runsBackgroundWork = autostart
        let d = defaults
        if let pi = d.object(forKey: "pollInterval") as? Double, pi > 0 { pollInterval = pi }
        if let sm = d.string(forKey: "scopeMode"), let m = ScopeMode(rawValue: sm) { scopeMode = m }
        if let on = d.string(forKey: "orgName") { orgName = on }
        restoring = false

        guard autostart else { return }
        _ = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWake() }
        }
        log.debug("AppState created")
        Task { await bootstrap() }
    }

    /// Demo/screenshot-only: a pre-filled, signed-in instance that does no I/O. It skips `bootstrap`, the
    /// wake observer and the defaults migration, and `menuDidOpen`, `refresh`, `refreshIdentity` and
    /// `perform` are no-ops while `isDemo`, so nothing can reach `BoxdClient`. Used by tests only.
    private init(demo identity: Identity, vms: [Vm], lastRefresh: Date) {
        isDemo = true
        client = BoxdClient()
        keyStore = .keychain
        defaults = .standard
        runsBackgroundWork = false
        restoring = false
        auth = .authenticated(identity)
        self.vms = Self.sort(vms)
        self.lastRefresh = lastRefresh
    }

    static func demo(identity: Identity, vms: [Vm], lastRefresh: Date) -> AppState {
        AppState(demo: identity, vms: vms, lastRefresh: lastRefresh)
    }

    deinit {
        pollTask?.cancel()
        refreshLoop?.cancel()
        bootstrapRetryTask?.cancel()
    }

    private var isAuthenticated: Bool {
        if case .authenticated = auth { return true }
        return false
    }

    private var scopeKey: String {
        scopeMode == .org ? "org:" + orgName.trimmingCharacters(in: .whitespaces) : scopeMode.rawValue
    }

    private func setNotice(_ id: String, _ text: String) {
        notices[id] = text
        noticeStamps[id] = .now
    }

    // MARK: Auth

    /// Invalidates everything in flight for the current session.
    private func invalidateSession() {
        sessionGen += 1
        pollTask?.cancel()
        pollTask = nil
        refreshLoop = nil
        pendingRefresh = false
        isRefreshing = false
    }

    private func didSignIn(_ identity: Identity) {
        invalidateSession()
        bootstrapRetryTask?.cancel()
        bootstrapRetryTask = nil
        bootstrapAttempts = 0
        lastIdentityCheck = .now
        auth = .authenticated(identity)
        startPolling()
    }

    private func authWasRejected() {
        invalidateSession()
        auth = .unauthenticated
        lastError = BoxdError.authRejected.errorDescription
    }

    private func awaitPendingReset() async {
        while let reset = pendingReset {
            await reset.value
            if pendingReset == reset { pendingReset = nil }
        }
    }

    private func bootstrap() async {
        log.debug("bootstrap (signing in from the saved key)")
        await awaitPendingReset()
        let gen = sessionGen
        guard let key = keyStore.load(), !key.isEmpty else {
            auth = .unauthenticated
            return
        }
        do {
            try await client.setAPIKey(key)
            let identity = try await client.whoami()
            guard gen == sessionGen else { return }
            didSignIn(identity)
            await refresh()
        } catch {
            guard gen == sessionGen, !isCancellation(error), !Task.isCancelled else { return }
            if case BoxdError.authRejected = error {
                bootstrapRetryTask = nil
                auth = .unauthenticated
                lastError = "Saved API key was rejected — paste a new one."
            } else {
                // Network down at launch etc.: stay on the connecting screen and retry with backoff.
                lastError = error.localizedDescription
                scheduleBootstrapRetry()
            }
        }
    }

    private func scheduleBootstrapRetry() {
        let delay = Self.bootstrapBackoff.indices.contains(bootstrapAttempts)
            ? Self.bootstrapBackoff[bootstrapAttempts] : 60
        bootstrapAttempts += 1
        // The task also runs the attempt, so cancelling it aborts both the wait and an in-flight try.
        bootstrapRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            if Task.isCancelled { return }
            await self?.bootstrap()
        }
    }

    func retryBootstrap() async {
        bootstrapRetryTask?.cancel()
        bootstrapRetryTask = nil
        auth = .loading
        lastError = nil
        await bootstrap()
    }

    func submitAPIKey(_ raw: String) async {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        bootstrapRetryTask?.cancel()
        bootstrapRetryTask = nil
        auth = .loading
        lastError = nil
        keychainWarning = nil
        submissionGen += 1
        let sub = submissionGen
        let gen = sessionGen
        func isCurrent() -> Bool { sub == submissionGen && gen == sessionGen }
        do {
            await awaitPendingReset()
            guard isCurrent() else { return }
            try await client.setAPIKey(key)
            let identity = try await client.whoami()
            guard isCurrent() else { return }
            if !keyStore.save(key) {
                keychainWarning = "Couldn't save the API key to the Keychain — you'll need to enter it again next launch."
            }
            didSignIn(identity)
            lastError = keychainWarning
            await refresh()
        } catch {
            guard isCurrent() else { return }
            auth = .unauthenticated
            if !isCancellation(error) { lastError = error.localizedDescription }
        }
    }

    func signOut() {
        invalidateSession()
        bootstrapRetryTask?.cancel()
        bootstrapRetryTask = nil
        bootstrapAttempts = 0
        keyStore.delete()
        pendingReset = Task { [client] in await client.reset() }
        vms = []
        notices = [:]
        noticeStamps = [:]
        lastActionDone = nil
        lastIdentityCheck = nil
        keychainWarning = nil
        lastError = nil
        lastRefresh = nil
        auth = .unauthenticated
    }

    /// Called by the menu window each time it opens.
    func menuDidOpen() {
        guard !isDemo, isAuthenticated else { return }
        if lastRefresh.map({ Date.now.timeIntervalSince($0) > 5 }) ?? true {
            Task { await refresh() }
        }
        Task { await refreshIdentity(ifOlderThan: 60) }
    }

    private func handleWake() {
        if isAuthenticated {
            Task { await refresh() }
            Task { await refreshIdentity(ifOlderThan: 0) }
        } else if bootstrapRetryTask != nil {
            Task { await retryBootstrap() }
        }
    }

    /// Re-reads identity (credits balance). Failure leaves auth untouched, except a rejected key.
    private func refreshIdentity(ifOlderThan age: TimeInterval) async {
        guard !isDemo, case .authenticated(let current) = auth, !identityInFlight else { return }
        if let last = lastIdentityCheck, Date.now.timeIntervalSince(last) < age { return }
        let gen = sessionGen
        identityInFlight = true
        lastIdentityCheck = .now
        defer { identityInFlight = false }
        do {
            let identity = try await client.whoami()
            guard gen == sessionGen, isAuthenticated else { return }
            if identity != current { auth = .authenticated(identity) }
        } catch BoxdError.authRejected {
            guard gen == sessionGen, isAuthenticated else { return }
            authWasRejected()
        } catch {}
    }

    // MARK: Polling / refresh

    private func pollDelay() -> Double {
        let busy = vms.contains { $0.status.isTransitional }
            || lastActionDone.map { Date.now.timeIntervalSince($0) < Self.fastPollWindow } ?? false
        return busy ? min(Self.fastPollInterval, pollInterval) : pollInterval
    }

    private func startPolling() {
        pollTask?.cancel()
        guard runsBackgroundWork, isAuthenticated else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                // Delay is recomputed every iteration so state changes speed up or slow down polling.
                guard let delay = self?.pollDelay() else { return }
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                guard let self else { return }
                Task { await self.refreshIdentity(ifOlderThan: Self.identityPollAge) }
                await self.refresh()
            }
        }
    }

    /// Refreshes the VM list. If one is already running, queues exactly one more run and waits for it,
    /// so settings changes and post-action refreshes are never dropped.
    func refresh() async {
        guard !isDemo, isAuthenticated else { return }
        if let loop = refreshLoop {
            pendingRefresh = true
            await loop.value
            return
        }
        let gen = sessionGen
        isRefreshing = true
        let loop = Task { await runRefreshLoop(gen) }
        refreshLoop = loop
        await loop.value
    }

    private func runRefreshLoop(_ gen: Int) async {
        repeat {
            pendingRefresh = false
            await refreshOnce(gen)
        } while pendingRefresh && gen == sessionGen && isAuthenticated
        if gen == sessionGen {
            refreshLoop = nil
            isRefreshing = false
        }
    }

    private func refreshOnce(_ gen: Int) async {
        let scope = scopeKey
        let started = Date.now
        do {
            let list = try await client.listVms(
                org: scopeMode == .org ? orgName.trimmingCharacters(in: .whitespaces) : "",
                allContexts: scopeMode == .allContexts)
            log.debug("ListVms scope=\(scope, privacy: .public) → \(list.count) vms: \(list.map { "\($0.name)=\($0.status.displayText)" }.joined(separator: ", "), privacy: .public)")
            // Stale if the session or scope changed meanwhile; a queued refresh covers the new scope.
            guard gen == sessionGen, isAuthenticated, scope == scopeKey else {
                log.debug("ListVms result dropped as stale")
                return
            }
            vms = Self.sort(list)
            for id in Array(notices.keys) where (noticeStamps[id] ?? .distantPast) < started {
                notices[id] = nil
                noticeStamps[id] = nil
            }
            lastError = keychainWarning
            lastRefresh = .now
        } catch BoxdError.authRejected {
            guard gen == sessionGen, isAuthenticated else { return }
            authWasRejected()
        } catch {
            log.debug("ListVms failed: \(String(describing: error), privacy: .public)")
            guard gen == sessionGen, isAuthenticated, scope == scopeKey,
                  !isCancellation(error), !Task.isCancelled else { return }
            lastError = error.localizedDescription
        }
    }

    // MARK: Actions

    func perform(_ action: VmAction, on vm: Vm) async {
        guard !isDemo else { return }
        let gen = sessionGen
        setNotice(vm.id, "\(action.progressLabel)…")
        do {
            try await client.performVmAction(action, vmID: vm.id)
            guard gen == sessionGen else { return }
            lastActionDone = .now
            startPolling() // recompute the (now fast) poll delay
            await refresh()
        } catch {
            guard gen == sessionGen else { return }
            if isCancellation(error) {
                notices[vm.id] = nil
                noticeStamps[vm.id] = nil
                return
            }
            lastActionDone = .now
            startPolling()
            await refresh() // sync true state first, then surface the failure
            guard gen == sessionGen else { return }
            setNotice(vm.id, error.localizedDescription)
        }
    }

    // MARK: Sorting: running → transitional → standby → hibernated → stopped → failed

    private static func rank(_ status: VmStatus) -> Int {
        switch status {
        case .running: return 0
        case .transitional: return 1
        case .standby: return 2
        case .hibernated: return 3
        case .stopped: return 4
        case .failed: return 5
        case .unknown: return 6
        }
    }

    static func sort(_ list: [Vm]) -> [Vm] {
        list.sorted {
            (rank($0.status), $0.name.lowercased()) < (rank($1.status), $1.name.lowercased())
        }
    }
}
