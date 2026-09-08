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
    @Published var mismatch: String?
    @Published var usageByProfile: [String: String] = [:]
    @Published var unsavedLogin: String?
    private var lastProfileScan = Date.distantPast
    weak var usageModel: UsageModel?
    private let loginPoll: Duration = .seconds(2)
    private let loginTimeout: Duration = .seconds(600)
    private var addTask: Task<Void, Never>?

    static func mismatchWarning(active: String?, expected: String?, live: String?) -> String? {
        guard let active, let expected, let live, expected != live else { return nil }
        return "Logged in as \(live) — \(active) is \(expected)"
    }

    func refreshIdentity() {
        currentEmail = ClaudeConfig.currentEmail()
        mismatch = Self.mismatchWarning(active: active,
                                        expected: active.flatMap { profileEmail($0) },
                                        live: currentEmail)
        unsavedLogin = loginToPreserve()
    }

    private func persist() {
        UserDefaults.standard.set(profiles, forKey: PrefKey.accountProfiles)
        UserDefaults.standard.set(active, forKey: PrefKey.accountActive)
    }

    nonisolated func profileServices(_ name: String) -> [String] {
        ["cctray-profile-\(name)", "CCTray-profile-\(name)"]
    }

    /* Every failure string here is shown to the user as the profile's menu label. */
    enum ProfileToken { case usable(String), failed(String) }

    /* Stores the rotated token before using it, so a keychain failure loses nothing. */
    nonisolated func profileToken(_ name: String) async -> ProfileToken {
        guard var payload = readProfile(name),
              let encoded = payload["credentials"] as? String,
              let creds = Data(base64Encoded: encoded),
              var file = try? JSONSerialization.jsonObject(with: creds) as? [String: Any],
              let oauth = file["claudeAiOauth"] as? [String: Any]
        else { return .failed("not saved") }
        if !ClaudeOAuth.isExpired(oauth) {
            guard let token = oauth["accessToken"] as? String else { return .failed("sign in again") }
            return .usable(token)
        }
        let fresh: [String: Any]
        switch await ClaudeOAuth.refresh(oauth) {
        case .ok(let updated): fresh = updated
        case .failed(let why): return .failed(why)
        }
        guard let token = fresh["accessToken"] as? String else { return .failed("not available") }
        file["claudeAiOauth"] = fresh
        guard let encodedFile = try? JSONSerialization.data(withJSONObject: file) else {
            return .failed("not available")
        }
        payload["credentials"] = encodedFile.base64EncodedString()
        guard writeProfile(name, payload: payload) else { return .failed("keychain error") }
        return .usable(token)
    }

    nonisolated static func usageSummary(_ usage: Usage, now: Date = Date()) -> String {
        let top = usage.topLimit
        let pct = "\(Int(top.percent))% \(top.label)"
        guard let reset = top.resetsAt else { return pct }
        return "\(pct) · \(UsageParser.countdown(to: reset, from: now))"
    }

    /* macOS truncates a long menu item in the middle, which eats into the number.
       Clip the name instead so the usage always survives. */
    nonisolated static func menuLabel(_ name: String, summary: String?) -> String {
        guard let summary else { return name }
        let limit = 10
        let short = name.count > limit ? name.prefix(limit - 1) + "…" : name[...]
        return "\(short)  \(summary)"
    }

    nonisolated private func profileSummary(_ name: String) async -> String {
        switch await profileToken(name) {
        case .failed(let why): return why
        case .usable(let token):
            do { return Self.usageSummary(try await fetchUsage(token: token).0) }
            catch UsageFetchError.http(401) { return "sign in again" }
            catch UsageFetchError.http(429) { return "rate limited" }
            catch { return "not available" }
        }
    }

    func refreshProfileUsage() async {
        guard Date().timeIntervalSince(lastProfileScan) >= 60 else { return }
        lastProfileScan = Date()
        var summaries: [String: String] = [:]
        /* While the live login is the wrong account, its usage is not this profile's. */
        if mismatch == nil, let active, let usage = usageModel?.usage {
            summaries[active] = Self.usageSummary(usage)
        }
        await withTaskGroup(of: (String, String).self) { group in
            for name in profiles where name != active {
                group.addTask { [self] in (name, await profileSummary(name)) }
            }
            for await pair in group { summaries[pair.0] = pair.1 }
        }
        /* Closing the menu cancels this, which fails every request in flight.
           Those are not real failures, so drop them and let the next open retry. */
        guard !Task.isCancelled else {
            lastProfileScan = .distantPast
            return
        }
        usageByProfile.merge(summaries) { _, new in new }
    }

    nonisolated func readProfile(_ name: String) -> [String: Any]? {
        guard let data = profileServices(name).lazy
            .compactMap({ Keychain.read(service: $0) }).first else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func profileEmail(_ name: String) -> String? {
        (readProfile(name)?["oauthAccount"] as? [String: Any])?["emailAddress"] as? String
    }

    private nonisolated func writeProfile(_ name: String, payload: [String: Any]) -> Bool {
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
        lastProfileScan = .distantPast
        refreshIdentity()
        statusText = replaced.flatMap { $0 == currentEmail ? nil : "Replaced \(clean) — was \($0)" }
        persist()
    }

    static func mayOverwrite(profileEmail: String?, liveEmail: String?) -> Bool {
        guard let profileEmail, let liveEmail else { return false }
        return profileEmail == liveEmail
    }

    /* The CLI rotates the live tokens while a profile is active. Fold them back
       into that profile before switching away, or its copy is left behind. */
    private func syncActiveProfile() {
        guard let name = active, profiles.contains(name),
              let creds = ClaudeKeychain.readRaw(),
              let configData = FileManager.default.contents(atPath: ClaudeConfig.path),
              let account = ClaudeConfig.readOauthAccount(fromClaudeJSON: configData),
              Self.mayOverwrite(profileEmail: profileEmail(name),
                                liveEmail: account["emailAddress"] as? String)
        else { return }
        _ = writeProfile(name, payload: [
            "credentials": creds.base64EncodedString(),
            "oauthAccount": account,
        ])
    }

    func activate(_ name: String) {
        syncActiveProfile()
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
                self?.relogin(name)
            } else if outcome == .skipped {
                self?.statusText = "Switched. Usage is rate limited; it fills in when that clears."
            } else {
                self?.statusText = nil
            }
        }
    }

    /* A dead profile is useless until you log in again, so start that for you. */
    func relogin(_ name: String) {
        guard addTask == nil else {
            statusText = "\(name) needs a login. Finish the one in progress first."
            return
        }
        let expected = profileEmail(name)
        let before = ClaudeConfig.currentEmail()
        if let error = TerminalLauncher.newLogin() {
            statusText = error
            return
        }
        isAddingAccount = true
        statusText = "\(name) needs a login — log in as \(expected ?? name)."
        addTask = Task { [weak self] in
            guard let result = await self?.waitForLogin(after: before) else { return }
            self?.finishRelogin(name, expected: expected, result: result)
        }
    }

    private func finishRelogin(_ name: String, expected: String?, result: LoginWait) {
        guard result != .cancelled else { return }
        addTask = nil
        isAddingAccount = false
        guard case .found(let email) = result else {
            statusText = "No login found. \(name) still needs one."
            return
        }
        guard Self.mayOverwrite(profileEmail: expected, liveEmail: email) else {
            statusText = "Logged in as \(email), not \(expected ?? name). Nothing saved."
            refreshIdentity()
            return
        }
        saveCurrent(as: name)
        ClaudeKeychain.invalidateCache()
        usageModel?.usage = nil
        Task { [weak self] in await self?.usageModel?.refresh(force: true) }
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

    enum RenameOutcome: Equatable { case rename(String), reject(String), ignore }

    static func validateRename(from old: String, to raw: String, existing: [String]) -> RenameOutcome {
        let clean = raw.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != old, existing.contains(old) else { return .ignore }
        guard !existing.contains(clean) else { return .reject("Rename failed: \(clean) already exists") }
        return .rename(clean)
    }

    func rename(_ old: String, to raw: String) {
        let clean: String
        switch Self.validateRename(from: old, to: raw, existing: profiles) {
        case .rename(let name): clean = name
        case .reject(let message): statusText = message; return
        case .ignore: return
        }
        guard let index = profiles.firstIndex(of: old),
              let payload = readProfile(old)
        else {
            statusText = "Rename failed: profile not readable"
            return
        }
        guard writeProfile(clean, payload: payload) else {
            statusText = "Rename failed: keychain write error"
            return
        }
        for service in profileServices(old) { Keychain.delete(service: service) }
        profiles[index] = clean
        if active == old { active = clean }
        usageByProfile[clean] = usageByProfile.removeValue(forKey: old)
        refreshIdentity()
        statusText = nil
        persist()
    }

    func delete(_ name: String) {
        for service in profileServices(name) { Keychain.delete(service: service) }
        profiles.removeAll { $0 == name }
        usageByProfile[name] = nil
        if active == name { active = nil }
        refreshIdentity()
        persist()
    }
}
