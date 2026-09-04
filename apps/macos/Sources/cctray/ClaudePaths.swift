import Foundation

enum ClaudePaths {
    static func flatten(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    static func projectDir(for cwd: String) -> String {
        NSHomeDirectory() + "/.claude/projects/" + flatten(cwd)
    }

    static func scratchpadDir(for cwd: String) -> String {
        "/private/tmp/claude-\(getuid())/" + flatten(cwd)
    }
}
