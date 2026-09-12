import AppKit
import Foundation

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal, iterm, ghostty, warp
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iterm: "iTerm2"
        case .ghostty: "Ghostty"
        case .warp: "Warp"
        }
    }
    var bundleID: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .iterm: "com.googlecode.iterm2"
        case .ghostty: "com.mitchellh.ghostty"
        case .warp: "dev.warp.Warp-Stable"
        }
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    static var selected: TerminalApp {
        if let raw = UserDefaults.standard.string(forKey: PrefKey.terminalApp),
           let app = TerminalApp(rawValue: raw) { return app }
        return detectDefault()
    }

    static func detectDefault() -> TerminalApp {
        let candidates: [TerminalApp] = [.ghostty, .iterm, .warp]
        if let hit = candidates.first(where: \.isRunning) { return hit }
        if let hit = candidates.first(where: {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil
        }) { return hit }
        return .terminal
    }
}

enum TerminalLauncher {
    static var sessionDirectory: String? {
        if let stored = UserDefaults.standard.string(forKey: PrefKey.sessionDir), !stored.isEmpty {
            return stored
        }
        let dev = NSHomeDirectory() + "/Developer"
        return FileManager.default.fileExists(atPath: dev) ? dev : nil
    }

    static func sessionCommand(for dir: String?, agent: CodingAgent = .claude) -> String {
        let command = agent == .codex ? CodexAccounts.command().trimmingCharacters(in: .whitespaces) : agent.rawValue
        guard let dir, !dir.isEmpty else { return command }
        return "cd '" + dir.replacingOccurrences(of: "'", with: "'\\''") + "' && " + command
    }

    @discardableResult
    static func newSession(agent: CodingAgent) -> String? {
        open(sessionCommand(for: sessionDirectory, agent: agent), in: .selected)
    }

    @discardableResult
    static func codexLogin() -> String? { open(CodexAccounts.command("login"), in: .selected) }

    static func appleScriptLiteral(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static let loginCommand = "claude auth login"

    @discardableResult
    static func newLogin(in app: TerminalApp = .selected) -> String? {
        open(loginCommand, in: app)
    }

    private static func open(_ command: String, in app: TerminalApp) -> String? {
        let scripted = appleScriptLiteral(command)
        switch app {
        case .terminal: return newTerminalSession(scripted)
        case .iterm: return newITermSession(scripted)
        case .ghostty, .warp: return newTypedSession(app, scripted)
        }
    }

    static func promptForAccessibility() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    static func requestPermissionsOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: PrefKey.didRequestPermissions) else { return }
        UserDefaults.standard.set(true, forKey: PrefKey.didRequestPermissions)
        promptForAccessibility()
        Shell.fire("/usr/bin/osascript", ["-e", "tell application \"System Events\" to count processes"])
    }

    private static func newTerminalSession(_ command: String) -> String? {
        let useTab = TerminalApp.terminal.isRunning && AXIsProcessTrusted()
        if TerminalApp.terminal.isRunning, !useTab { promptForAccessibility() }
        let tab = useTab ? """
            if (count of windows) > 0 then
                tell application "System Events" to keystroke "t" using command down
                delay 0.4
                do script "\(command)" in selected tab of front window
            else
                do script "\(command)"
            end if
        """ : """
            do script "\(command)"
        """
        return runAppleScript("""
        tell application "Terminal"
            activate
        \(tab)
        end tell
        """)
    }

    private static func newITermSession(_ command: String) -> String? {
        return runAppleScript("""
        tell application "iTerm"
            activate
            if (count of windows) > 0 then
                tell current window
                    create tab with default profile
                    tell current session to write text "\(command)"
                end tell
            else
                set w to (create window with default profile)
                tell current session of w to write text "\(command)"
            end if
        end tell
        """)
    }

    private static func typeSessionCommand(_ command: String, intoProcess name: String) -> String? {
        return runAppleScript("""
        tell application "\(name)" to activate
        delay 0.3
        tell application "System Events"
            tell process "\(name)"
                if (count of windows) > 0 then
                    keystroke "t" using command down
                else
                    keystroke "n" using command down
                end if
            end tell
            delay 0.4
            keystroke "\(command)"
            key code 36
        end tell
        """)
    }

    private static func newTypedSession(_ app: TerminalApp, _ command: String) -> String? {
        let name = app.displayName
        guard AXIsProcessTrusted() else {
            promptForAccessibility()
            if !app.isRunning { Shell.fire("/usr/bin/open", ["-na", name]) }
            return "\(name) needs Accessibility access to open a session"
        }
        if app.isRunning {
            return typeSessionCommand(command, intoProcess: name)
        }
        Shell.fire("/usr/bin/open", ["-na", name])
        return runAppleScript("""
        tell application "System Events"
            set tries to 0
            repeat until ((exists process "\(name)") and (exists window 1 of process "\(name)")) or tries > 50
                delay 0.2
                set tries to tries + 1
            end repeat
            delay 0.5
            keystroke "\(command)"
            key code 36
        end tell
        """)
    }

    @discardableResult
    static func focusSession(tty: String, cwd: String = "") -> String? {
        guard !tty.isEmpty, tty != "??", let app = owningApp(ofTTY: tty) else {
            return focus(tty: tty)
        }
        if let terminal = terminal(hosting: app.bundleIdentifier) {
            return focus(tty: tty, in: terminal)
        } else if !cwd.isEmpty, let bundleID = app.bundleIdentifier {
            Shell.fire("/usr/bin/open", ["-b", bundleID, cwd])
        } else {
            app.activate()
        }
        return nil
    }

    static func ttys(ownedBy appPid: Int32, rows: [ProcRow]) -> Set<String> {
        let parents = Proc.parents(rows)
        let owned = rows.filter { $0.tty != "??" }
            .filter { Proc.ancestor(of: $0.pid, parents: parents) { $0 == appPid } != nil }
        return Set(owned.map(\.tty))
    }

    static func terminal(hosting bundleID: String?) -> TerminalApp? {
        TerminalApp.allCases.first { $0.bundleID == bundleID }
    }

    struct FrontApp: Sendable {
        let bundleID: String?
        let pid: Int32
    }

    static func frontApp() -> FrontApp? {
        NSWorkspace.shared.frontmostApplication.map {
            FrontApp(bundleID: $0.bundleIdentifier, pid: $0.processIdentifier)
        }
    }

    static func isLooking(atTTY tty: String, front: FrontApp) -> Bool {
        guard !tty.isEmpty, tty != "??" else { return false }
        switch terminal(hosting: front.bundleID) {
        case .terminal?:
            return scriptOutput("tell application \"Terminal\" to get tty of selected tab of front window")?
                .hasSuffix(tty) ?? false
        case .iterm?:
            return scriptOutput("tell application \"iTerm\" to get tty of current session of current window")?
                .hasSuffix(tty) ?? false
        case .ghostty?, .warp?, nil:
            break
        }
        let owned = ttys(ownedBy: front.pid, rows: Proc.all())
        return mostRecentlyUsed(tty, atimes: Dictionary(uniqueKeysWithValues:
            owned.map { ($0, ptyAtime($0)) }))
    }

    static func mostRecentlyUsed(_ tty: String, atimes: [String: TimeInterval],
                                 grace: TimeInterval = 2) -> Bool {
        guard let mine = atimes[tty] else { return false }
        guard atimes.count > 1 else { return true }
        let others = atimes.filter { $0.key != tty }.values.max() ?? 0
        return mine + grace >= others
    }

    private static func ptyAtime(_ tty: String) -> TimeInterval {
        var st = stat()
        guard lstat("/dev/\(tty)", &st) == 0 else { return 0 }
        return TimeInterval(st.st_atimespec.tv_sec)
    }

    private static func scriptOutput(_ script: String) -> String? {
        let out = Shell.capture("/usr/bin/osascript", ["-e", script])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : out
    }

    static func owningApp(ofTTY tty: String) -> NSRunningApplication? {
        let rows = Proc.all()
        let parents = Proc.parents(rows)
        for pid in rows.filter({ $0.tty == tty }).map(\.pid) {
            let hit = Proc.ancestor(of: pid, parents: parents) { candidate in
                NSRunningApplication(processIdentifier: candidate)?.activationPolicy == .regular
            }
            if let hit { return NSRunningApplication(processIdentifier: hit) }
        }
        return nil
    }

    @discardableResult
    static func focus(tty: String, in app: TerminalApp = .selected) -> String? {
        switch app {
        case .terminal:
            return runAppleScript("""
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        if (tty of t) ends with "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                        end if
                    end repeat
                end repeat
            end tell
            """)
        case .iterm:
            return runAppleScript("""
            tell application "iTerm"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if (tty of s) ends with "\(tty)" then
                                select w
                                tell w to select t
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            """)
        case .ghostty, .warp:
            Shell.fire("/usr/bin/open", ["-a", app.displayName])
            return nil
        }
    }

    @discardableResult
    private static func runAppleScript(_ source: String) -> String? {
        let result = Shell.run("/usr/bin/osascript", ["-e", source])
        guard result.status != 0 else { return nil }
        let message = result.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "osascript failed (\(result.status))" : message
    }
}
