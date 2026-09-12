import Foundation

enum CodingAgent: String, CaseIterable, Identifiable {
    case claude, codex
    var id: String { rawValue }
    var name: String { self == .claude ? "Claude" : "Codex" }
    var enabledKey: String { "agent.\(rawValue).enabled" }
    var hotkeyKey: String { "agent.\(rawValue).hotkey" }
    func isEnabled(in defaults: UserDefaults) -> Bool { defaults.object(forKey: enabledKey) as? Bool ?? true }
    var isEnabled: Bool { isEnabled(in: .standard) }
    static var enabled: [CodingAgent] { allCases.filter(\.isEnabled) }
}
