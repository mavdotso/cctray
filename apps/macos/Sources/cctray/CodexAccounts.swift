import Foundation

struct CodexProfile: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var usesDefaultHome: Bool? = nil
    var home: String {
        usesDefaultHome == true ? CodexHook.home : HookInstaller.appSupportDir + "/codex-accounts/" + id
    }
}

@MainActor
final class CodexAccounts: ObservableObject {
    let model = CodexModel()
    @Published var profiles: [CodexProfile] = savedProfiles
    @Published var selected = UserDefaults.standard.string(forKey: PrefKey.codexSelectedProfile) ?? "" {
        didSet {
            guard selected != oldValue else { return }
            UserDefaults.standard.set(selected, forKey: PrefKey.codexSelectedProfile)
            model.accountChanged()
            Task {
                await model.refresh(force: true)
                await refreshProfileUsage()
            }
        }
    }
    @Published var error: String?
    @Published var usageByProfile: [String: String] = [:]
    private var lastUsageRefresh = Date.distantPast
    private var refreshingUsage = false

    nonisolated static var savedProfiles: [CodexProfile] {
        guard let data = UserDefaults.standard.data(forKey: PrefKey.codexProfiles),
              let profiles = try? JSONDecoder().decode([CodexProfile].self, from: data) else { return [] }
        return profiles.filter { UUID(uuidString: $0.id) != nil }
    }

    nonisolated static var current: CodexProfile? {
        let selected = UserDefaults.standard.string(forKey: PrefKey.codexSelectedProfile)
        return savedProfiles.first { $0.id == selected }
    }

    nonisolated static func command(_ arguments: String = "", profile: CodexProfile? = current) -> String {
        guard let profile, profile.usesDefaultHome != true else { return "codex " + arguments }
        return "env CODEX_HOME=\(Shell.quote(profile.home)) codex -c 'cli_auth_credentials_store=\"keyring\"' " + arguments
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: PrefKey.codexProfiles)
        }
    }

    func captureCurrentLogin(email: String) {
        guard Self.current == nil,
              !UserDefaults.standard.bool(forKey: PrefKey.codexDefaultProfileDeleted) else { return }
        if let existing = profiles.first(where: { $0.usesDefaultHome == true }) {
            selected = existing.id
        } else {
            let profile = CodexProfile(id: UUID().uuidString,
                                       name: AccountNaming.profileName(for: email, existing: profiles.map(\.name)),
                                       usesDefaultHome: true)
            profiles.append(profile)
            persist()
            selected = profile.id
        }
    }

    nonisolated static func usageSummary(_ limits: CodexLimits, now: Date = Date()) -> String {
        let windows = limits.buckets.flatMap { [$0.1.primary, $0.1.secondary].compactMap { $0 } }
        guard let top = windows.max(by: { $0.usedPercent < $1.usedPercent }) else { return "not available" }
        let label = top.windowDurationMins == 10080 ? "week" : top.label
        let text = "\(Int(top.usedPercent))% \(label)"
        guard let reset = top.reset else { return text }
        return "\(text) · \(UsageParser.countdown(to: reset, from: now))"
    }

    func refreshProfileUsage() async {
        guard CodingAgent.codex.isEnabled else { return }
        if let limits = model.limits, model.error == nil, model.loadedProfile == selected {
            usageByProfile[selected] = Self.usageSummary(limits)
        }
        guard !refreshingUsage, Date().timeIntervalSince(lastUsageRefresh) >= 60 else { return }
        refreshingUsage = true
        defer { refreshingUsage = false }
        lastUsageRefresh = Date()
        for profile in profiles where profile.id != selected {
            guard !Task.isCancelled, CodingAgent.codex.isEnabled else {
                lastUsageRefresh = .distantPast
                return
            }
            let result = await Task.detached { Result { try CodexRPC.read(profile: profile) } }.value
            guard !Task.isCancelled else { lastUsageRefresh = .distantPast; return }
            guard profiles.contains(where: { $0.id == profile.id }) else { continue }
            switch result {
            case .success(let (_, limits)): usageByProfile[profile.id] = Self.usageSummary(limits)
            case .failure: usageByProfile[profile.id] = "not available"
            }
        }
    }

    func add(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !profiles.contains(where: { $0.name == name }) else {
            error = "An account with that name already exists"
            return
        }
        let profile = CodexProfile(id: UUID().uuidString, name: name)
        do {
            let fm = FileManager.default
            try fm.createDirectory(atPath: profile.home, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let config = CodexHook.home + "/config.toml"
            if fm.fileExists(atPath: config) {
                try fm.copyItem(atPath: config, toPath: profile.home + "/config.toml")
            }
            for name in ["AGENTS.md", "skills"] where fm.fileExists(atPath: CodexHook.home + "/" + name) {
                try fm.createSymbolicLink(atPath: profile.home + "/" + name,
                                          withDestinationPath: CodexHook.home + "/" + name)
            }
            profiles.append(profile)
            persist()
            selected = profile.id
            error = TerminalLauncher.codexLogin()
        } catch {
            self.error = "Cannot create Codex account: \(error.localizedDescription)"
        }
    }

    func rename(_ id: String, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard !profiles.contains(where: { $0.id != id && $0.name == name }) else {
            error = "An account with that name already exists"
            return
        }
        profiles[index].name = name
        persist()
        error = nil
    }

    func delete(_ id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        Task {
            let status = await Task.detached {
                Shell.run("/bin/zsh", ["-ilc", Self.command("logout", profile: profile)]).status
            }.value
            guard status == 0 else { error = "Delete failed: cannot remove the Codex login"; return }
            profiles.removeAll { $0.id == id }
            usageByProfile[id] = nil
            if profile.usesDefaultHome == true {
                UserDefaults.standard.set(true, forKey: PrefKey.codexDefaultProfileDeleted)
            }
            if selected == id { selected = profiles.first?.id ?? "" }
            persist()
            error = nil
        }
    }
}
