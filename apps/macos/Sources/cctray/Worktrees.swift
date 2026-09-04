import Foundation

struct Worktree: Identifiable {
    let repo: String
    let path: String
    let lastCommit: Date
    let sizeKB: Int
    let dirty: Bool
    let locked: Bool
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var repoName: String { (repo as NSString).lastPathComponent }
    var ageDays: Int { max(0, Int(Date().timeIntervalSince(lastCommit)) / 86400) }
    var isRemovable: Bool { !dirty && !locked }
}

enum Worktrees {
    static func footerText(for selection: [Worktree]) -> String {
        let kb = selection.map(\.sizeKB).reduce(0, +)
        return "\(selection.count) selected · \(kb.kbSizeText)"
    }

    static func git(_ args: [String]) -> String {
        Shell.capture("/usr/bin/git",
                      ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"] + args)
    }

    static func linkedEntries(porcelain: String) -> [(path: String, locked: Bool)] {
        var entries: [(String, Bool)] = []
        var current: String?
        var locked = false
        for line in porcelain.split(separator: "\n") {
            if line.hasPrefix("worktree ") {
                if let c = current { entries.append((c, locked)) }
                current = String(line.dropFirst("worktree ".count))
                locked = false
            } else if line == "locked" || line.hasPrefix("locked ") {
                locked = true
            }
        }
        if let c = current { entries.append((c, locked)) }
        return Array(entries.dropFirst())
    }

    static let defaultStaleDays = 7

    static var staleDays: Int {
        UserDefaults.standard.object(forKey: PrefKey.staleDays) as? Int ?? defaultStaleDays
    }

    static func isStale(epoch: TimeInterval, now: Date, days: Int) -> Bool {
        now.timeIntervalSince1970 - epoch > TimeInterval(days) * 86400
    }

    static func scan(root: String, now: Date = Date(), days: Int = defaultStaleDays) -> [Worktree] {
        let fm = FileManager.default
        guard let subdirs = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var result: [Worktree] = []
        for name in subdirs {
            let repo = (root as NSString).appendingPathComponent(name)
            guard fm.fileExists(atPath: repo + "/.git") else { continue }
            _ = git(["-C", repo, "worktree", "prune"])
            let porcelain = git(["-C", repo, "worktree", "list", "--porcelain"])
            for entry in linkedEntries(porcelain: porcelain) where fm.fileExists(atPath: entry.path) {
                let head = git(["-C", entry.path, "log", "-1", "--format=%ct"])
                guard let epoch = TimeInterval(head.trimmingCharacters(in: .whitespacesAndNewlines)),
                      isStale(epoch: epoch, now: now, days: days) else { continue }
                let status = git(["-C", entry.path, "status", "--porcelain"])
                let du = Shell.capture("/usr/bin/du", ["-sk", entry.path])
                    .split(separator: "\t").first.flatMap { Int($0) } ?? 0
                result.append(Worktree(repo: repo, path: entry.path,
                                       lastCommit: Date(timeIntervalSince1970: epoch),
                                       sizeKB: du,
                                       dirty: !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                       locked: entry.locked))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func removeAssociated(for path: String) {
        for dir in [ClaudePaths.projectDir(for: path), ClaudePaths.scratchpadDir(for: path)] {
            try? FileManager.default.removeItem(atPath: dir)
        }
    }
}

@MainActor
final class WorktreeModel: ObservableObject {
    @Published var stale: [Worktree] = []
    private var scanning = false
    private var lastScan: Date?
    private var lastDays = 0


    private static let rescanAfter: TimeInterval = 600

    func refresh(force: Bool = false) {
        guard !scanning else { return }
        let days = Worktrees.staleDays
        if !force, days == lastDays, let last = lastScan,
           Date().timeIntervalSince(last) < Self.rescanAfter { return }
        guard let root = TerminalLauncher.sessionDirectory else { return }
        scanning = true
        Task { [weak self] in
            let found = await Task.detached { Worktrees.scan(root: root, days: days) }.value
            guard let self else { return }
            self.stale = found
            self.lastScan = Date()
            self.lastDays = days
            self.scanning = false
            let targets = found.filter(\.isRemovable).map(\.path)
            if !force, !targets.isEmpty,
               UserDefaults.standard.bool(forKey: PrefKey.autoClean) {
                _ = await self.remove(paths: Set(targets))
            }
        }
    }

    func remove(paths: Set<String>) async -> (removed: Int, skipped: Int, freedKB: Int) {
        let targets = stale.filter { paths.contains($0.path) }
        let result = await Task.detached {
            var removed = 0, skipped = 0, freed = 0
            for wt in targets {
                if wt.locked {
                    _ = Worktrees.git(["-C", wt.repo, "worktree", "unlock", wt.path])
                }
                var args = ["-C", wt.repo, "worktree", "remove"]
                if wt.dirty { args.append("--force") }
                args.append(wt.path)
                _ = Worktrees.git(args)
                if FileManager.default.fileExists(atPath: wt.path) {
                    skipped += 1
                } else {
                    removed += 1
                    freed += wt.sizeKB
                    Worktrees.removeAssociated(for: wt.path)
                }
            }
            return (removed, skipped, freed)
        }.value
        refresh(force: true)
        return result
    }
}
