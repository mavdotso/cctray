import Foundation

struct CodexLimits: Decodable {
    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: TimeInterval?
        var label: String {
            guard let minutes = windowDurationMins else { return "Usage" }
            if minutes == 10080 { return "Week" }
            return minutes >= 60 && minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes)m"
        }
        var reset: Date? { resetsAt.map(Date.init(timeIntervalSince1970:)) }
    }
    struct Bucket: Decodable {
        let limitName: String?
        let primary: Window?
        let secondary: Window?
    }
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?
    var buckets: [(String, Bucket)] {
        if let all = rateLimitsByLimitId, !all.isEmpty {
            return all.keys.sorted().map { ($0, all[$0]!) }
        }
        return rateLimits.map { [("codex", $0)] } ?? []
    }

    var sessionWindow: Window? {
        mainWindows.first { $0.windowDurationMins != 10080 }
    }

    var weeklyWindow: Window? {
        mainWindows.first { $0.windowDurationMins == 10080 }
    }

    private var mainWindows: [Window] {
        let main = rateLimitsByLimitId?["codex"] ?? rateLimits
        return [main?.primary, main?.secondary].compactMap { $0 }
    }

    var sparkWindows: [Window] {
        guard let bucket = buckets.first(where: {
            ($0.1.limitName ?? $0.0).localizedCaseInsensitiveContains("spark")
        })?.1 else { return [] }
        return [bucket.primary, bucket.secondary].compactMap { $0 }
    }

    var sparkWindow: Window? {
        sparkWindows.max {
            if $0.usedPercent != $1.usedPercent { return $0.usedPercent < $1.usedPercent }
            return ($0.resetsAt ?? .infinity) > ($1.resetsAt ?? .infinity)
        }
    }
}

enum CodexRPC {
    enum Failure: LocalizedError {
        case unavailable, timedOut, rejected(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Codex unavailable. Install Codex CLI and sign in."
            case .timedOut: "Codex did not respond. Try again."
            case .rejected(let message): message
            }
        }
    }

    static func read(profile: CodexProfile? = CodexAccounts.current) throws -> (String, CodexLimits) {
        let input = Pipe(), output = Pipe()
        let process = try Shell.start("/bin/zsh", ["-ilc", "exec " + CodexAccounts.command("app-server", profile: profile)],
                                      input: input, output: output)
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        var pending = Data()
        let deadline = Date().addingTimeInterval(20)
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func request(_ method: String, id: Int, params: [String: Any] = [:]) throws -> Data {
            try send(["id": id, "method": method, "params": params])
            while Date() < deadline {
                if let newline = pending.firstIndex(of: 10) {
                    let line = pending[..<newline]
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          object["id"] as? Int == id else { continue }
                    if object["error"] != nil {
                        throw Failure.rejected("Codex could not read usage. Check your login and retry.")
                    }
                    guard let result = object["result"] else { throw Failure.unavailable }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                        events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 200)
                if ready < 0 { throw Failure.unavailable }
                if ready == 0 { continue }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { throw Failure.unavailable }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count < 4_194_304 else { throw Failure.unavailable }
            }
            throw Failure.timedOut
        }
        _ = try request("initialize", id: 0, params: [
            "clientInfo": ["name": "cctray", "version": "1.0"]
        ])
        try send(["method": "initialized"])
        let accountData = try request("account/read", id: 1)
        let object = try JSONSerialization.jsonObject(with: accountData) as? [String: Any]
        guard let account = object?["account"] as? [String: Any] else {
            throw Failure.rejected("Sign in with codex login")
        }
        guard account["type"] as? String == "chatgpt" else {
            throw Failure.rejected("Usage limits require a ChatGPT login")
        }
        let limits = try JSONDecoder().decode(CodexLimits.self,
                                              from: request("account/rateLimits/read", id: 2))
        return (account["email"] as? String ?? "ChatGPT account", limits)
    }
}

@MainActor
final class CodexModel: ObservableObject {
    @Published private(set) var limits: CodexLimits?
    @Published private(set) var email: String?
    @Published private(set) var error: String?
    private(set) var loadedProfile: String?
    private var generation = 0
    private var refreshing = false
    private var lastRefresh = Date.distantPast
    private var timer: Timer?

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh(force: Bool = false) async {
        guard CodingAgent.codex.isEnabled else { return }
        guard !refreshing, force || Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        refreshing = true
        lastRefresh = Date()
        let profile = CodexAccounts.current
        let requestGeneration = generation
        let result = await Task.detached { Result { try CodexRPC.read(profile: profile) } }.value
        refreshing = false
        guard requestGeneration == generation, profile == CodexAccounts.current else {
            limits = nil
            email = nil
            await refresh(force: true)
            return
        }
        guard CodingAgent.codex.isEnabled else { return }
        switch result {
        case .success(let (identity, usage)):
            loadedProfile = profile?.id ?? "default"
            email = identity
            limits = usage
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }

    func accountChanged() {
        generation += 1
        lastRefresh = .distantPast
        loadedProfile = nil
        limits = nil
        email = nil
        error = nil
    }
}
