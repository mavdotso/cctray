import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    let awake = AwakeController()
    let usageModel = UsageModel()
    let preWarm = PreWarmController()
    let attention = AttentionCenter()
    let sessions = SessionModel()
    let worktrees = WorktreeModel()
    let accounts = AccountStore()
    private var bag = Set<AnyCancellable>()
    private var menuTask: Task<Void, Never>?
    @Published var launchError: String?

    init() {
        for key in ProcessInfo.processInfo.environment.keys where key.hasPrefix("CLAUDE") {
            unsetenv(key)
        }
        accounts.usageModel = usageModel
        usageModel.startPolling()
        preWarm.start(usageModel: usageModel)
        usageModel.$usage
            .receive(on: RunLoop.main)
            .sink { [weak self] u in self?.preWarm.evaluate(usage: u) }
            .store(in: &bag)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    == [.command, .option],
                  event.charactersIgnoringModifiers?.lowercased()
                    == TerminalLauncher.newSessionHotkey else { return }
            Task { @MainActor [weak self] in
                self?.launchError = TerminalLauncher.newSession()
            }
        }
        attention.start()
        sessions.startAutoAwake(awake: awake)
        TerminalLauncher.requestPermissionsOnFirstLaunch()
    }

    func menuDidOpen() {
        attention.clearLog()
        worktrees.refresh()
        accounts.refreshIdentity()
        menuTask?.cancel()
        menuTask = Task { [weak self] in
            guard let self else { return }
            await sessions.refresh()
            guard !Task.isCancelled else { return }
            await usageModel.refresh()
            guard !Task.isCancelled else { return }
            await accounts.refreshProfileUsage()
        }
    }

    func menuDidClose() {
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
            SettingsView()
        }
    }
}
