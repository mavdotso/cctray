import Foundation

struct ClaudeSession: Identifiable {
    let pid: Int32
    let tty: String
    let cpu: Double
    let elapsed: TimeInterval
    var cwd = ""
    var title: String?
    var id: Int32 { pid }
    var isWorking: Bool { cpu >= 5 }
}

enum Sessions {
    static func active(_ rows: [ProcRow]) -> [ClaudeSession] {
        rows.filter { $0.isClaude && $0.tty != "??" && $0.ppid != 1 }
            .map { ClaudeSession(pid: $0.pid, tty: $0.tty, cpu: $0.cpu,
                                 elapsed: $0.elapsed) }
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

    static func cwds(for sessions: [ClaudeSession]) -> [Int32: String] {
        guard !sessions.isEmpty else { return [:] }
        let pids = sessions.map { String($0.pid) }.joined(separator: ",")
        return parseCwds(lsofOutput: Shell.capture("/usr/sbin/lsof",
                                                   ["-a", "-p", pids, "-d", "cwd", "-Fn"]))
    }
}

enum SessionTitles {
    static func title(forCwd cwd: String, used: inout Set<String>) -> String? {
        let dir = ClaudePaths.projectDir(for: cwd)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let jsonls = files.filter { $0.hasSuffix(".jsonl") }
            .map { (path: dir + "/" + $0, at: mtime(dir + "/" + $0)) }
            .sorted { $0.at > $1.at }
            .map(\.path)
        guard let file = jsonls.first(where: { !used.contains($0) }) else { return nil }
        used.insert(file)
        guard let fh = FileHandle(forReadingAtPath: file),
              let data = try? fh.read(upToCount: 1_048_576) else { return nil }
        try? fh.close()
        return titleFromTranscript(String(decoding: data, as: UTF8.self))
    }

    static func titleFromTranscript(_ head: String) -> String? {
        for line in head.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { continue }
            if obj["type"] as? String == "summary",
               let s = obj["summary"] as? String, !s.isEmpty { return String(s.prefix(60)) }
            if obj["type"] as? String == "user",
               let msg = obj["message"] as? [String: Any] {
                var text: String?
                if let s = msg["content"] as? String { text = s }
                if let parts = msg["content"] as? [[String: Any]] {
                    text = parts.first { $0["type"] as? String == "text" }?["text"] as? String
                }
                if let t = cleaned(text) { return t }
            }
        }
        return nil
    }

    private static func cleaned(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("Caveat:"),
              !t.hasPrefix("Base directory for this skill:")
        else { return nil }
        return String(t.replacingOccurrences(of: "\n", with: " ").prefix(60))
    }

    private static func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            ?? .distantPast
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
    @Published var sessions: [ClaudeSession] = []
    @Published var orphanPids: [Int32] = []
    private var timer: Timer?
    private var lastActive = 0
    private var autoEngaged = false
    private var scanning = false

    private nonisolated static func scan() -> (sessions: [ClaudeSession], orphans: [Int32]) {
        let rows = Proc.all()
        var list = Sessions.active(rows)
        let cwds = Sessions.cwds(for: list)
        var used = Set<String>()
        for i in list.indices {
            list[i].cwd = cwds[list[i].pid] ?? ""
            list[i].title = SessionTitles.title(forCwd: list[i].cwd, used: &used)
        }
        return (list, Sessions.orphans(rows))
    }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        let found = await Task.detached { SessionModel.scan() }.value
        scanning = false
        sessions = found.sessions
        orphanPids = found.orphans
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
                    ? await Task.detached { Sessions.active(Proc.all()).count }.value
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
