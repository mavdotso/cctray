import Foundation

final class GeminiActivity {
    private struct Entry {
        var working: Bool
        var transcript: String
        var checked: Date
    }

    private var entriesByPid: [Int32: Entry] = [:]
    private var entriesByTTY: [String: Entry] = [:]
    private let lock = NSLock()

    func record(line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provider = obj["provider"] as? String,
              provider == "gemini" || provider == "agy",
              let raw = obj["raw"] as? [String: Any] else { return false }
        let working: Bool
        let transcript: String
        if provider == "agy" {
            switch raw["hookEventName"] as? String {
            case "PreInvocation": working = true
            case "Stop": working = false
            default: return false
            }
            transcript = raw["transcriptPath"] as? String ?? ""
        } else {
            switch raw["hook_event_name"] as? String {
            case "BeforeAgent": working = true
            case "AfterAgent": working = false
            default: return false
            }
            transcript = raw["transcript_path"] as? String ?? ""
        }
        let pid = (obj["pid"] as? NSNumber)?.int32Value
        let tty = obj["tty"] as? String
        guard pid != nil || (tty != nil && tty != "??" && !tty!.isEmpty) else { return false }
        lock.withLock {
            let entry = Entry(working: working, transcript: transcript, checked: Date())
            if let pid { entriesByPid[pid] = entry }
            if let tty, !tty.isEmpty, tty != "??" { entriesByTTY[tty] = entry }
        }
        return true
    }

    func state(pid: Int32, tty: String) -> (working: Bool, transcript: String)? {
        lock.withLock {
            let existing = entriesByPid[pid] ?? entriesByTTY[tty]
            guard var entry = existing else { return nil }
            if entry.working, !entry.transcript.isEmpty, Date().timeIntervalSince(entry.checked) >= 5 {
                if let working = Self.working(at: entry.transcript) {
                    entry.working = working
                }
                entry.checked = Date()
                entriesByPid[pid] = entry
                if !tty.isEmpty, tty != "??" { entriesByTTY[tty] = entry }
            }
            return (entry.working, entry.transcript)
        }
    }

    func prune(keepingPids pids: Set<Int32>, ttys: Set<String>) {
        lock.withLock {
            entriesByPid = entriesByPid.filter { pids.contains($0.key) }
            entriesByTTY = entriesByTTY.filter { ttys.contains($0.key) }
        }
    }

    static func working(at path: String) -> Bool? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }
        return working(text: String(decoding: data, as: UTF8.self))
    }

    static func working(text: String) -> Bool? {
        if let data = text.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messages = root["messages"] as? [[String: Any]] {
            return working(messages: messages)
        }
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let state = working(entry: obj) else { continue }
            return state
        }
        return nil
    }

    private static func working(messages: [[String: Any]]) -> Bool? {
        for msg in messages.reversed() {
            if let state = working(entry: msg) { return state }
        }
        return nil
    }

    private static func working(entry: [String: Any]) -> Bool? {
        switch entry["type"] as? String {
        case "USER_INPUT":
            return true
        case "GENERIC":
            return true
        case "PLANNER_RESPONSE":
            if let status = entry["status"] as? String, status != "DONE" { return true }
            if let calls = entry["tool_calls"] as? [[String: Any]], !calls.isEmpty { return true }
            return false
        case "user":
            return true
        case "gemini", "error", "info":
            return false
        default:
            return nil
        }
    }

    static func titleFromTranscript(_ text: String) -> String? {
        if let data = text.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messages = root["messages"] as? [[String: Any]] {
            for msg in messages where msg["type"] as? String == "user" {
                if let title = cleaned(extractText(from: msg)) { return title }
            }
            return nil
        }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            let type = obj["type"] as? String
            if type == "USER_INPUT" {
                if let content = obj["content"] as? String,
                   let title = cleaned(extractUserRequest(from: content)) {
                    return title
                }
            } else if type == "user" {
                if let title = cleaned(extractText(from: obj)) { return title }
            }
        }
        return nil
    }

    private static func extractUserRequest(from content: String) -> String {
        let openTag = "<USER_REQUEST>"
        let closeTag = "</USER_REQUEST>"
        if let start = content.range(of: openTag),
           let end = content.range(of: closeTag, range: start.upperBound..<content.endIndex) {
            return String(content[start.upperBound..<end.lowerBound])
        }
        return content
    }

    private static func extractText(from entry: [String: Any]) -> String? {
        if let message = entry["message"] as? String { return message }
        if let content = entry["content"] as? String { return content }
        if let parts = entry["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.first(where: { !$0.isEmpty })
        }
        if let parts = entry["message"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.first(where: { !$0.isEmpty })
        }
        return nil
    }

    private static func cleaned(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty, !t.hasPrefix("<"), !t.hasPrefix("/") else { return nil }
        return String(t.replacingOccurrences(of: "\n", with: " ").prefix(60))
    }
}
