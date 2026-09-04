import Foundation

enum Shell {
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
    let cpu: Double
    let elapsed: TimeInterval
    let comm: String
    var isClaude: Bool { comm == "claude" || comm.hasSuffix("/claude") }
}

enum Proc {
    static func parse(psOutput: String) -> [ProcRow] {
        psOutput.split(separator: "\n").compactMap { line in
            let p = line.split(separator: " ", omittingEmptySubsequences: true)
            guard p.count >= 6, let pid = Int32(p[0]), let ppid = Int32(p[1]),
                  let cpu = Double(p[3]) else { return nil }
            return ProcRow(pid: pid, ppid: ppid, tty: String(p[2]), cpu: cpu,
                           elapsed: parseElapsed(String(p[4])),
                           comm: p[5...].joined(separator: " "))
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
        parse(psOutput: Shell.capture(
            "/bin/ps", ["-axo", "pid=,ppid=,tty=,%cpu=,etime=,comm="]))
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
    static let showSessions = "sessions.show"
    static let showAccounts = "accounts.show"
    static let autoAwake = "sessions.autoAwake"
    static let accountProfiles = "accounts.profiles"
    static let accountActive = "accounts.active"
    static let usageCache = "usage.cache"
    static let staleDays = "worktrees.staleDays"
    static let autoClean = "worktrees.autoClean"
    static let didRequestPermissions = "didRequestPermissions"
}
