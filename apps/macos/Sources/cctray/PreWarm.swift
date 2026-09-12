import AppKit
import Foundation

struct ActiveHours: Equatable {
    var startMin: Int
    var endMin: Int
    static let `default` = ActiveHours(startMin: 420, endMin: 1380)
}

enum PreWarmRule {
    static func minutesOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    static func inActiveHours(nowMinutes m: Int, hours: ActiveHours) -> Bool {
        if hours.startMin == hours.endMin { return true }
        if hours.startMin < hours.endMin { return m >= hours.startMin && m < hours.endMin }
        return m >= hours.startMin || m < hours.endMin
    }

    static func shouldFire(now: Date, resetsAt: Date?, hours: ActiveHours,
                           firedFor: Date?) -> Bool {
        guard let r = resetsAt, now >= r else { return false }
        guard inActiveHours(nowMinutes: minutesOfDay(now), hours: hours) else { return false }
        return firedFor != r
    }
}

@MainActor
final class PreWarmController: ObservableObject {
    private struct Target {
        let agent: CodingAgent
        let account: String
        let reset: Date?
        var profile: CodexProfile? = nil
        var key: String { agent.rawValue + ":" + account }
    }

    @Published var isOn = UserDefaults.standard.bool(forKey: PrefKey.prewarmOn) {
        didSet {
            defaults.set(isOn, forKey: PrefKey.prewarmOn)
            if isOn { Task { await tick() } }
        }
    }
    @Published private var errors: [CodingAgent: String] = [:]
    var lastError: String? { errors[.claude] ?? errors[.codex] }
    private let defaults = UserDefaults.standard
    private var fired: [String: Date] = [:]
    private var running = Set<CodingAgent>()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private weak var usageModel: UsageModel?
    private weak var codex: CodexModel?

    private var hours: ActiveHours {
        ActiveHours(
            startMin: defaults.object(forKey: PrefKey.prewarmStartMin) as? Int ?? ActiveHours.default.startMin,
            endMin: defaults.object(forKey: PrefKey.prewarmEndMin) as? Int ?? ActiveHours.default.endMin)
    }

    func start(usageModel: UsageModel, codex: CodexModel) {
        self.usageModel = usageModel
        self.codex = codex
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.tick() }
        }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.tick()
                await usageModel.refresh()
                await codex.refresh()
            }
        }
    }

    private func tick() async {
        var targets: [Target] = []
        if let usageModel, !usageModel.authFailed, !usageModel.isStale,
           let account = usageModel.loadedAccount, account == ClaudeConfig.currentEmail() {
            targets.append(Target(agent: .claude, account: account, reset: usageModel.usage?.fiveHour.resetsAt))
        }
        let profile = CodexAccounts.current
        let account = profile?.id ?? "default"
        if let codex, codex.error == nil, codex.loadedProfile == account {
            targets.append(Target(agent: .codex, account: account,
                                  reset: codex.limits?.sessionWindow?.reset, profile: profile))
        }
        await evaluate(targets)
    }

    private func evaluate(_ targets: [Target]) async {
        for target in targets {
            guard isOn, target.agent.isEnabled(in: defaults),
                  !running.contains(target.agent),
                  PreWarmRule.shouldFire(now: Date(), resetsAt: target.reset, hours: hours,
                                         firedFor: fired[target.key]) else { continue }
            fired[target.key] = target.reset
            running.insert(target.agent)
            let status = await Self.runCommand(target)
            running.remove(target.agent)
            guard let status else {
                fired[target.key] = nil
                continue
            }
            if status == 0 {
                errors[target.agent] = nil
                if target.agent == .claude { await usageModel?.refresh(force: true) }
                else { await codex?.refresh(force: true) }
            } else {
                errors[target.agent] = "\(target.agent.name) pre-warm failed (\(status))"
                if target.agent == .claude { fired[target.key] = nil }
            }
        }
    }

    private nonisolated static func runCommand(_ target: Target) async -> Int32? {
        await Task.detached { () -> Int32? in
            guard target.agent.isEnabled else { return nil }
            if target.agent == .claude {
                guard ClaudeConfig.currentEmail() == target.account else { return nil }
            } else {
                guard (CodexAccounts.current?.id ?? "default") == target.account else { return nil }
            }
            let command = target.agent == .claude
                ? "claude -p \"hi\" --model haiku"
                : CodexAccounts.command(
                    "exec --ephemeral --skip-git-repo-check --sandbox read-only -C /tmp -c 'notify=[]' 'Reply only with hi. Do not use tools.'",
                    profile: target.profile)
            return Shell.run("/bin/zsh", ["-ilc", command]).status
        }.value
    }
}
