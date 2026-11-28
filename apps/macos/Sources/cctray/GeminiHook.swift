import Foundation

enum GeminiHook {
    enum HookError: Error { case malformedSettings }

    static let hookScriptPath = HookInstaller.appSupportDir + "/gemini-attention.sh"
    static let agyHookScriptPath = HookInstaller.appSupportDir + "/agy-attention.sh"
    static let quotedHookScriptPath = "\"\(hookScriptPath)\""
    static let quotedAgyHookScriptPath = "\"\(agyHookScriptPath)\""
    static let hookName = "cctray-attention"
    static let events = ["BeforeAgent", "AfterAgent"]

    static let hookScript = """
    #!/bin/sh
    IN=$(cat)
    [ -z "$IN" ] && IN='{}'
    P=$PPID
    TTY=$(/bin/ps -o tty= -p "$P" | /usr/bin/tr -d ' ')
    if [ -z "$TTY" ] || [ "$TTY" = "??" ]; then
      P=$(/bin/ps -o ppid= -p "$P" | /usr/bin/tr -d ' ')
      TTY=$(/bin/ps -o tty= -p "$P" | /usr/bin/tr -d ' ')
    fi
    printf '{"provider":"gemini","tty":"%s","pid":%s,"raw":%s}\\n' "$TTY" "$P" "$IN" >> \(Shell.quote(HookInstaller.attentionLogPath))
    printf '{}'
    """

    static let agyHookScript = """
    #!/bin/sh
    IN=$(cat)
    [ -z "$IN" ] && IN='{}'
    P=$PPID
    TTY=$(/bin/ps -o tty= -p "$P" | /usr/bin/tr -d ' ')
    if [ -z "$TTY" ] || [ "$TTY" = "??" ]; then
      P=$(/bin/ps -o ppid= -p "$P" | /usr/bin/tr -d ' ')
      TTY=$(/bin/ps -o tty= -p "$P" | /usr/bin/tr -d ' ')
    fi
    printf '{"provider":"agy","tty":"%s","pid":%s,"raw":%s}\\n' "$TTY" "$P" "$IN" >> \(Shell.quote(HookInstaller.attentionLogPath))
    printf '{}'
    """

    private static var ourEntry: [String: Any] {
        [
            "matcher": "*",
            "hooks": [[
                "name": hookName,
                "type": "command",
                "command": quotedHookScriptPath,
            ]],
        ]
    }

    private static var ourAgyEntry: [String: Any] {
        [
            "PreInvocation": [["type": "command", "command": quotedAgyHookScriptPath]],
            "Stop": [["type": "command", "command": quotedAgyHookScriptPath]],
        ]
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        guard let inner = entry["hooks"] as? [[String: Any]] else { return false }
        return inner.contains {
            ($0["command"] as? String == quotedHookScriptPath) || ($0["name"] as? String == hookName)
        }
    }

    private static func settingsObject(_ json: Data) throws -> [String: Any] {
        guard !json.isEmpty else { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: json),
              let dict = obj as? [String: Any] else { throw HookError.malformedSettings }
        return dict
    }

    private static func stripOurs(_ hooks: inout [String: Any]) {
        for event in events {
            guard let entries = hooks[event] as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurs($0) }
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
    }

    private static func encode(_ obj: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    static func install(into json: Data) throws -> Data {
        var obj = try settingsObject(json)
        var hooks = obj["hooks"] as? [String: Any] ?? [:]
        stripOurs(&hooks)
        for event in events {
            hooks[event] = (hooks[event] as? [[String: Any]] ?? []) + [ourEntry]
        }
        obj["hooks"] = hooks
        return try encode(obj)
    }

    static func remove(from json: Data) throws -> Data {
        var obj = try settingsObject(json)
        guard var hooks = obj["hooks"] as? [String: Any] else { return json }
        stripOurs(&hooks)
        if hooks.isEmpty { obj.removeValue(forKey: "hooks") } else { obj["hooks"] = hooks }
        return try encode(obj)
    }

    static func installAgy(into json: Data) throws -> Data {
        var obj = try settingsObject(json)
        obj[hookName] = ourAgyEntry
        return try encode(obj)
    }

    static func removeAgy(from json: Data) throws -> Data {
        var obj = try settingsObject(json)
        guard obj[hookName] != nil else { return json }
        obj.removeValue(forKey: hookName)
        return try encode(obj)
    }

    static func setEnabled(_ enabled: Bool,
                           settingsPath: String = GeminiConfig.settingsPath,
                           agyHooksPath: String = GeminiConfig.agyHooksPath,
                           useAgy: Bool = GeminiCLI.isAgyInstalled) throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: HookInstaller.appSupportDir, withIntermediateDirectories: true)
        if enabled {
            if !fm.fileExists(atPath: HookInstaller.attentionLogPath) {
                fm.createFile(atPath: HookInstaller.attentionLogPath, contents: Data())
            }
        }
        if useAgy {
            if enabled {
                try agyHookScript.write(toFile: agyHookScriptPath, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agyHookScriptPath)
            }
            let exists = fm.fileExists(atPath: agyHooksPath)
            if enabled || exists {
                let current = fm.contents(atPath: agyHooksPath) ?? Data("{}".utf8)
                let updated = enabled ? try installAgy(into: current) : try removeAgy(from: current)
                if enabled {
                    try fm.createDirectory(atPath: (agyHooksPath as NSString).deletingLastPathComponent,
                                           withIntermediateDirectories: true)
                }
                if current != updated || !exists {
                    try updated.write(to: URL(fileURLWithPath: agyHooksPath), options: .atomic)
                }
            }
            if fm.fileExists(atPath: settingsPath),
               let current = fm.contents(atPath: settingsPath),
               let cleaned = try? remove(from: current), cleaned != current {
                try? cleaned.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            }
            return
        }
        if enabled {
            try hookScript.write(toFile: hookScriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptPath)
        }
        let exists = fm.fileExists(atPath: settingsPath)
        if !enabled && !exists { return }
        let current = fm.contents(atPath: settingsPath) ?? Data("{}".utf8)
        let updated = enabled ? try install(into: current) : try remove(from: current)
        if enabled {
            try fm.createDirectory(atPath: (settingsPath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
        }
        if current != updated || !exists {
            try updated.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        }
    }
}
