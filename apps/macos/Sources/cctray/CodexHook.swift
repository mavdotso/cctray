import Foundation

enum CodexHook {
    enum Failure: LocalizedError {
        case existingNotify
        var errorDescription: String? {
            "Codex already has a notify command. Its chime was not installed."
        }
    }
    static var home: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
    }
    static let scriptPath = HookInstaller.appSupportDir + "/codex-attention.sh"
    static var block: String {
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: ["/bin/sh", scriptPath],
                                                               options: [.withoutEscapingSlashes]), encoding: .utf8)!
        return "# cctray Codex attention\nnotify = \(encoded)\n# end cctray Codex attention\n"
    }

    static func configure(_ text: String, enabled: Bool) throws -> String {
        let stripped = text.replacingOccurrences(of: block, with: "")
        guard enabled else { return stripped }
        let pattern = #"(?m)^\s*["']?notify["']?\s*="#
        guard stripped.range(of: pattern, options: .regularExpression) == nil else {
            throw Failure.existingNotify
        }
        return block + stripped
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
            TTY=$(/bin/ps -o tty= -p "$PPID" | /usr/bin/tr -d ' ')
            [ -n "$1" ] || exit 0
            printf '{"provider":"codex","tty":"%s","raw":%s}\\n' "$TTY" "$1" >> \(Shell.quote(HookInstaller.attentionLogPath))
            """
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.createDirectory(atPath: home, withIntermediateDirectories: true)
        }
        if current != updated { try updated.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
