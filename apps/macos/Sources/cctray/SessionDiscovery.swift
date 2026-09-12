import Foundation

final class SessionDiscovery {
    private struct Snapshot {
        var rows: [ProcRow]
        var cwds: [Int32: String]
        var openFiles: [Int32: [String]]

        static func capture() -> Snapshot {
            let rows = Proc.all()
            let cwds = Sessions.cwds(for: Sessions.active(rows))
            let pids = rows.filter { $0.agent == .codex }.map { String($0.pid) }.joined(separator: ",")
            var files: [Int32: [String]] = [:]
            if !pids.isEmpty {
                let output = Shell.capture("/usr/sbin/lsof", ["-p", pids, "-Fn"])
                var pid: Int32 = 0
                for line in output.split(separator: "\n") {
                    if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
                    if line.hasPrefix("n"), line.contains("/sessions/"), line.hasSuffix(".jsonl") {
                        files[pid, default: []].append(String(line.dropFirst()))
                    }
                }
            }
            return Snapshot(rows: rows, cwds: cwds, openFiles: files)
        }
    }

    private let activity = CodexActivity()

    func scan() -> (sessions: [AgentSession], orphans: [Int32]) {
        let found = Snapshot.capture()
        var sessions = Sessions.active(found.rows).filter { $0.agent.isEnabled }
        var used = Set<String>()
        for i in sessions.indices {
            sessions[i].cwd = found.cwds[sessions[i].pid] ?? ""
            if sessions[i].agent == .claude {
                sessions[i].title = title(forCwd: sessions[i].cwd, used: &used)
            } else if let path = codexTranscriptPath(pid: sessions[i].pid, cwd: sessions[i].cwd,
                elapsed: sessions[i].elapsed, rows: found.rows, openFiles: found.openFiles, used: &used) {
                sessions[i].codexWorking = activity.working(at: path)
                if let file = FileHandle(forReadingAtPath: path) {
                    defer { try? file.close() }
                    if let data = try? file.read(upToCount: 1_048_576) {
                        sessions[i].title = Self.codexTitleFromTranscript(String(decoding: data, as: UTF8.self))
                    }
                }
            }
        }
        return (sessions, CodingAgent.claude.isEnabled ? Sessions.orphans(found.rows) : [])
    }

    private func codexTranscriptPath(pid: Int32, cwd: String, elapsed: TimeInterval,
                                    rows: [ProcRow], openFiles: [Int32: [String]], used: inout Set<String>) -> String? {
        let parents = Proc.parents(rows)
        let related = rows.filter {
            $0.pid == pid || ($0.agent == .codex && Proc.ancestor(of: $0.pid, parents: parents, match: { $0 == pid }) != nil)
        }.map(\.pid)
        let openPath = related.flatMap { openFiles[$0] ?? [] }.first {
            !used.contains($0) && Self.codexMetadata(at: $0)?["source"] as? String == "cli"
        }
        let path = openPath ?? codexTranscript(cwd: cwd, elapsed: elapsed, used: used)
        guard let path else { return nil }
        used.insert(path)
        return path
    }

    private func codexTranscript(cwd: String, elapsed: TimeInterval, used: Set<String>) -> String? {
        guard !cwd.isEmpty else { return nil }
        let roots = Set([CodexHook.home] + CodexAccounts.savedProfiles.map(\.home))
        let earliest = Date().addingTimeInterval(-elapsed - 5)
        var candidates: [(String, Date)] = []
        for root in roots {
            let dir = URL(fileURLWithPath: root + "/sessions")
            guard let files = FileManager.default.enumerator(at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files where url.pathExtension == "jsonl" && !used.contains(url.path) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified >= earliest { candidates.append((url.path, modified)) }
            }
        }
        for (path, _) in candidates.sorted(by: { $0.1 > $1.1 }).prefix(100) {
            guard let payload = Self.codexMetadata(at: path),
                  payload["source"] as? String == "cli",
                  payload["cwd"] as? String == cwd else { continue }
            return path
        }
        return nil
    }

    static func codexMetadata(at path: String) -> [String: Any]? {
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        var data = Data()
        while data.count < 4_194_304 {
            guard let part = try? file.read(upToCount: 16_384), !part.isEmpty else { return nil }
            data.append(part)
            if let end = data.firstIndex(of: 10) {
                guard let object = try? JSONSerialization.jsonObject(with: data[..<end]) as? [String: Any],
                      object["type"] as? String == "session_meta" else { return nil }
                return object["payload"] as? [String: Any]
            }
        }
        return nil
    }

    static func codexTitleFromTranscript(_ text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message",
                  let title = cleaned(payload["message"] as? String) else { continue }
            return title
        }
        return nil
    }

    private func title(forCwd cwd: String, used: inout Set<String>) -> String? {
        let dir = ClaudePaths.projectDir(for: cwd)
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return nil }
        let jsonls = files.filter { $0.hasSuffix(".jsonl") }
            .map { (path: dir + "/" + $0, at: Self.mtime(dir + "/" + $0)) }
            .sorted { $0.at > $1.at }
            .map(\.path)
        guard let file = jsonls.first(where: { !used.contains($0) }) else { return nil }
        used.insert(file)
        guard let fh = FileHandle(forReadingAtPath: file),
              let data = try? fh.read(upToCount: 1_048_576) else { return nil }
        try? fh.close()
        return Self.titleFromTranscript(String(decoding: data, as: UTF8.self))
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
