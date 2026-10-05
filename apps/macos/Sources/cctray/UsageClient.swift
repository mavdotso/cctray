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
    /* The API sends microseconds. Older Foundation parses them without being
       asked; newer Foundation rejects them unless the style says so. */
    static func parseDate(_ s: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(s))
            ?? (try? Date.ISO8601FormatStyle().parse(s))
    }

    static func parse(_ data: Data) throws -> Usage {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(
                    in: try d.singleValueContainer(),
                    debugDescription: "Bad date: \(s)")
            }
            return date
        }
        return try dec.decode(Usage.self, from: data)
    }

    static func countdown(to date: Date) -> String {
        let s = max(0, Int(date.timeIntervalSinceNow))
        let d = s / 86400
        let h = (s % 86400) / 3600
        let m = (s % 3600) / 60
        if d > 0 { return h > 0 ? "\(d)d \(h)h" : "\(d)d" }
        if h > 0 { return m > 0 ? "\(h)h \(m)m" : "\(h)h" }
        return "\(m)m"
    }
}

enum UsageFetchError: Error { case http(Int), rateLimited(Date) }

func fetchUsage(token: String) async throws -> (Usage, Data) {
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.timeoutInterval = 30
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    let (data, resp) = try await URLSession.shared.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    if code == 429, let retry = RetryAfter.date((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")) {
        throw UsageFetchError.rateLimited(retry)
    }
    guard code == 200 else { throw UsageFetchError.http(code) }
    return (try UsageParser.parse(data), data)
}

@MainActor
final class ClaudeUsageClient {
    enum Failure: Error, Equatable {
        case login(ClaudeLoginError), rateLimited, retryLater, cancelled, unavailable
        var label: String {
            switch self {
            case .login(let error): error.label
            case .rateLimited, .retryLater: "rate limited"
            case .cancelled, .unavailable: "not available"
            }
        }
        var needsLogin: Bool { self == .login(.signIn) || self == .login(.notSaved) }
    }

    private let logins: ClaudeLoginManager
    private let fetch: (String) async throws -> (Usage, Data)
    private let now: () -> Date
    private var retryAfter: [ClaudeLogin.Identity: Date] = [:]
    private var pending: [String: Task<(Usage, Data), Error>] = [:]

    init(logins: ClaudeLoginManager, now: @escaping () -> Date = Date.init,
         fetch: @escaping (String) async throws -> (Usage, Data) = { try await fetchUsage(token: $0) }) {
        self.logins = logins
        self.now = now
        self.fetch = fetch
    }

    private func fetchToken(_ token: String, identity: ClaudeLogin.Identity) async throws -> (Usage, Data) {
        if let task = pending[token] { return try await task.value }
        let task = Task {
            do { return try await fetch(token) }
            catch {
                switch error {
                case UsageFetchError.http(429), UsageFetchError.rateLimited:
                    let fallback = now().addingTimeInterval(120)
                    if case UsageFetchError.rateLimited(let deadline) = error { retryAfter[identity] = max(fallback, deadline) }
                    else { retryAfter[identity] = fallback }
                default: break
                }
                throw error
            }
        }
        pending[token] = task
        defer { pending[token] = nil }
        return try await task.value
    }

    func read(for source: ClaudeLoginStorage.Source) async -> Result<(Usage, Data), Failure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let identity = logins.identity(for: source) else { return .failure(.login(.notSaved)) }
        retryAfter = retryAfter.filter { $0.value > now() }
        if retryAfter[identity] != nil { return .failure(.retryLater) }
        var rejectedToken: String?
        for attempt in 0..<2 {
            let result = await logins.token(for: source, rejectedToken: rejectedToken)
            guard !Task.isCancelled else { return .failure(.cancelled) }
            guard logins.identity(for: source) == identity else { return .failure(.login(.changed)) }
            let token: String
            switch result {
            case .success(let usable): token = usable
            case .failure(let error): return .failure(.login(error))
            }
            do {
                let usage = try await fetchToken(token, identity: identity)
                guard !Task.isCancelled else { return .failure(.cancelled) }
                guard logins.identity(for: source) == identity else { return .failure(.login(.changed)) }
                return .success(usage)
            } catch {
                guard !Task.isCancelled else { return .failure(.cancelled) }
                guard logins.identity(for: source) == identity else { return .failure(.login(.changed)) }
                switch error {
                case UsageFetchError.http(401):
                    if attempt == 0 { rejectedToken = token; continue }
                    guard logins.isCurrent(source, token: token) else { return .failure(.login(.changed)) }
                    logins.reject(source, token: token)
                    return .failure(.login(.signIn))
                case UsageFetchError.http(429), UsageFetchError.rateLimited:
                    return .failure(.rateLimited)
                default: return .failure(.unavailable)
                }
            }
        }
        return .failure(.unavailable)
    }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published private(set) var usage: Usage?
    @Published private(set) var authFailed = false
    @Published private(set) var isStale = false
    private let defaults: UserDefaults
    private let client: ClaudeUsageClient
    private let currentAccount: () -> String?
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private var generation = 0
    private var observedAccount: String?
    private(set) var loadedAccount: String?
    private var timer: Timer?
    private var lastSuccess = Date.distantPast

    init(client: ClaudeUsageClient,
         defaults: UserDefaults = .standard,
         currentAccount: @escaping () -> String? = ClaudeConfig.currentEmail,
         isEnabled: @escaping () -> Bool = { CodingAgent.claude.isEnabled },
         now: @escaping () -> Date = Date.init) {
        self.client = client
        self.defaults = defaults
        self.currentAccount = currentAccount
        self.isEnabled = isEnabled
        self.now = now
        observedAccount = currentAccount()
    }

    func accountChanged() {
        generation += 1
        observedAccount = currentAccount()
        usage = nil
        loadedAccount = nil
        authFailed = false
        isStale = false
        lastSuccess = .distantPast
        defaults.removeObject(forKey: PrefKey.usageCache)
        defaults.removeObject(forKey: PrefKey.usageCacheAccount)
    }

    func startPolling() {
        if let account = currentAccount(), defaults.string(forKey: PrefKey.usageCacheAccount) == account,
           let data = defaults.data(forKey: PrefKey.usageCache),
           let cached = try? UsageParser.parse(data) {
            loadedAccount = account
            usage = cached
            isStale = true
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    enum Outcome { case fetched, skipped, failed }

    @discardableResult
    func refresh(force: Bool = false) async -> Outcome {
        guard isEnabled() else { return .skipped }
        let account = currentAccount()
        if observedAccount != account { accountChanged() }
        let requestGeneration = generation
        guard force || usage == nil || now().timeIntervalSince(lastSuccess) >= 60 else { return .skipped }
        let result = await client.read(for: .current)
        guard !Task.isCancelled, isEnabled(), requestGeneration == generation,
              account == currentAccount() else { return .skipped }
        switch result {
        case .success(let (fetched, data)):
            loadedAccount = account
            usage = fetched
            lastSuccess = now()
            defaults.set(data, forKey: PrefKey.usageCache)
            defaults.set(account, forKey: PrefKey.usageCacheAccount)
            authFailed = false
            isStale = false
            return .fetched
        case .failure(let error):
            if error == .retryLater || error == .cancelled { return .skipped }
            authFailed = error.needsLogin
            if authFailed {
                usage = nil
                loadedAccount = nil
                defaults.removeObject(forKey: PrefKey.usageCache)
                defaults.removeObject(forKey: PrefKey.usageCacheAccount)
            }
            isStale = usage != nil
            return .failed
        }
    }
}
