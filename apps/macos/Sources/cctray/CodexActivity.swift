import Foundation

final class CodexActivity {
    private struct Entry {
        let inode: UInt64
        var offset: UInt64
        var partial: Data
        var working: Bool?
    }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()

    func working(at path: String) -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        guard let file = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = attributes[.systemFileNumber] as? UInt64 else { return nil }
        if var entry = entries[path], entry.inode == inode, size >= entry.offset {
            if size > entry.offset {
                try? file.seek(toOffset: entry.offset)
                guard let new = try? file.read(upToCount: Int(size - entry.offset)) else { return entry.working }
                entry.offset += UInt64(new.count)
                entry.partial.append(new)
                let lines = entry.partial.split(separator: 10, omittingEmptySubsequences: false)
                for line in lines.dropLast() {
                    if let state = Self.state(in: Data(line)) { entry.working = state }
                }
                entry.partial = lines.last.map { Data($0) } ?? Data()
                entries[path] = entry
            }
            return entry.working
        }
        var offset = size
        var prefix = Data()
        var partial = Data()
        var working: Bool?
        while offset > 0 {
            let start = offset > 262_144 ? offset - 262_144 : 0
            try? file.seek(toOffset: start)
            guard var data = try? file.read(upToCount: Int(offset - start)) else { break }
            data.append(prefix)
            var lines = data.split(separator: UInt8(10), omittingEmptySubsequences: false).map { Data($0) }
            if offset == size { partial = lines.removeLast() }
            prefix = start > 0 && !lines.isEmpty ? lines.removeFirst() : Data()
            working = lines.reversed().compactMap(Self.state).first
            if working != nil { break }
            offset = start
        }
        if entries.count > 200 { entries.removeAll() }
        entries[path] = Entry(inode: inode, offset: size, partial: partial, working: working)
        return working
    }

    private static func state(in line: Data) -> Bool? {
        let text = String(decoding: line, as: UTF8.self)
        guard ["task_started", "task_complete", "turn_aborted"].contains(where: text.contains),
              let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any] else { return nil }
        switch payload["type"] as? String {
        case "task_started": return true
        case "task_complete", "turn_aborted": return false
        default: return nil
        }
    }
}
