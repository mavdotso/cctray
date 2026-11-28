import Foundation

enum RetryAfter {
    static func date(_ value: String?, now: Date = Date()) -> Date? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite, seconds >= 0 { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

enum Shell {
    static func start(_ path: String, _ args: [String], input: Pipe, output: Pipe) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    static func run(_ path: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        guard (try? p.run()) != nil else { return (-1, "", "cannot run \(path)") }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus,
                String(decoding: out, as: UTF8.self),
                String(decoding: err, as: UTF8.self))
    }

    static func capture(_ path: String, _ args: [String]) -> String {
        run(path, args).out
    }

    static func fire(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        try? p.run()
    }
}

struct ProcRow: Equatable {
    let pid: Int32
    let ppid: Int32
    let tty: String
    let elapsed: TimeInterval
    let comm: String
    var arguments = ""
    var isClaude: Bool { comm == "claude" || comm.hasSuffix("/claude") }
    var isAgy: Bool { comm == "agy" || comm.hasSuffix("/agy") }
    var isGemini: Bool {
        if isAgy || comm == "gemini" || comm.hasSuffix("/gemini") { return true }
        guard comm == "node" || comm.hasSuffix("/node") else { return false }
        return geminiArgTokens() != nil
    }
    var agent: CodingAgent? {
        if isClaude { return .claude }
        if comm == "codex" || comm.hasSuffix("/codex") { return .codex }
        if isGemini { return .gemini }
        return nil
    }

    /* Returns the CLI tokens after the gemini binary/script if this process runs Gemini CLI. */
    private func geminiArgTokens() -> [String]? {
        var tokens = arguments.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return nil }
        let firstName = (tokens[0] as NSString).lastPathComponent
        if firstName == "gemini" {
            tokens.removeFirst()
            return tokens
        }
        guard firstName == "node" || comm == "node" || comm.hasSuffix("/node") else { return nil }
        tokens.removeFirst()
        let nodeValueOptions: Set<String> = ["-r", "--require", "-e", "--eval", "-p", "--print",
            "-C", "--conditions", "--import", "--loader", "--env-file", "--max-old-space-size"]
        while let token = tokens.first {
            tokens.removeFirst()
            if nodeValueOptions.contains(token) {
                if !tokens.isEmpty { tokens.removeFirst() }
                continue
            }
            if token.hasPrefix("-") { continue }
            let name = (token as NSString).lastPathComponent
            if name == "gemini" || token.contains("/gemini-cli/") {
                return tokens
            }
            return nil
        }
        return nil
    }

    var isInteractive: Bool {
        switch agent {
        case .claude:
            return true
        case .codex:
            let rest = arguments.hasPrefix(comm) ? String(arguments.dropFirst(comm.count)) : arguments
            var tokens = rest.split(separator: " ").map(String.init)
            if let first = tokens.first, (first as NSString).lastPathComponent == "codex" { tokens.removeFirst() }
            let valueOptions: Set<String> = ["-c", "--config", "--enable", "--disable", "-C", "--cd",
                "-m", "--model", "-p", "--profile", "-s", "--sandbox", "-a", "--ask-for-approval",
                "--add-dir", "--image", "-i", "--local-provider"]
            while let first = tokens.first {
                tokens.removeFirst()
                if valueOptions.contains(first) {
                    if !tokens.isEmpty { tokens.removeFirst() }
                    continue
                }
                if first == "--version" || first == "-V" || first == "--help" || first == "-h" { return false }
                if first.hasPrefix("-") { continue }
                return !["app-server", "exec", "e", "review", "login", "logout", "mcp", "mcp-server",
                         "completion", "debug", "sandbox", "apply", "cloud", "features", "help"].contains(first)
            }
            return true
        case .gemini:
            if isAgy {
                let rest = arguments.hasPrefix(comm) ? String(arguments.dropFirst(comm.count)) : arguments
                var tokens = rest.split(separator: " ").map(String.init)
                if let first = tokens.first, (first as NSString).lastPathComponent == "agy" { tokens.removeFirst() }
                let nonInteractiveFlags: Set<String> = ["-p", "--print", "--prompt", "--version", "-v", "--help", "-h"]
                let valueOptions: Set<String> = ["--add-dir", "--agent", "--conversation", "-r", "--resume",
                    "--effort", "-i", "--prompt-interactive", "--input-format", "--json-schema", "--log-file",
                    "--mode", "--model", "--output-format", "--print-timeout", "--project", "--settings"]
                while let first = tokens.first {
                    tokens.removeFirst()
                    if nonInteractiveFlags.contains(first) || first.hasPrefix("--print=")
                        || first.hasPrefix("--prompt=") || first.hasPrefix("-p=") {
                        return false
                    }
                    if valueOptions.contains(first) {
                        if !tokens.isEmpty { tokens.removeFirst() }
                        continue
                    }
                    if first.hasPrefix("-") { continue }
                    return !["acp", "agent", "agents", "changelog", "help", "install", "mcp",
                             "mic-serve", "models", "plugin", "plugins", "remote-control", "update"].contains(first)
                }
                return true
            }
            var tokens: [String]
            if let parsed = geminiArgTokens() {
                tokens = parsed
            } else {
                let rest = arguments.hasPrefix(comm) ? String(arguments.dropFirst(comm.count)) : arguments
                tokens = rest.split(separator: " ").map(String.init)
                if let first = tokens.first, (first as NSString).lastPathComponent == "gemini" { tokens.removeFirst() }
            }
            let nonInteractiveFlags: Set<String> = ["-p", "--prompt", "--version", "-v", "--help", "-h",
                "--list-sessions", "--list-extensions", "--delete-session"]
            let valueOptions: Set<String> = ["-m", "--model", "-r", "--resume", "-o", "--output-format",
                "--approval-mode", "--include-directories", "--allowed-mcp-server-names",
                "-e", "--extensions", "--policy", "-i", "--prompt-interactive"]
            while let first = tokens.first {
                tokens.removeFirst()
                if nonInteractiveFlags.contains(first) || first.hasPrefix("--prompt=") || first.hasPrefix("-p=") {
                    return false
                }
                if valueOptions.contains(first) {
                    if !tokens.isEmpty { tokens.removeFirst() }
                    continue
                }
                if first.hasPrefix("-") { continue }
                return !["mcp", "extensions", "hooks", "skills", "policies"].contains(first)
            }
            return true
        case nil:
            return false
        }
    }
}

enum Proc {
    static func parse(psOutput: String) -> [ProcRow] {
        psOutput.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 5, let pid = Int32(p[0]), let ppid = Int32(p[1]) else { return nil }
            return ProcRow(pid: pid, ppid: ppid, tty: String(p[2]),
                           elapsed: parseElapsed(String(p[3])),
                           comm: p[4...].joined(separator: " "))
        }
    }

    static func parseElapsed(_ s: String) -> TimeInterval {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let parts = rest.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return 0 }
        return days * 86400 + parts.reduce(0) { $0 * 60 + $1 }
    }

    static func all() -> [ProcRow] {
        var rows = parse(psOutput: Shell.capture(
            "/bin/ps", ["-axo", "pid=,ppid=,tty=,etime=,comm="]))
        let commands = Shell.capture("/bin/ps", ["-axo", "pid=,args="])
        var arguments: [Int32: String] = [:]
        for line in commands.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            if parts.count == 2, let pid = Int32(parts[0]) { arguments[pid] = String(parts[1]) }
        }
        for index in rows.indices { rows[index].arguments = arguments[rows[index].pid] ?? "" }
        return rows
    }

    static func parents(_ rows: [ProcRow]) -> [Int32: Int32] {
        Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
    }

    static func ancestor(of pid: Int32, parents: [Int32: Int32],
                         match: (Int32) -> Bool) -> Int32? {
        var current = pid
        var hops = 0
        while current > 1, hops < 25 {
            if match(current) { return current }
            current = parents[current] ?? 1
            hops += 1
        }
        return nil
    }
}

extension Int {
    var kbSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(self) * 1024, countStyle: .file)
    }
}

enum PrefKey {
    static let terminalApp = "terminal.app"
    static let sessionDir = "session.dir"
    static let prewarmOn = "prewarm.on"
    static let prewarmStartMin = "prewarm.startMin"
    static let prewarmEndMin = "prewarm.endMin"
    static let chimeOn = "chime.on"
    static let chimeSound = "chime.sound"
    static let chimeSilent = "chime.silent"
    static let showSessions = "sessions.show"
    static let showAccounts = "accounts.show"
    static let autoAwake = "sessions.autoAwake"
    static let accountProfiles = "accounts.profiles"
    static let accountActive = "accounts.active"
    static let claudeDeletedLogin = "accounts.deletedLogin"
    static let usageCache = "usage.cache"
    static let usageCacheAccount = "usage.cacheAccount"
    static let codexProfiles = "codex.profiles"
    static let codexSelectedProfile = "codex.selectedProfile"
    static let codexDefaultProfileDeleted = "codex.defaultProfileDeleted"
    static let geminiProfiles = "gemini.profiles"
    static let geminiActive = "gemini.active"
    static let geminiDeletedLogin = "gemini.deletedLogin"
    static let geminiUsageCache = "gemini.usageCache"
    static let geminiUsageCacheAccount = "gemini.usageCacheAccount"
    static let staleDays = "worktrees.staleDays"
    static let autoClean = "worktrees.autoClean"
    static let didRequestPermissions = "didRequestPermissions"
}
