import Foundation

struct AgentSession: Identifiable {
    let pid: Int32
    let tty: String
    let cpu: Double
    let elapsed: TimeInterval
    var agent: CodingAgent = .claude
    var cwd = ""
    var title: String?
    var codexWorking: Bool?
    var id: Int32 { pid }
    var isWorking: Bool { agent == .codex ? (codexWorking ?? (cpu >= 5)) : cpu >= 5 }
}

enum Sessions {
    static func active(_ rows: [ProcRow]) -> [AgentSession] {
        rows.filter { $0.isInteractive && $0.tty != "??" && $0.ppid != 1 }
            .map { AgentSession(pid: $0.pid, tty: $0.tty, cpu: $0.cpu,
                                 elapsed: $0.elapsed, agent: $0.agent ?? .claude) }
            .sorted { ($0.elapsed, $0.tty) < ($1.elapsed, $1.tty) }
    }

    static func orphans(_ rows: [ProcRow]) -> [Int32] {
        rows.filter { $0.isClaude && $0.ppid == 1 }.map(\.pid)
    }

    static func parseCwds(lsofOutput: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in lsofOutput.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            if line.hasPrefix("n") { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    static func cwds(for sessions: [AgentSession]) -> [Int32: String] {
        guard !sessions.isEmpty else { return [:] }
        let pids = sessions.map { String($0.pid) }.joined(separator: ",")
        return parseCwds(lsofOutput: Shell.capture("/usr/sbin/lsof",
                                                   ["-a", "-p", pids, "-d", "cwd", "-Fn"]))
    }
}

enum AutoAwakeRule {
    enum Action { case engage, release }

    static func decide(active: Int, lastActive: Int, autoEngaged: Bool,
                       isOn: Bool, enabled: Bool) -> Action? {
        if !enabled { return autoEngaged ? .release : nil }
        if active > 0, lastActive == 0, !isOn { return .engage }
        if active == 0, autoEngaged { return .release }
        return nil
    }
}

@MainActor
final class SessionModel: ObservableObject {
    @Published var sessions: [AgentSession] = []
    @Published var orphanPids: [Int32] = []
    private var timer: Timer?
    private var menuTimer: Timer?
    private var lastActive = 0
    private var autoEngaged = false
    private var scanning = false

    private let discovery = SessionDiscovery()

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        let found = await Task.detached { [discovery] in discovery.scan() }.value
        scanning = false
        sessions = found.sessions
        orphanPids = found.orphans
    }

    func startMenuUpdates() {
        stopMenuUpdates()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTimer = timer
    }

    func stopMenuUpdates() {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    func killOrphans() {
        for pid in orphanPids { kill(pid, SIGTERM) }
        orphanPids = []
        Task { await refresh() }
    }

    func startAutoAwake(awake: AwakeController) {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor [weak self, weak awake] in
                guard let self, let awake else { return }
                let enabled = UserDefaults.standard.bool(forKey: PrefKey.autoAwake)
                let active = enabled
                    ? await Task.detached { Sessions.active(Proc.all()).filter { $0.agent.isEnabled }.count }.value
                    : 0
                switch AutoAwakeRule.decide(active: active, lastActive: self.lastActive,
                                            autoEngaged: self.autoEngaged,
                                            isOn: awake.isOn, enabled: enabled) {
                case .engage:
                    self.autoEngaged = true
                    awake.isOn = true
                case .release:
                    self.autoEngaged = false
                    awake.isOn = false
                case nil:
                    break
                }
                self.lastActive = active
            }
        }
    }
}
