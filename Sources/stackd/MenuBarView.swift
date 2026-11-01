import SwiftUI
import AppKit
import ServiceManagement

@main
struct StackdApp: App {
    private let state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu bar label (template mark + running count)

struct MenuBarLabel: View {
    let state: AppState
    @State private var pulse = StatusPulse()

    private var isConnecting: Bool {
        if case .loading = state.auth { return true }
        return false
    }

    private var runningCount: Int? {
        guard case .authenticated = state.auth else { return nil }
        let n = state.vms.filter { $0.status == .running }.count
        return n > 0 ? n : nil
    }

    private var hasError: Bool {
        if case .authenticated = state.auth { return state.lastError != nil }
        return false
    }

    private var description: String {
        switch state.auth {
        case .loading: return "Stackd, connecting"
        case .unauthenticated: return "Stackd, signed out"
        case .authenticated:
            if hasError { return "Stackd, error" }
            guard let n = runningCount else { return "Stackd, no machines running" }
            return "Stackd, \(n) \(n == 1 ? "machine" : "machines") running"
        }
    }

    var body: some View {
        // A fresh NSImage is built on every evaluation; the pulse alpha is observed, so the
        // label re-renders (and the status item image updates) on each animation tick.
        let style: StatusMark.Style = {
            if case .unauthenticated = state.auth { return .outline }
            return .solid
        }()
        let alpha: CGFloat = isConnecting ? pulse.alpha : 1
        HStack(spacing: 2) {
            Image(nsImage: StatusMark.image(style: style, badge: hasError, alpha: alpha))
            if let n = runningCount {
                Text("\(n)")
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(description)
        .onChange(of: isConnecting, initial: true) { _, connecting in
            pulse.setPulsing(connecting)
        }
    }
}

// MARK: - Hit targets

private extension View {
    /// 24×24 pt clickable area for bare icon buttons, without changing the glyph's look.
    func iconHitTarget() -> some View {
        frame(width: 24, height: 24).contentShape(Rectangle())
    }
}

// MARK: - Menu window

struct MenuBarView: View {
    @Bindable var state: AppState
    @State private var page = Page.main

    private enum Page { case main, settings }

    var body: some View {
        VStack(spacing: 0) {
            switch state.auth {
            case .loading:
                loadingView
            case .unauthenticated:
                SetupView(state: state)
            case .authenticated(let identity):
                if page == .settings {
                    SettingsView(state: state) { page = .main }
                } else {
                    mainView(identity)
                }
            }
        }
        .frame(width: 320)
        .onAppear { state.menuDidOpen() }
        // `.onAppear` is not guaranteed to refire when the panel reopens, so also
        // listen for the menu panel becoming key (sheets/dialogs are not NSPanels).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object is NSPanel { state.menuDidOpen() }
        }
        .onChange(of: state.auth) { _, auth in
            if case .authenticated = auth {} else { page = .main }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Connecting to boxd…").font(.callout)
            if let error = state.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry") { Task { await state.retryBootstrap() } }
            }
        }
        .padding()
    }

    private func mainView(_ identity: Identity) -> some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(identity.title).font(.headline).lineLimit(1)
                if let balance = identity.billing?.balanceLabel {
                    Text(balance).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if state.isRefreshing { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider()
            vmList
            Divider()
            footer
        }
    }

    // MARK: List

    @ViewBuilder
    private var vmList: some View {
        if state.vms.isEmpty && state.lastRefresh != nil {
            emptyState
        } else if state.vms.count > Self.maxUnscrolledRows {
            // Fixed height, no content measurement: a measured height read back from inside a
            // MenuBarExtra panel's ScrollView stayed 0, which collapsed the list.
            ScrollView { rows }.frame(height: Self.scrollHeight)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(state.vms) { vm in
                VmRow(vm: vm, notice: state.notices[vm.id]) { action in
                    Task { await state.perform(action, on: vm) }
                }
            }
        }
        .padding(6)
    }

    private static let maxUnscrolledRows = 9
    private static let scrollHeight: CGFloat = 420

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "server.rack").font(.title2).foregroundStyle(.secondary)
            Text("No machines").font(.callout.weight(.medium))
            Text("Create one with `boxd machine new`, or check the scope in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button { Task { await state.refresh() } } label: {
                Image(systemName: "arrow.clockwise").iconHitTarget()
            }
            .disabled(state.isRefreshing)
            .accessibilityLabel("Refresh")
            .help("Refresh now")

            if let last = state.lastRefresh {
                Text(last, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { page = .settings } label: { Image(systemName: "gear").iconHitTarget() }
                .accessibilityLabel("Settings")
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power").iconHitTarget() }
                .accessibilityLabel("Quit Stackd")
                .help("Quit Stackd")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - VM row

struct VmRow: View {
    let vm: Vm
    let notice: String?
    var onAction: (VmAction) -> Void
    @State private var confirm: VmAction?

    var body: some View {
        HStack(spacing: 4) {
            Button { openVM() } label: {
                HStack(spacing: 8) {
                    statusIndicator
                    VStack(alignment: .leading, spacing: 1) {
                        Text(vm.name).font(.system(.body, weight: .medium)).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let notice {
                        Text(notice).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu { actionMenu } label: { Image(systemName: "ellipsis.circle").iconHitTarget() }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(vm.name)")
                .help("Actions")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contextMenu { actionMenu }
        .confirmationDialog(confirmTitle, isPresented: confirmPresented, titleVisibility: .visible) {
            if let confirm {
                Button(confirm.label, role: confirm.isDestructive ? .destructive : nil) {
                    onAction(confirm)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if vm.status.isTransitional {
            ProgressView().controlSize(.mini).frame(width: 10, height: 10)
        } else {
            Circle().fill(statusColor).frame(width: 8, height: 8)
        }
    }

    private var statusColor: Color {
        switch vm.status {
        case .running: return .green
        case .standby: return .orange
        case .hibernated: return .purple
        case .failed: return .red
        case .stopped, .unknown: return .gray
        case .transitional: return .blue
        }
    }

    private var subtitle: String {
        var parts = [vm.sizeLabel, vm.status.displayText]
        if !vm.org.isEmpty { parts.append("shared: \(vm.org)") }
        if let host = vm.url?.host() { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionMenu: some View {
        let actions = VmAction.actions(for: vm.status)
        if actions.isEmpty {
            Text("No actions while \(vm.status.displayText)")
        } else {
            ForEach(actions, id: \.self) { action in
                if action.needsConfirm {
                    Button(action.label, role: action.isDestructive ? .destructive : nil) {
                        confirm = action
                    }
                } else {
                    Button(action.label) { onAction(action) }
                }
            }
        }
        if let url = vm.url {
            Divider()
            Button("Copy URL") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
    }

    private var confirmPresented: Binding<Bool> {
        Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })
    }

    private var confirmTitle: String {
        guard let confirm else { return "" }
        return "\(confirm.label) “\(vm.name)”?"
    }

    private var confirmMessage: String {
        switch confirm {
        case .destroy:
            return "Destroying deletes the VM and its disk. This cannot be undone."
        case .stop:
            return "The VM shuts down and stops billing for compute."
        case .reboot:
            return "The VM restarts; running processes are interrupted."
        case .none, .some:
            return ""
        }
    }

    private func openVM() {
        guard let url = vm.url else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Setup (first launch / signed out)

struct SetupView: View {
    let state: AppState
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to boxd").font(.headline)
            Text("Create an API key with `boxd auth keys create stackd` or at app.boxd.sh, then paste it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("bxd_…", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            if let error = state.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Keys see only the org they were created in — create the key in the org that owns your machines.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
    }

    private func submit() {
        Task { await state.submitAPIKey(key) }
    }
}

// MARK: - Settings (inline page)

struct SettingsView: View {
    @Bindable var state: AppState
    var onBack: () -> Void
    @State private var orgDraft = ""
    @FocusState private var orgFocused: Bool
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                row("Show machines") {
                    Picker("Show machines", selection: $state.scopeMode) {
                        Text("Personal only").tag(ScopeMode.personal)
                        Text("All contexts").tag(ScopeMode.allContexts)
                        Text("Specific org").tag(ScopeMode.org)
                    }
                }
                if state.scopeMode == .org {
                    TextField("Org name", text: $orgDraft)
                        .textFieldStyle(.roundedBorder)
                        .focused($orgFocused)
                        .onSubmit { commitOrg() }
                }
                row("Refresh every") {
                    Picker("Refresh every", selection: $state.pollInterval) {
                        Text("5 s").tag(5.0)
                        Text("10 s").tag(10.0)
                        Text("15 s").tag(15.0)
                        Text("30 s").tag(30.0)
                    }
                }
                Divider()
                launchAtLogin
                Divider()
                Button("Sign Out and Replace Key…") {
                    commitOrg()
                    state.signOut()
                }
                Text("Keys are org-scoped: create the key in the org that owns your machines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .onAppear {
            orgDraft = state.orgName
            loginStatus = SMAppService.mainApp.status
        }
        .onDisappear { commitOrg() }
        .onChange(of: orgFocused) { _, focused in if !focused { commitOrg() } }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { back() } label: {
                Image(systemName: "chevron.left").iconHitTarget()
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Back")
            .help("Back")
            Text("Settings").font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            Spacer()
            content().labelsHidden().fixedSize()
        }
    }

    // MARK: Launch at login

    private var launchAtLogin: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Launch at login", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { setLaunchAtLogin($0) }))
            if loginStatus == .requiresApproval {
                Text("Approval needed in System Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Launch at login only works from the installed app. \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }

    // MARK: Helpers

    private func commitOrg() {
        let trimmed = orgDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        orgDraft = trimmed
        if trimmed != state.orgName { state.orgName = trimmed }
    }

    private func back() {
        commitOrg()
        onBack()
    }
}
