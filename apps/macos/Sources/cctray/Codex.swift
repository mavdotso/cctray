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
        let primary: Window?
        let secondary: Window?
    }
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?

    var sessionWindow: Window? {
        mainWindows.first { $0.windowDurationMins != 10080 }
    }

    var weeklyWindow: Window? {
        mainWindows.first { $0.windowDurationMins == 10080 }
    }

    var mainWindows: [Window] {
        let main = rateLimitsByLimitId?["codex"] ?? rateLimits
        return [main?.primary, main?.secondary].compactMap { $0 }
    }
}

enum CodexRPC {
    enum Failure: LocalizedError {
        case unavailable, timedOut, signingOut, rejected(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "Codex unavailable. Install Codex CLI and sign in."
            case .timedOut: "Codex did not respond. Try again."
            case .signingOut: "Removing the Codex login. Try again when it finishes."
            case .rejected(let message): message
            }
        }
    }

    static func read(profile: CodexProfile?) throws -> (String, CodexLimits) {
        try read(command: CodexAccounts.command("app-server", profile: profile))
    }

    static func read(command: String) throws -> (String, CodexLimits) {
        let input = Pipe(), output = Pipe()
        let process = try Shell.start("/bin/zsh", ["-ilc", "exec " + command],
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
        let accountData = try request("account/read", id: 1, params: ["refreshToken": true])
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
final class CodexLoginManager {
    typealias Reading = Result<(String, CodexLimits), Error>
    static let shared = CodexLoginManager()

    private let readLogin: (CodexProfile?) async -> Reading
    private let removeLogin: (CodexProfile) async -> Result<Void, Error>
    private var reads: [String: Task<Reading, Never>] = [:]
    private var removals: [String: Task<Result<Void, Error>, Never>] = [:]

    init(read: @escaping (CodexProfile?) async -> Reading = { profile in
        await Task.detached { Result { try CodexRPC.read(profile: profile) } }.value
    }, logout: @escaping (CodexProfile) async -> Result<Void, Error> = { profile in
        await Task.detached {
            Result {
                guard Shell.run("/bin/zsh", ["-ilc", CodexAccounts.command("logout", profile: profile)]).status == 0 else {
                    throw CodexRPC.Failure.rejected("Delete failed: cannot remove the Codex login")
                }
            }
        }.value
    }) {
        readLogin = read
        removeLogin = logout
    }

    /* Finish credential rotation even when a menu task is cancelled. Logout
       waits for that work before removing the login. */
    func read(profile: CodexProfile?) async -> Reading {
        let home = profile?.home ?? CodexHook.home
        guard removals[home] == nil else { return .failure(CodexRPC.Failure.signingOut) }
        if let task = reads[home] { return await task.value }
        let task = Task {
            let result = await readLogin(profile)
            reads[home] = nil
            return result
        }
        reads[home] = task
        return await task.value
    }

    func logout(profile: CodexProfile) async -> Result<Void, Error> {
        let home = profile.home
        if let task = removals[home] { return await task.value }
        let task = Task {
            _ = await reads[home]?.value
            let result = await removeLogin(profile)
            removals[home] = nil
            return result
        }
        removals[home] = task
        return await task.value
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
    private let logins: CodexLoginManager
    private let currentProfile: () -> CodexProfile?

    init(logins: CodexLoginManager? = nil,
         currentProfile: @escaping () -> CodexProfile? = { CodexAccounts.current }) {
        self.logins = logins ?? .shared
        self.currentProfile = currentProfile
    }

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
        let profile = currentProfile()
        let requestGeneration = generation
        let result = await logins.read(profile: profile)
        refreshing = false
        guard requestGeneration == generation, profile == currentProfile() else {
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
