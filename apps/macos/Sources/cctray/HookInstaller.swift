import Foundation

enum HookInstaller {
    enum HookError: Error { case malformedSettings }

    private static func settingsObject(_ json: Data) throws -> [String: Any] {
        guard !json.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: json),
              let dict = obj as? [String: Any] else { throw HookError.malformedSettings }
        return dict
    }

    static let appSupportDir = NSHomeDirectory() + "/Library/Application Support/cctray"
    static let hookScriptPath = appSupportDir + "/attention-hook.sh"
    static let attentionLogPath = appSupportDir + "/attention.jsonl"
    static let claudeSettingsPath = NSHomeDirectory() + "/.claude/settings.json"

    private static let supportRoot = NSHomeDirectory() + "/Library/Application Support"
    private static let legacyQuotedHookScriptPath =
        "\"\(supportRoot)/CCTray/attention-hook.sh\""

    static func migrateLegacyDir() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: supportRoot),
              entries.contains("CCTray"), !entries.contains("cctray") else { return }
        try? fm.moveItem(atPath: supportRoot + "/CCTray", toPath: appSupportDir)
    }

    static let hookScript = """
    #!/bin/sh
    IN=$(cat)
    [ -z "$IN" ] && IN='{}'
    TTY=$(ps -o tty= -p $PPID | tr -d ' ')
    printf '{"tty":"%s","raw":%s}\\n' "$TTY" "$IN" >> "\(attentionLogPath)"
    """

    static let quotedHookScriptPath = "\"\(hookScriptPath)\""

    private static var ourEntry: [String: Any] {
        ["hooks": [["type": "command", "command": quotedHookScriptPath]]]
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains {
            let cmd = $0["command"] as? String
            return cmd == quotedHookScriptPath || cmd == legacyQuotedHookScriptPath
        }
    }

    private static let knownEvents = ["Stop", "Notification"]

    private static func stripOurs(_ hooks: inout [String: Any]) {
        for name in knownEvents {
            guard let entries = hooks[name] as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: name) } else { hooks[name] = kept }
        }
    }

    private static func encode(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj,
                                   options: [.prettyPrinted, .sortedKeys])
    }

    static func install(into json: Data) throws -> Data {
        var obj = try settingsObject(json)
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        stripOurs(&hooks)
        hooks["Stop"] = (hooks["Stop"] as? [[String: Any]] ?? []) + [ourEntry]
        obj["hooks"] = hooks
        return try encode(obj)
    }

    static func remove(from json: Data) throws -> Data {
        var obj = try settingsObject(json)
        guard var hooks = obj["hooks"] as? [String: Any] else { return json }
        stripOurs(&hooks)
        obj["hooks"] = hooks
        return try encode(obj)
    }

    static func setEnabled(_ enabled: Bool) throws {
        let fm = FileManager.default
        migrateLegacyDir()
        try fm.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        if enabled {
            try hookScript.write(toFile: hookScriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptPath)
            if !fm.fileExists(atPath: attentionLogPath) {
                fm.createFile(atPath: attentionLogPath, contents: Data())
            }
        }
        let current = fm.contents(atPath: claudeSettingsPath) ?? Data("{}".utf8)
        let updated = enabled ? try install(into: current) : try remove(from: current)
        try updated.write(to: URL(fileURLWithPath: claudeSettingsPath), options: .atomic)
    }
}
