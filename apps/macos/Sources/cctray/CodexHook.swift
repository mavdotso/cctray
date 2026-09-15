import Foundation

enum CodexHook {
    enum Failure: LocalizedError {
        case unreadableNotify
        var errorDescription: String? {
            "Codex has a notify command cctray cannot read. Its chime was not installed."
        }
    }
    static var home: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
    }
    static let scriptPath = HookInstaller.appSupportDir + "/codex-attention.sh"
    static let head = "# cctray Codex attention\n"
    static let tail = "# end cctray Codex attention\n"
    static let kept = "# kept: "

    /* Codex allows one notify command: chain the existing one and keep it for removal. */
    static func configure(_ text: String, enabled: Bool) throws -> String {
        var text = text
        let notifyPattern = #"(?m)^\s*["']?notify["']?\s*=.*\n?"#
        let blockPattern = "(?s)" + NSRegularExpression.escapedPattern(for: head) + ".*?"
            + NSRegularExpression.escapedPattern(for: tail)
        if let block = text.range(of: blockPattern, options: .regularExpression) {
            let restored = text[block].split(separator: "\n")
                .first { $0.hasPrefix(kept) }
                .map { $0.dropFirst(kept.count) + "\n" } ?? ""
            var withoutBlock = text
            withoutBlock.removeSubrange(block)
            if withoutBlock.range(of: notifyPattern, options: .regularExpression) != nil {
                text = withoutBlock
            } else {
                text.replaceSubrange(block, with: restored)
            }
        }
        guard enabled else { return text }
        var command = ["/bin/sh", scriptPath]
        var keptLine = ""
        if let existing = text.range(of: notifyPattern, options: .regularExpression) {
            let line = text[existing].trimmingCharacters(in: .newlines)
            let value = line.drop { $0 != "=" }.dropFirst()
            guard let args = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String]
            else { throw Failure.unreadableNotify }
            if args.contains(where: {
                $0.replacingOccurrences(of: #"\/"#, with: "/").contains(scriptPath)
            }) { return text }
            command += args
            keptLine = kept + line + "\n"
            text.removeSubrange(existing)
        }
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: command,
                                                               options: [.withoutEscapingSlashes]), encoding: .utf8)!
        return head + keptLine + "notify = \(encoded)\n" + tail + text
    }

    static func setEnabled(_ enabled: Bool, home: String = home) throws {
        let fm = FileManager.default
        let path = home + "/config.toml"
        guard enabled || fm.fileExists(atPath: path) else { return }
        let current = fm.fileExists(atPath: path) ? try String(contentsOfFile: path, encoding: .utf8) : ""
        let updated = try configure(current, enabled: enabled)
        if enabled {
            try fm.createDirectory(atPath: HookInstaller.appSupportDir, withIntermediateDirectories: true)
            if !fm.fileExists(atPath: HookInstaller.attentionLogPath) {
                fm.createFile(atPath: HookInstaller.attentionLogPath, contents: Data())
            }
            let script = """
            #!/bin/sh
            [ "$#" -gt 0 ] || exit 0
            TTY=$(/bin/ps -o tty= -p "$PPID" | /usr/bin/tr -d ' ')
            eval "PAYLOAD=\\${$#}"
            [ -n "$PAYLOAD" ] || exit 0
            printf '{"provider":"codex","tty":"%s","raw":%s}\\n' "$TTY" "$PAYLOAD" >> \(Shell.quote(HookInstaller.attentionLogPath))
            [ "$#" -gt 1 ] || exit 0
            exec "$@"
            """
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        }
        if current != updated { try updated.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
