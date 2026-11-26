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
    let model: CodexModel
    @Published var profiles: [CodexProfile]
    @Published var selected: String {
        didSet {
            guard selected != oldValue else { return }
            defaults.set(selected, forKey: PrefKey.codexSelectedProfile)
            model.accountChanged()
            Task {
                await model.refresh(force: true)
                await refreshProfileUsage()
            }
        }
    }
    @Published var error: String?
    @Published var usageByProfile: [String: String] = [:]
    @Published private(set) var isDeletingAccount = false
    private var lastUsageRefresh = Date.distantPast
    private var refreshingUsage = false
    private let logins: CodexLoginManager
    private let defaults: UserDefaults
    private let launchLogin: (CodexProfile?) -> String?

    init(logins: CodexLoginManager? = nil, defaults: UserDefaults = .standard,
         launchLogin: @escaping (CodexProfile?) -> String? = TerminalLauncher.codexLogin) {
        let logins = logins ?? .shared
        self.logins = logins
        self.defaults = defaults
        self.launchLogin = launchLogin
        profiles = Self.storedProfiles(in: defaults)
        selected = defaults.string(forKey: PrefKey.codexSelectedProfile) ?? ""
        model = CodexModel(logins: logins, currentProfile: { Self.current(in: defaults) })
    }

    nonisolated static var savedProfiles: [CodexProfile] {
        storedProfiles(in: .standard)
    }

    private nonisolated static func storedProfiles(in defaults: UserDefaults) -> [CodexProfile] {
        guard let data = defaults.data(forKey: PrefKey.codexProfiles),
              let profiles = try? JSONDecoder().decode([CodexProfile].self, from: data) else { return [] }
        return profiles.filter { UUID(uuidString: $0.id) != nil }
    }

    nonisolated static var current: CodexProfile? {
        current(in: .standard)
    }

    private nonisolated static func current(in defaults: UserDefaults) -> CodexProfile? {
        let selected = defaults.string(forKey: PrefKey.codexSelectedProfile)
        return storedProfiles(in: defaults).first { $0.id == selected }
    }

    nonisolated static func command(_ arguments: String = "", profile: CodexProfile? = current) -> String {
        guard let profile, profile.usesDefaultHome != true else { return "codex " + arguments }
        return "env CODEX_HOME=\(Shell.quote(profile.home)) codex -c 'cli_auth_credentials_store=\"keyring\"' " + arguments
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: PrefKey.codexProfiles)
        }
    }

    func captureCurrentLogin(email: String) {
        guard !isDeletingAccount,
              !profiles.contains(where: { $0.id == selected }),
              !defaults.bool(forKey: PrefKey.codexDefaultProfileDeleted) else { return }
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

    nonisolated static func usageSummary(_ limits: CodexLimits) -> String {
        guard let top = limits.mainWindows.max(by: { $0.usedPercent < $1.usedPercent }) else { return "not available" }
        let text = "\(Int(top.usedPercent))% \(top.label.lowercased())"
        guard let reset = top.reset else { return text }
        return "\(text) · \(UsageParser.countdown(to: reset))"
    }

    func refreshProfileUsage(minimumInterval: TimeInterval = 60) async {
        guard CodingAgent.codex.isEnabled else { return }
        if let limits = model.limits, model.error == nil, model.loadedProfile == selected {
            usageByProfile[selected] = Self.usageSummary(limits)
        }
        guard !refreshingUsage, Date().timeIntervalSince(lastUsageRefresh) >= minimumInterval else { return }
        refreshingUsage = true
        defer { refreshingUsage = false }
        lastUsageRefresh = Date()
        let scannedProfiles = profiles
        for profile in scannedProfiles where profile.id != selected {
            guard profiles.contains(where: { $0.id == profile.id }) else { continue }
            guard !Task.isCancelled, CodingAgent.codex.isEnabled else {
                lastUsageRefresh = .distantPast
                return
            }
            let result = await logins.read(profile: profile)
            guard !Task.isCancelled else { lastUsageRefresh = .distantPast; return }
            guard profiles.contains(where: { $0.id == profile.id }) else { continue }
            switch result {
            case .success(let (_, limits)): usageByProfile[profile.id] = Self.usageSummary(limits)
            case .failure: usageByProfile[profile.id] = "not available"
            }
        }
    }

    func add(name: String) {
        guard !isDeletingAccount else { return }
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
            error = launchLogin(profile)
        } catch {
            self.error = "Cannot create Codex account: \(error.localizedDescription)"
        }
    }

    func rename(_ id: String, to name: String) {
        guard !isDeletingAccount else { return }
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

    func relogin(_ id: String) {
        guard !isDeletingAccount, let profile = profiles.first(where: { $0.id == id }) else { return }
        error = launchLogin(profile)
        lastUsageRefresh = .distantPast
        if id == selected { model.accountChanged() }
    }

    func delete(_ id: String) {
        guard !isDeletingAccount, let profile = profiles.first(where: { $0.id == id }) else { return }
        isDeletingAccount = true
        if selected == id { model.accountChanged() }
        Task {
            defer { isDeletingAccount = false }
            if case .failure(let failure) = await logins.logout(profile: profile) {
                error = failure.localizedDescription
                return
            }
            profiles.removeAll { $0.id == id }
            usageByProfile[id] = nil
            if profile.usesDefaultHome == true {
                defaults.set(true, forKey: PrefKey.codexDefaultProfileDeleted)
            }
            if selected == id { selected = profiles.first?.id ?? "" }
            persist()
            error = nil
        }
    }
}
