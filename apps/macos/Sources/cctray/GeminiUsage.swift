import Foundation

struct GeminiQuotaBucket: Decodable, Equatable {
    let modelId: String?
    let bucketId: String?
    let window: String?
    let tokenType: String?
    let remainingFraction: Double?
    let resetTime: Date?

    var usedPercent: Double {
        let remaining = max(0, min(1, remainingFraction ?? 1))
        return (1 - remaining) * 100
    }
}

struct GeminiUsage: Decodable, Equatable {
    struct Window: Equatable {
        let label: String
        let shortLabel: String
        let usedPercent: Double
        let resetsAt: Date?
    }

    struct Group: Decodable, Equatable {
        let displayName: String?
        let buckets: [GeminiQuotaBucket]?
    }

    let groups: [Group]?
    let buckets: [GeminiQuotaBucket]

    enum CodingKeys: String, CodingKey { case groups, buckets }

    init(groups: [Group]? = nil, buckets: [GeminiQuotaBucket] = []) {
        self.groups = groups
        self.buckets = buckets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        groups = try container.decodeIfPresent([Group].self, forKey: .groups)
        buckets = try container.decodeIfPresent([GeminiQuotaBucket].self, forKey: .buckets) ?? []
    }

    private var geminiGroupBuckets: [GeminiQuotaBucket] {
        guard let groups, !groups.isEmpty else { return [] }
        if let geminiGroup = groups.first(where: { group in
            let name = (group.displayName ?? "").lowercased()
            let hasGeminiId = (group.buckets ?? []).contains { ($0.bucketId ?? "").lowercased().hasPrefix("gemini") }
            return name.contains("gemini") || hasGeminiId
        }) {
            return geminiGroup.buckets ?? []
        }
        return groups.first?.buckets ?? []
    }

    var sessionWindow: Window? {
        guard let bucket = geminiGroupBuckets.first(where: {
            $0.window == "5h" || ($0.bucketId ?? "").lowercased().contains("5h")
        }) else { return nil }
        return Window(label: "Session", shortLabel: "5h", usedPercent: bucket.usedPercent, resetsAt: bucket.resetTime)
    }

    var weeklyWindow: Window? {
        guard let bucket = geminiGroupBuckets.first(where: {
            $0.window == "weekly" || ($0.bucketId ?? "").lowercased().contains("weekly")
        }) else { return nil }
        return Window(label: "Week", shortLabel: "week", usedPercent: bucket.usedPercent, resetsAt: bucket.resetTime)
    }

    private func bindingWindow(label: String, matching predicate: (GeminiQuotaBucket) -> Bool) -> Window? {
        let matched = buckets.filter(predicate)
        guard let top = matched.max(by: { lhs, rhs in
            if lhs.usedPercent != rhs.usedPercent { return lhs.usedPercent < rhs.usedPercent }
            return (lhs.resetTime ?? .distantFuture) > (rhs.resetTime ?? .distantFuture)
        }) else { return nil }
        return Window(label: label, shortLabel: label.lowercased(), usedPercent: top.usedPercent, resetsAt: top.resetTime)
    }

    var proWindow: Window? {
        bindingWindow(label: "Pro") { ($0.modelId ?? "").lowercased().contains("pro") }
    }

    var flashWindow: Window? {
        bindingWindow(label: "Flash") {
            let id = ($0.modelId ?? "").lowercased()
            return id.contains("flash") && !id.contains("lite")
        }
    }

    var liteWindow: Window? {
        bindingWindow(label: "Lite") {
            let id = ($0.modelId ?? "").lowercased()
            return id.contains("flash") && id.contains("lite")
        }
    }

    var windows: [Window] {
        let summaryWindows = [sessionWindow, weeklyWindow].compactMap { $0 }
        if !summaryWindows.isEmpty { return summaryWindows }
        let grouped = [proWindow, flashWindow, liteWindow].compactMap { $0 }
        if !grouped.isEmpty { return grouped }
        guard let fallback = bindingWindow(label: "Usage", matching: { _ in true }) else { return [] }
        return [fallback]
    }

    var topLimit: Window? {
        windows.max(by: { $0.usedPercent < $1.usedPercent })
    }

    var preWarmReset: Date? {
        sessionWindow?.resetsAt ?? proWindow?.resetsAt ?? flashWindow?.resetsAt ?? windows.compactMap(\.resetsAt).min()
    }
}

enum GeminiUsageParser {
    static func parse(_ data: Data) throws -> GeminiUsage {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = UsageParser.parseDate(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Bad date: \(raw)")
            }
            return date
        }
        return try dec.decode(GeminiUsage.self, from: data)
    }
}

enum GeminiCodeAssist {
    static let dailyBaseURL = "https://daily-cloudcode-pa.googleapis.com/v1internal"
    static let prodBaseURL = "https://cloudcode-pa.googleapis.com/v1internal"
    static let antigravityUserAgent = "antigravity/hub/2.24.0"

    static func parseProjectID(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let project = obj["cloudaicompanionProject"] as? String, !project.isEmpty {
            return project
        }
        if let projectObj = obj["cloudaicompanionProject"] as? [String: Any],
           let id = projectObj["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    static func loadProjectID(token: String, isAntigravity: Bool) async throws -> String? {
        let base = isAntigravity ? dailyBaseURL : prodBaseURL
        var req = URLRequest(url: URL(string: base + ":loadCodeAssist")!)
        req.timeoutInterval = 30
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if isAntigravity {
            req.setValue(antigravityUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let body: [String: Any] = [
            "metadata": [
                "ideType": isAntigravity ? "ANTIGRAVITY" : "GEMINI_CLI",
                "platform": "DARWIN_ARM64",
                "pluginType": "GEMINI",
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429, let retry = RetryAfter.date((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")) {
            throw UsageFetchError.rateLimited(retry)
        }
        if code == 401 { throw UsageFetchError.http(401) }
        guard code == 200 else { return nil }
        return parseProjectID(from: data)
    }

    static func fetchQuota(token: String, projectID: String?, isAntigravity: Bool) async throws -> (GeminiUsage, Data) {
        let urlString = isAntigravity
            ? dailyBaseURL + ":retrieveUserQuotaSummary"
            : prodBaseURL + ":retrieveUserQuota"
        var req = URLRequest(url: URL(string: urlString)!)
        req.timeoutInterval = 30
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if isAntigravity {
            req.setValue(antigravityUserAgent, forHTTPHeaderField: "User-Agent")
        }
        let payload: [String: Any] = projectID.flatMap { $0.isEmpty ? nil : ["project": $0] } ?? [:]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 429, let retry = RetryAfter.date((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")) {
            throw UsageFetchError.rateLimited(retry)
        }
        guard code == 200 else { throw UsageFetchError.http(code) }
        return (try GeminiUsageParser.parse(data), data)
    }

    static func fetchUsage(token: String, projectID: String? = nil,
                           isAntigravity: Bool = GeminiCLI.isAgyInstalled) async throws -> (GeminiUsage, Data, String?) {
        let resolvedProject: String?
        if let projectID, !projectID.isEmpty {
            resolvedProject = projectID
        } else {
            resolvedProject = try await loadProjectID(token: token, isAntigravity: isAntigravity)
        }
        let (usage, data) = try await fetchQuota(token: token, projectID: resolvedProject, isAntigravity: isAntigravity)
        return (usage, data, resolvedProject)
    }
}

@MainActor
final class GeminiUsageClient {
    enum Failure: Error, Equatable {
        case login(GeminiLoginError), rateLimited, retryLater, cancelled, unavailable
        var label: String {
            switch self {
            case .login(let error): error.label
            case .rateLimited, .retryLater: "rate limited"
            case .cancelled, .unavailable: "not available"
            }
        }
        var needsLogin: Bool { self == .login(.signIn) || self == .login(.notSaved) }
    }

    private let logins: GeminiLoginManager
    private let fetch: (String, String?, Bool) async throws -> (GeminiUsage, Data, String?)
    private let now: () -> Date
    private var retryAfter: [GeminiLogin.Identity: Date] = [:]
    private var projectIDs: [GeminiLogin.Identity: String] = [:]
    private var pending: [String: Task<(GeminiUsage, Data), Error>] = [:]

    init(logins: GeminiLoginManager, now: @escaping () -> Date = Date.init,
         fetch: @escaping (String, String?, Bool) async throws -> (GeminiUsage, Data, String?) = {
             try await GeminiCodeAssist.fetchUsage(token: $0, projectID: $1, isAntigravity: $2)
         }) {
        self.logins = logins
        self.now = now
        self.fetch = fetch
    }

    private func fetchToken(_ token: String, identity: GeminiLogin.Identity,
                            isAntigravity: Bool) async throws -> (GeminiUsage, Data) {
        if let task = pending[token] { return try await task.value }
        let cachedProject = projectIDs[identity]
        let task = Task {
            do {
                let (usage, data, resolvedProject) = try await fetch(token, cachedProject, isAntigravity)
                if let resolvedProject, !resolvedProject.isEmpty {
                    projectIDs[identity] = resolvedProject
                }
                return (usage, data)
            } catch {
                switch error {
                case UsageFetchError.http(429), UsageFetchError.rateLimited:
                    let fallback = now().addingTimeInterval(120)
                    if case UsageFetchError.rateLimited(let deadline) = error {
                        retryAfter[identity] = max(fallback, deadline)
                    } else {
                        retryAfter[identity] = fallback
                    }
                default:
                    break
                }
                throw error
            }
        }
        pending[token] = task
        defer { pending[token] = nil }
        return try await task.value
    }

    func read(for source: GeminiLoginStorage.Source) async -> Result<(GeminiUsage, Data), Failure> {
        guard !Task.isCancelled else { return .failure(.cancelled) }
        guard let identity = logins.identity(for: source) else { return .failure(.login(.notSaved)) }
        let isAntigravity = logins.isAntigravity(for: source)
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
                let usage = try await fetchToken(token, identity: identity, isAntigravity: isAntigravity)
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
                default:
                    return .failure(.unavailable)
                }
            }
        }
        return .failure(.unavailable)
    }
}

@MainActor
final class GeminiUsageModel: ObservableObject {
    @Published private(set) var usage: GeminiUsage?
    @Published private(set) var authFailed = false
    @Published private(set) var isStale = false
    private let defaults: UserDefaults
    private let client: GeminiUsageClient
    private let currentAccount: () -> String?
    private let isEnabled: () -> Bool
    private let now: () -> Date
    private var generation = 0
    private var observedAccount: String?
    private(set) var loadedAccount: String?
    private var timer: Timer?
    private var lastSuccess = Date.distantPast

    init(client: GeminiUsageClient,
         defaults: UserDefaults = .standard,
         currentAccount: @escaping () -> String? = GeminiConfig.currentEmail,
         isEnabled: @escaping () -> Bool = { CodingAgent.gemini.isEnabled },
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
        defaults.removeObject(forKey: PrefKey.geminiUsageCache)
        defaults.removeObject(forKey: PrefKey.geminiUsageCacheAccount)
    }

    func startPolling() {
        if let account = currentAccount(), defaults.string(forKey: PrefKey.geminiUsageCacheAccount) == account,
           let data = defaults.data(forKey: PrefKey.geminiUsageCache),
           let cached = try? GeminiUsageParser.parse(data) {
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
            defaults.set(data, forKey: PrefKey.geminiUsageCache)
            defaults.set(account, forKey: PrefKey.geminiUsageCacheAccount)
            authFailed = false
            isStale = false
            return .fetched
        case .failure(let error):
            if error == .retryLater || error == .cancelled { return .skipped }
            authFailed = error.needsLogin
            if authFailed {
                usage = nil
                loadedAccount = nil
                defaults.removeObject(forKey: PrefKey.geminiUsageCache)
                defaults.removeObject(forKey: PrefKey.geminiUsageCacheAccount)
            }
            isStale = usage != nil
            return .failed
        }
    }
}
