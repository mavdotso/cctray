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
        return inner.contains { $0["command"] as? String == quotedHookScriptPath }
    }

    private static func stripOurs(_ hooks: inout [String: Any]) {
        guard let entries = hooks["Stop"] as? [[String: Any]] else { return }
        let kept = entries.filter { !isOurs($0) }
        if kept.isEmpty { hooks.removeValue(forKey: "Stop") } else { hooks["Stop"] = kept }
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
        if enabled {
            try fm.createDirectory(atPath: (claudeSettingsPath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
        }
        if !enabled && !fm.fileExists(atPath: claudeSettingsPath) { return }
        try updated.write(to: URL(fileURLWithPath: claudeSettingsPath), options: .atomic)
    }
}
