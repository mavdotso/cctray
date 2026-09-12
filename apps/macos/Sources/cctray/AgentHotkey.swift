import AppKit
import SwiftUI

struct AgentHotkey: Codable, Equatable {
    let keyCode: UInt16?
    let modifiers: UInt
    let key: String

    static let none = AgentHotkey(keyCode: nil, modifiers: 0, key: "")
    static func read(for agent: CodingAgent, defaults: UserDefaults = .standard) -> AgentHotkey {
        if let data = defaults.data(forKey: agent.hotkeyKey),
           let shortcut = try? JSONDecoder().decode(Self.self, from: data) { return shortcut }
        return AgentHotkey(keyCode: agent == .claude ? 8 : 31,
                           modifiers: NSEvent.ModifierFlags([.command, .option]).rawValue,
                           key: agent == .claude ? "C" : "O")
    }

    var label: String {
        guard keyCode != nil else { return "None" }
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        return (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + key
    }

    func matches(keyCode: UInt16, modifiers: UInt) -> Bool {
        self.keyCode == keyCode && self.modifiers == modifiers
    }

    static let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static func agent(keyCode: UInt16, modifiers: UInt, defaults: UserDefaults = .standard) -> CodingAgent? {
        CodingAgent.allCases.first {
            $0.isEnabled(in: defaults) && read(for: $0, defaults: defaults).matches(keyCode: keyCode, modifiers: modifiers)
        }
    }
}

struct AgentHotkeyRecorder: View {
    let agent: CodingAgent
    @Binding var recordingAgent: CodingAgent?
    @State private var shortcut = AgentHotkey.none
    @State private var monitor: Any?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack {
                Button(monitor == nil ? shortcut.label : "Press shortcut…") { record() }
                    .accessibilityLabel("\(agent.name) shortcut: \(shortcut.label)")
                if shortcut.keyCode != nil {
                    Button("Clear") { save(.none) }.controlSize(.small)
                }
            }
            if let error { Text(error).font(.caption2).foregroundStyle(.orange) }
        }
        .onAppear { shortcut = AgentHotkey.read(for: agent) }
        .onChange(of: recordingAgent) { _, value in if value != agent { stop() } }
        .onDisappear { stop() }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func save(_ value: AgentHotkey) {
        stop()
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: agent.hotkeyKey)
            shortcut = value
            error = nil
        }
    }

    private func record() {
        stop()
        recordingAgent = agent
        error = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            let flags = event.modifierFlags.intersection(AgentHotkey.relevantFlags)
            guard !flags.intersection([.command, .option, .control]).isEmpty,
                  let key = event.charactersIgnoringModifiers, key.count == 1,
                  key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else {
                error = "Use ⌘, ⌥ or ⌃ with a letter or number"
                return nil
            }
            let value = AgentHotkey(keyCode: event.keyCode, modifiers: flags.rawValue, key: key.uppercased())
            if let other = CodingAgent.allCases.first(where: {
                $0 != agent && AgentHotkey.read(for: $0).matches(keyCode: event.keyCode, modifiers: flags.rawValue)
            }) {
                error = "Already used by \(other.name)"
                return nil
            }
            save(value)
            return nil
        }
    }
}
