import Foundation

enum CodingAgent: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var enabledKey: String { "agent.\(rawValue).enabled" }
    var hotkeyKey: String { "agent.\(rawValue).hotkey" }
    var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var enabled: [CodingAgent] { allCases.filter(\.isEnabled) }
}
