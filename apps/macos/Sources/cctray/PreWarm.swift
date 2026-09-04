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
    @Published var isOn = UserDefaults.standard.bool(forKey: PrefKey.prewarmOn) {
        didSet { UserDefaults.standard.set(isOn, forKey: PrefKey.prewarmOn) }
    }
    @Published var lastError: String?
    private var firedFor: Date?
    weak var usageModel: UsageModel?

    var hours: ActiveHours {
        let d = UserDefaults.standard
        return ActiveHours(
            startMin: d.object(forKey: PrefKey.prewarmStartMin) as? Int
                ?? ActiveHours.default.startMin,
            endMin: d.object(forKey: PrefKey.prewarmEndMin) as? Int
                ?? ActiveHours.default.endMin)
    }

    func start(usageModel: UsageModel) {
        self.usageModel = usageModel
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.usageModel?.refresh()
                evaluate(usage: self.usageModel?.usage)
            }
        }
    }

    func evaluate(usage: Usage?) {
        guard isOn,
              PreWarmRule.shouldFire(now: Date(),
                                     resetsAt: usage?.fiveHour.resetsAt,
                                     hours: hours,
                                     firedFor: firedFor) else { return }
        firedFor = usage?.fiveHour.resetsAt
        Task { [weak self] in
            let status = await Self.runClaude()
            self?.finish(status: status)
        }
    }

    private func finish(status: Int32) {
        switch status {
        case 0:
            lastError = nil
            Task { [weak self] in await self?.usageModel?.refresh() }
            return
        case Self.couldNotStart:
            lastError = "Pre-warm failed: could not start zsh"
        case 127:
            lastError = "Pre-warm failed: claude not found in PATH"
        default:
            lastError = "Pre-warm failed: claude exited with status \(status)"
        }
        firedFor = nil
    }

    static let couldNotStart: Int32 = -1

    private static func runClaude() async -> Int32 {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-ilc", "claude -p \"hi\" --model haiku"]
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(returning: couldNotStart) }
        }
    }
}
