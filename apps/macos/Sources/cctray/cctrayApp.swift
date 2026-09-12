import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let awake = AwakeController()
    var usageModel: UsageModel { accounts.usageModel }
    var codex: CodexModel { codexAccounts.model }
    let codexAccounts = CodexAccounts()
    let preWarm = PreWarmController()
    let attention = AttentionCenter()
    let sessions = SessionModel()
    let worktrees = WorktreeModel()
    let accounts = AccountStore()
    private var menuTask: Task<Void, Never>?
    @Published var launchError: String?

    init() {
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("CLAUDE") {
            unsetenv(key)
        }
        usageModel.startPolling()
        codex.start()
        preWarm.start(usageModel: usageModel, codex: codex)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard let agent = AgentHotkey.agent(keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection(AgentHotkey.relevantFlags).rawValue) else { return }
            Task { @MainActor [weak self] in
                self?.launchError = TerminalLauncher.newSession(agent: agent)
            }
        }
        attention.start()
        sessions.startAutoAwake(awake: awake)
        TerminalLauncher.requestPermissionsOnFirstLaunch()
    }

    func menuDidOpen() {
        sessions.startMenuUpdates()
        attention.clearLog()
        worktrees.refresh()
        if CodingAgent.claude.isEnabled { accounts.refreshIdentity() }
        menuTask?.cancel()
        menuTask = Task { [weak self] in
            guard let self else { return }
            await sessions.refresh()
            await codex.refresh()
            if codex.loadedProfile == "default", let email = codex.email {
                codexAccounts.captureCurrentLogin(email: email)
            }
            await codexAccounts.refreshProfileUsage()
            guard !Task.isCancelled else { return }
            await usageModel.refresh()
            guard !Task.isCancelled else { return }
            if CodingAgent.claude.isEnabled { await accounts.refreshProfileUsage() }
        }
    }

    func agentSettingsChanged() {
        attention.updateAgents()
        Task {
            await sessions.refresh()
            await usageModel.refresh(force: true)
            await codex.refresh(force: true)
        }
    }

    func menuDidClose() {
        sessions.stopMenuUpdates()
        menuTask?.cancel()
        menuTask = nil
    }

    static let trayIcon: NSImage = {
        let img = Bundle.module.url(forResource: "console", withExtension: "svg")
            .flatMap(NSImage.init(contentsOf:)) ?? NSImage()
        img.isTemplate = true
        img.size = NSSize(width: 18, height: 18)
        return img
    }()
}

@main
struct cctrayApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(state)
        } label: {
            Image(nsImage: AppState.trayIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Clean Worktrees", id: "cleanWorktrees") {
            CleanWorktreesView(worktrees: state.worktrees)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Settings {
            SettingsView().environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}
