import AppKit
import Foundation
import UserNotifications

struct AttentionEvent: Equatable {
    let tty: String
    let cwd: String
    var message = ""
}

enum AttentionParser {
    static func parse(line: String) -> AttentionEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["raw"] as? [String: Any],
              raw["notification_type"] as? String != "idle_prompt"
        else { return nil }
        return AttentionEvent(tty: obj["tty"] as? String ?? "",
                              cwd: projectRoot(cwd: raw["cwd"] as? String ?? "",
                                               transcriptPath: raw["transcript_path"] as? String ?? ""),
                              message: raw["last_assistant_message"] as? String ?? "")
    }

    static func projectRoot(cwd: String, transcriptPath: String) -> String {
        let name = ((transcriptPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        guard name.hasPrefix("-") else { return cwd }
        var dir = cwd
        while dir.count > 1 {
            if ClaudePaths.flatten(dir) == name { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        let naive = name.replacingOccurrences(of: "-", with: "/")
        return FileManager.default.fileExists(atPath: naive) ? naive : cwd
    }
}

struct LogTail {
    private(set) var offset: UInt64 = 0
    private var partial = ""

    mutating func skipExisting(at path: String) {
        offset = Self.size(of: path)
        partial = ""
    }

    mutating func reset() {
        offset = 0
        partial = ""
    }

    mutating func lines(fromFileAt path: String) -> [String] {
        guard let fh = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset { reset() }
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return [] }
        offset += UInt64(data.count)
        var parts = (partial + String(decoding: data, as: UTF8.self))
            .components(separatedBy: "\n")
        partial = parts.removeLast()
        return parts.filter { !$0.isEmpty }
    }

    private static func size(of path: String) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
    }
}

@MainActor
final class AttentionCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var isOn = UserDefaults.standard.bool(forKey: PrefKey.chimeOn) {
        didSet {
            UserDefaults.standard.set(isOn, forKey: PrefKey.chimeOn)
            apply()
        }
    }
    @Published var lastError: String?

    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var tail = LogTail()

    private func apply() {
        do {
            try HookInstaller.setEnabled(isOn)
            lastError = nil
        } catch HookInstaller.HookError.malformedSettings {
            lastError = "Chime setup failed: ~/.claude/settings.json is not valid JSON"
        } catch {
            lastError = "Chime setup failed: cannot write ~/.claude/settings.json"
        }
        if isOn { startWatching() } else { stopWatching() }
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if isOn { apply() }
    }

    private func startWatching() {
        stopWatching()
        fd = open(HookInstaller.attentionLogPath, O_EVTONLY)
        guard fd >= 0 else { return }
        tail.skipExisting(at: HookInstaller.attentionLogPath)
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .main)
        src.setEventHandler { [weak self] in self?.drain() }
        src.setCancelHandler { [fd] in close(fd) }
        src.resume()
        source = src
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
    }

    private func drain() {
        for line in tail.lines(fromFileAt: HookInstaller.attentionLogPath) {
            guard let event = AttentionParser.parse(line: line) else { continue }
            handle(event)
        }
    }

    private func handle(_ event: AttentionEvent) {
        guard let front = TerminalLauncher.frontApp() else { deliver(event); return }
        Task { [weak self] in
            let looking = await Task.detached {
                TerminalLauncher.isLooking(atTTY: event.tty, front: front)
            }.value
            if !looking { self?.deliver(event) }
        }
    }

    private func deliver(_ event: AttentionEvent) {
        CueSynth.play(UserDefaults.standard.string(forKey: PrefKey.chimeSound))

        let content = UNMutableNotificationContent()
        let dir = (event.cwd as NSString).lastPathComponent
        content.title = dir.isEmpty ? "Claude finished" : "Claude finished · \(dir)"
        content.body = event.message.isEmpty
            ? (event.cwd as NSString).abbreviatingWithTildeInPath
            : String(event.message.prefix(140))
        content.userInfo = ["tty": event.tty, "cwd": event.cwd]
        let req = UNNotificationRequest(identifier: UUID().uuidString,
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    func clearLog() {
        if source != nil { drain() }
        tail.reset()
        try? Data().write(to: URL(fileURLWithPath: HookInstaller.attentionLogPath))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let tty = info["tty"] as? String ?? ""
        let cwd = info["cwd"] as? String ?? ""
        await MainActor.run {
            if !tty.isEmpty { TerminalLauncher.focusSession(tty: tty, cwd: cwd) }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
