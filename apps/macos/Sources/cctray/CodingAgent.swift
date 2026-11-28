import Foundation

enum CodingAgent: String, CaseIterable, Identifiable {
    case claude, codex, gemini
    var id: String { rawValue }
    var name: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .gemini: "Gemini"
        }
    }
    var enabledKey: String { "agent.\(rawValue).enabled" }
    var hotkeyKey: String { "agent.\(rawValue).hotkey" }
    var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var enabled: [CodingAgent] { allCases.filter(\.isEnabled) }
}
