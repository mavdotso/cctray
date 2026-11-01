import AppKit

@MainActor
final class LoginMaintenance {
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var lastCodexCheck = Date.distantPast
    private let claude: AccountStore
    private let codex: CodexAccounts

    init(claude: AccountStore, codex: CodexAccounts) {
        self.claude = claude
        self.codex = codex
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.tick(force: true) }
        }
        tick(force: true)
    }

    func tick(force: Bool = false) {
        guard task == nil else { return }
        task = Task {
            defer { task = nil }
            await claude.maintainLogins()
            guard CodingAgent.codex.isEnabled else { return }
            guard force || Date().timeIntervalSince(lastCodexCheck) >= 300 else { return }
            lastCodexCheck = Date()
            await codex.model.refresh(force: force)
            if codex.model.loadedProfile == "default", let email = codex.model.email {
                codex.captureCurrentLogin(email: email)
            }
            await codex.refreshProfileUsage(minimumInterval: force ? 0 : 300)
        }
    }
}
