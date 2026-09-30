import Foundation

final class ClaudeActivity {
    private struct Entry {
        var working: Bool
        let transcript: String
        var checked: Date
    }
    private var entries: [Int32: Entry] = [:]
    private let lock = NSLock()
    func record(line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["provider"] == nil,
              let pid = (obj["pid"] as? NSNumber)?.int32Value,
              let raw = obj["raw"] as? [String: Any],
              let transcript = raw["transcript_path"] as? String else { return false }
        let working: Bool
        switch raw["hook_event_name"] as? String {
        case "UserPromptSubmit": working = true
        case "Stop": working = false
        default: return false
        }
        lock.withLock {
            entries[pid] = Entry(working: working, transcript: transcript, checked: Date())
        }
        return true
    }

    /* Esc ends a turn without Stop, so an open turn rechecks the transcript. */
    func state(pid: Int32) -> (working: Bool, transcript: String)? {
        lock.withLock {
            guard var entry = entries[pid] else { return nil }
            if entry.working, Date().timeIntervalSince(entry.checked) >= 5 {
                entry.working = Self.working(tail: Self.tail(entry.transcript))
                entry.checked = Date()
            }
            entries[pid] = entry
            return (entry.working, entry.transcript)
        }
    }

    func prune(keeping pids: Set<Int32>) {
        lock.withLock { entries = entries.filter { pids.contains($0.key) } }
    }

    private static func tail(_ path: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        return (try? fh.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /* A turn is open until an end-of-turn entry or an interrupt follows it. */
    static func working(tail: String) -> Bool {
        for line in tail.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["isSidechain"] as? Bool != true else { continue }
            switch obj["type"] as? String {
            case "system" where ["turn_duration", "stop_hook_summary", "local_command"].contains(obj["subtype"] as? String):
                return false
            case "user":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]]
                let text = content?.first?["text"] as? String ?? ""
                return !text.hasPrefix("[Request interrupted")
            case "assistant":
                let reason = (obj["message"] as? [String: Any])?["stop_reason"] as? String
                return reason == nil || reason == "tool_use"
            default:
                continue
            }
        }
        return false
    }
}
