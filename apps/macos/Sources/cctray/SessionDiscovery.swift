import CryptoKit
import Foundation

final class SessionDiscovery {
    private struct Snapshot {
        var rows: [ProcRow]
        var cwds: [Int32: String]
        var openFiles: [Int32: [String]]

        static func capture() -> Snapshot {
            let rows = Proc.all()
            let pids = Set(rows.filter { $0.agent == .codex }.map(\.pid) + Sessions.active(rows).map(\.pid))
            let open = Sessions.openFiles(pids: pids.sorted())
            return Snapshot(rows: rows, cwds: open.cwds, openFiles: open.transcripts)
        }
    }

    private let activity = CodexActivity()
    let claude = ClaudeActivity()
    let gemini = GeminiActivity()

    func scan() -> (sessions: [AgentSession], orphans: [Int32]) {
        let found = Snapshot.capture()
        var sessions = Sessions.active(found.rows).filter { $0.agent.isEnabled }
        let activePids = Set(sessions.map(\.pid))
        let activeTTYs = Set(sessions.map(\.tty))
        claude.prune(keeping: activePids)
        gemini.prune(keepingPids: activePids, ttys: activeTTYs)
        var used = Set<String>()
        for i in sessions.indices {
            sessions[i].cwd = found.cwds[sessions[i].pid] ?? ""
            switch sessions[i].agent {
            case .claude:
                if let state = claude.state(pid: sessions[i].pid) {
                    sessions[i].title = Self.head(state.transcript).flatMap(Self.titleFromTranscript)
                    sessions[i].isWorking = state.working
                }
            case .codex:
                if let path = codexTranscriptPath(pid: sessions[i].pid, cwd: sessions[i].cwd,
                    elapsed: sessions[i].elapsed, rows: found.rows, openFiles: found.openFiles, used: &used) {
                    sessions[i].isWorking = activity.working(at: path) ?? false
                    sessions[i].title = Self.head(path).flatMap(Self.codexTitleFromTranscript)
                }
            case .gemini:
                let hookState = gemini.state(pid: sessions[i].pid, tty: sessions[i].tty)
                let transcriptPath: String? = if let t = hookState?.transcript, !t.isEmpty {
                    t
                } else {
                    geminiTranscriptPath(pid: sessions[i].pid, cwd: sessions[i].cwd,
                                         elapsed: sessions[i].elapsed, openFiles: found.openFiles, used: &used)
                }
                if let transcriptPath {
                    used.insert(transcriptPath)
                    sessions[i].title = Self.head(transcriptPath).flatMap(GeminiActivity.titleFromTranscript)
                }
                if let hookState {
                    sessions[i].isWorking = hookState.working
                } else if let transcriptPath {
                    sessions[i].isWorking = GeminiActivity.working(at: transcriptPath) ?? false
                }
            }
        }
        return (sessions, CodingAgent.claude.isEnabled ? Sessions.orphans(found.rows) : [])
    }

    private func geminiTranscriptPath(pid: Int32, cwd: String, elapsed: TimeInterval,
                                      openFiles: [Int32: [String]], used: inout Set<String>) -> String? {
        for file in openFiles[pid] ?? [] {
            if file.contains("/presence/"), file.hasSuffix(".lock") {
                let id = ((file as NSString).lastPathComponent as NSString).deletingPathExtension
                let path = GeminiConfig.agyBrainDir + "/" + id + "/.system_generated/logs/transcript.jsonl"
                if !used.contains(path), FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
            if file.contains("/chats/"), !used.contains(file) {
                return file
            }
        }
        return Self.geminiTranscript(cwd: cwd, elapsed: elapsed, used: used)
    }

    static func geminiProjectSlugs(for cwd: String, geminiDir: String = GeminiConfig.dir) -> [String] {
        guard !cwd.isEmpty else { return [] }
        var slugs: [String] = []
        let projectsPath = geminiDir + "/projects.json"
        if let data = FileManager.default.contents(atPath: projectsPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let projects = obj["projects"] as? [String: String], let slug = projects[cwd], !slug.isEmpty {
                slugs.append(slug)
            } else if let slug = obj[cwd] as? String, !slug.isEmpty {
                slugs.append(slug)
            }
        }
        let hash = SHA256.hash(data: Data(cwd.utf8)).map { String(format: "%02x", $0) }.joined()
        if !slugs.contains(hash) { slugs.append(hash) }
        return slugs
    }

    static func geminiTranscript(cwd: String, elapsed: TimeInterval, used: Set<String>,
                                 geminiDir: String = GeminiConfig.dir) -> String? {
        guard !cwd.isEmpty else { return nil }
        let earliest = Date().addingTimeInterval(-elapsed - 5)
        var candidates: [(String, Date)] = []
        for slug in geminiProjectSlugs(for: cwd, geminiDir: geminiDir) {
            let chatsDir = URL(fileURLWithPath: geminiDir + "/tmp/" + slug + "/chats")
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: chatsDir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { continue }
            for url in files {
                let name = url.lastPathComponent
                let ext = url.pathExtension
                guard name.hasPrefix("session-"), (ext == "jsonl" || ext == "json"), !used.contains(url.path) else {
                    continue
                }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified >= earliest { candidates.append((url.path, modified)) }
            }
        }
        return candidates.max(by: { $0.1 < $1.1 })?.0
    }

    private func codexTranscriptPath(pid: Int32, cwd: String, elapsed: TimeInterval,
                                    rows: [ProcRow], openFiles: [Int32: [String]], used: inout Set<String>) -> String? {
        let parents = Proc.parents(rows)
        let related = rows.filter {
            $0.pid == pid || ($0.agent == .codex && Proc.ancestor(of: $0.pid, parents: parents, match: { $0 == pid }) != nil)
        }.map(\.pid)
        let openPath = related.flatMap { openFiles[$0] ?? [] }.first {
            !used.contains($0) && Self.codexMetadata(at: $0).map(Self.isCodexCLI) == true
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
                  Self.isCodexCLI(payload),
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

    /* Codex 0.159+ TUI sessions run through the app server and record source "vscode". */
    static func isCodexCLI(_ payload: [String: Any]) -> Bool {
        let source = payload["source"] as? String
        return source == "cli" || (source == "vscode" && payload["originator"] as? String == "codex-tui")
    }

    private static func head(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        return (try? fh.read(upToCount: 1_048_576)).map { String(decoding: $0, as: UTF8.self) }
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
}
