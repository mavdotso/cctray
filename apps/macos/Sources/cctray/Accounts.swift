import Foundation
import Security

enum ClaudeConfig {
    static let path = NSHomeDirectory() + "/.claude.json"

    enum ConfigError: Error { case notAnObject }

    static func replaceOauthAccount(inClaudeJSON data: Data,
                                    with account: [String: Any]) throws -> Data {
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ConfigError.notAnObject }
        obj["oauthAccount"] = account
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    }

    static func readOauthAccount(fromClaudeJSON data: Data) -> [String: Any]? {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["oauthAccount"] as? [String: Any]
    }

    static func currentEmail() -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return readOauthAccount(fromClaudeJSON: data)?["emailAddress"] as? String
    }
}

enum AccountNaming {
    static func profileName(for email: String, existing: [String]) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        for candidate in [local, email] where !existing.contains(candidate) {
            return candidate
        }
        var n = 2
        while existing.contains("\(email)-\(n)") { n += 1 }
        return "\(email)-\(n)"
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published var profiles: [String] =
        UserDefaults.standard.stringArray(forKey: PrefKey.accountProfiles) ?? []
    @Published var active: String? =
        UserDefaults.standard.string(forKey: PrefKey.accountActive)
    @Published var statusText: String?
    @Published var currentEmail: String? = ClaudeConfig.currentEmail()
    @Published var isAddingAccount = false
    weak var usageModel: UsageModel?
    private let loginPoll: Duration = .seconds(2)
    private let loginTimeout: Duration = .seconds(600)
    private var addTask: Task<Void, Never>?

    func refreshIdentity() {
        currentEmail = ClaudeConfig.currentEmail()
    }

    private func persist() {
        UserDefaults.standard.set(profiles, forKey: PrefKey.accountProfiles)
        UserDefaults.standard.set(active, forKey: PrefKey.accountActive)
    }

    func profileServices(_ name: String) -> [String] {
        ["cctray-profile-\(name)", "CCTray-profile-\(name)"]
    }

    func readProfile(_ name: String) -> [String: Any]? {
        guard let data = profileServices(name).lazy
            .compactMap({ Keychain.read(service: $0) }).first else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func profileEmail(_ name: String) -> String? {
        (readProfile(name)?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    private func writeProfile(_ name: String, payload: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return Keychain.write(service: profileServices(name)[0], data: data)
    }

    func saveCurrent(as name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        guard let creds = ClaudeKeychain.readRaw(),
              let configData = FileManager.default.contents(atPath: ClaudeConfig.path),
              let account = ClaudeConfig.readOauthAccount(fromClaudeJSON: configData)
        else {
            statusText = "Save failed: no Claude Code login found"
            return
        }
        let payload: [String: Any] = [
            "credentials": creds.base64EncodedString(),
            "oauthAccount": account,
        ]
        guard writeProfile(clean, payload: payload) else {
            statusText = "Save failed: keychain write error"
            return
        }
        let replaced = profiles.contains(clean) ? profileEmail(clean) : nil
        if !profiles.contains(clean) { profiles.append(clean) }
        active = clean
        refreshIdentity()
        statusText = replaced.flatMap { $0 == currentEmail ? nil : "Replaced \(clean) — was \($0)" }
        persist()
    }

    func activate(_ name: String) {
        guard let payload = readProfile(name),
              let b64 = payload["credentials"] as? String,
              let creds = Data(base64Encoded: b64),
              let account = payload["oauthAccount"] as? [String: Any]
        else {
            statusText = "Switch failed: profile not readable"
            return
        }
        guard ClaudeKeychain.writeRaw(creds) else {
            statusText = "Switch failed: keychain write error"
            return
        }
        do {
            let current = FileManager.default.contents(atPath: ClaudeConfig.path) ?? Data("{}".utf8)
            let updated = try ClaudeConfig.replaceOauthAccount(inClaudeJSON: current, with: account)
            try updated.write(to: URL(fileURLWithPath: ClaudeConfig.path), options: .atomic)
        } catch {
            statusText = "Switch failed: cannot write ~/.claude.json"
            return
        }
        active = name
        refreshIdentity()
        persist()
        usageModel?.usage = nil
        usageModel?.isStale = false
        Task { [weak self] in
            let outcome = await self?.usageModel?.refresh(force: true)
            if self?.usageModel?.authFailed == true {
                self?.statusText =
                    "Profile tokens expired — run claude and log in, then re-save profile."
            } else if outcome == .skipped {
                self?.statusText = "Switched. Usage is rate limited; it fills in when that clears."
            } else {
                self?.statusText = nil
            }
        }
    }

    func loginToPreserve() -> String? {
        guard let email = ClaudeConfig.currentEmail(),
              !profiles.contains(where: { profileEmail($0) == email })
        else { return nil }
        return AccountNaming.profileName(for: email, existing: profiles)
    }

    func addAccount() {
        guard addTask == nil else { return }
        if let name = loginToPreserve() { saveCurrent(as: name) }
        let before = ClaudeConfig.currentEmail()
        if let error = TerminalLauncher.newLogin() {
            statusText = error
            return
        }
        isAddingAccount = true
        statusText = "Log in in the terminal — the profile saves itself."
        addTask = Task { [weak self] in
            guard let result = await self?.waitForLogin(after: before) else { return }
            self?.finishAdd(result)
        }
    }

    func cancelAdd() {
        addTask?.cancel()
        addTask = nil
        isAddingAccount = false
        statusText = nil
    }

    enum LoginWait: Equatable { case found(String), timedOut, cancelled }

    func waitForLogin(after before: String?) async -> LoginWait {
        var waited = Duration.zero
        while waited < loginTimeout {
            try? await Task.sleep(for: loginPoll)
            if Task.isCancelled { return .cancelled }
            let now = await Task.detached { ClaudeConfig.currentEmail() }.value
            if let now, now != before { return .found(now) }
            waited += loginPoll
        }
        return .timedOut
    }

    private func finishAdd(_ result: LoginWait) {
        guard result != .cancelled else { return }
        addTask = nil
        isAddingAccount = false
        guard case .found(let email) = result else {
            statusText = "No new login found. Nothing was saved."
            return
        }
        let name = AccountNaming.profileName(for: email, existing: profiles)
        saveCurrent(as: name)
        guard profiles.contains(name) else { return }
        statusText = "Added \(email)"
        ClaudeKeychain.invalidateCache()
        usageModel?.usage = nil
        Task { [weak self] in await self?.usageModel?.refresh(force: true) }
    }

    func delete(_ name: String) {
        for service in profileServices(name) { Keychain.delete(service: service) }
        profiles.removeAll { $0 == name }
        if active == name { active = nil }
        persist()
    }
}
