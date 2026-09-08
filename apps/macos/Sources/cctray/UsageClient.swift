import Foundation

struct UsageWindow: Decodable {
    let utilization: Double
    let resetsAt: Date?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct LimitEntry: Decodable {
    let kind: String
    let percent: Double
    let resetsAt: Date?
    let scope: Scope?
    struct Scope: Decodable {
        let model: Model?
        struct Model: Decodable {
            let displayName: String?
            enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
    }
    enum CodingKeys: String, CodingKey {
        case kind, percent, scope
        case resetsAt = "resets_at"
    }
}

struct Usage: Decodable {
    let fiveHour: UsageWindow
    let sevenDay: UsageWindow
    let limits: [LimitEntry]?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }

    struct TopLimit { let label: String, percent: Double, resetsAt: Date? }

    static func windowLabel(_ group: String) -> String {
        switch group {
        case "session": return "5h"
        case let g where g.hasPrefix("weekly"): return "week"
        case let g where g.hasPrefix("monthly"): return "month"
        default: return group
        }
    }

    /* The switcher has room for one number, so show the limit that binds first. */
    var topLimit: TopLimit {
        if let top = limits?.max(by: { $0.percent < $1.percent }) {
            return TopLimit(label: Self.windowLabel(top.kind),
                            percent: top.percent, resetsAt: top.resetsAt)
        }
        return sevenDay.utilization > fiveHour.utilization
            ? TopLimit(label: "week", percent: sevenDay.utilization, resetsAt: sevenDay.resetsAt)
            : TopLimit(label: "5h", percent: fiveHour.utilization, resetsAt: fiveHour.resetsAt)
    }

    var modelLimit: (label: String, window: UsageWindow)? {
        limits?.lazy.compactMap { l -> (String, UsageWindow)? in
            guard l.kind == "weekly_scoped",
                  let name = l.scope?.model?.displayName else { return nil }
            return (name, UsageWindow(utilization: l.percent, resetsAt: l.resetsAt))
        }.first
    }
}

enum UsageParser {
    static func parse(_ data: Data) throws -> Usage {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            guard let date = try? Date.ISO8601FormatStyle().parse(s) else {
                throw DecodingError.dataCorruptedError(
                    in: try d.singleValueContainer(),
                    debugDescription: "Bad date: \(s)")
            }
            return date
        }
        return try dec.decode(Usage.self, from: data)
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }
}

enum UsageFetchError: Error { case http(Int) }

func fetchUsage(token: String) async throws -> (Usage, Data) {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else { throw UsageFetchError.http(code) }
    return (try UsageParser.parse(data), data)
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var usage: Usage?
    @Published var authFailed = false
    @Published var isStale = false
    private var timer: Timer?
    private var backoffUntil = Date.distantPast
    private var lastSuccess = Date.distantPast

    func startPolling() {
        if let data = UserDefaults.standard.data(forKey: PrefKey.usageCache),
           let cached = try? UsageParser.parse(data) {
            usage = cached
            isStale = true
        }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor in await self.refresh() }
        }
        Task { await refresh() }
    }

    enum Outcome { case fetched, skipped, failed }

    @discardableResult
    func refresh(force: Bool = false, retrying: Bool = false) async -> Outcome {
        guard Date() >= backoffUntil else { return .skipped }
        guard force || usage == nil || Date().timeIntervalSince(lastSuccess) >= 60 else { return .skipped }
        guard let token = ClaudeKeychain.accessToken() else {
            usage = nil
            authFailed = true
            return .failed
        }
        do {
            let (fetched, data) = try await fetchUsage(token: token)
            usage = fetched
            lastSuccess = Date()
            UserDefaults.standard.set(data, forKey: PrefKey.usageCache)
            authFailed = false
            isStale = false
            return .fetched
        } catch UsageFetchError.http(401) {
            ClaudeKeychain.invalidateCache()
            if !retrying { return await refresh(force: true, retrying: true) }
            usage = nil
            authFailed = true
            return .failed
        } catch UsageFetchError.http(429) {
            backoffUntil = Date().addingTimeInterval(usage == nil ? 120 : 900)
            authFailed = false
            isStale = usage != nil
            return .failed
        } catch {
            authFailed = false
            isStale = usage != nil
            return .failed
        }
    }
}
