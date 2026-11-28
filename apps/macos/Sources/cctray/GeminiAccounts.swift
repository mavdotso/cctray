import Foundation

@MainActor
final class GeminiAccounts: ObservableObject {
    @Published var profiles: [String]
    @Published var active: String?
    @Published var statusText: String?
    @Published var currentEmail: String?
    @Published var isAddingAccount = false
    @Published var mismatch: String?
    @Published var usageByProfile: [String: String] = [:]
    @Published var unsavedLogin: String?
    private var lastProfileScan = Date.distantPast
    private let defaults: UserDefaults
    private let storage: GeminiLoginStorage
    private let isEnabled: () -> Bool
    private let launchLogin: () -> String?
    private let usageClient: GeminiUsageClient
    let logins: GeminiLoginManager
    let usageModel: GeminiUsageModel
    @Published private(set) var isSwitchingAccount = false
    @Published private(set) var needsLogin = Set<String>()
    private let loginPoll: Duration = .seconds(2)
    private let loginTimeout: Duration = .seconds(600)
    private var addTask: Task<Void, Never>?
    private var loginGeneration = 0

    init(defaults: UserDefaults = .standard, storage: GeminiLoginStorage = .live,
         isEnabled: @escaping () -> Bool = { CodingAgent.gemini.isEnabled },
         launchLogin: @escaping () -> String? = TerminalLauncher.geminiLogin,
         refresh: @escaping (GeminiLogin) async -> GeminiLoginManager.Renewal = GeminiOAuth.refresh,
         fetch: @escaping (String, String?, Bool) async throws -> (GeminiUsage, Data, String?) = {
             try await GeminiCodeAssist.fetchUsage(token: $0, projectID: $1, isAntigravity: $2)
         }) {
        self.defaults = defaults
        self.storage = storage
        self.isEnabled = isEnabled
        self.launchLogin = launchLogin
        profiles = defaults.stringArray(forKey: PrefKey.geminiProfiles) ?? []
        active = defaults.string(forKey: PrefKey.geminiActive)
        currentEmail = storage.currentEmail()
        let logins = GeminiLoginManager(read: storage.read, write: storage.write, sources: {
            [.current] + (defaults.stringArray(forKey: PrefKey.geminiProfiles) ?? []).map(GeminiLoginStorage.Source.profile)
        }, refresh: refresh)
        self.logins = logins
        let client = GeminiUsageClient(logins: logins, fetch: fetch)
        usageClient = client
        usageModel = GeminiUsageModel(client: client, defaults: defaults,
                                      currentAccount: storage.currentEmail, isEnabled: isEnabled)
    }

    func refreshIdentity() {
        let live = storage.currentEmail()
        if live != currentEmail { usageModel.accountChanged() }
        currentEmail = live
        mismatch = AccountStore.mismatchWarning(active: active,
                                                expected: active.flatMap { profileEmail($0) },
                                                live: currentEmail)
        unsavedLogin = loginToPreserve()
    }

    func maintainLogins() async {
        guard isEnabled(), !isAddingAccount, !isSwitchingAccount else { return }
        if defaults.string(forKey: PrefKey.geminiDeletedLogin) != storage.currentEmail(),
           let name = loginToPreserve() { saveCurrent(as: name) }
        refreshIdentity()
        if let live = storage.read(.current),
           let match = profiles.first(where: { name in
               storage.read(.profile(name)).map(live.matchesAccount) == true
           }), active != match {
            active = match
            persist()
            refreshIdentity()
        }
        let current = await logins.token(for: .current)
        let storageWarning = "Could not save the renewed login. Will retry."
        if case .failure(.storage) = current { statusText = storageWarning }
        else if statusText == storageWarning { statusText = nil }
        for name in profiles {
            guard isEnabled(), !isAddingAccount, !isSwitchingAccount else { return }
            _ = await profileToken(name)
        }
    }

    private func persist() {
        defaults.set(profiles, forKey: PrefKey.geminiProfiles)
        defaults.set(active, forKey: PrefKey.geminiActive)
    }

    func profileToken(_ name: String, rejectedToken: String? = nil) async -> Result<String, GeminiLoginError> {
        let result = await logins.token(for: .profile(name), rejectedToken: rejectedToken)
        guard profiles.contains(name) else { return .failure(.notSaved) }
        switch result {
        case .success: needsLogin.remove(name)
        case .failure(let error):
            if error == .signIn { needsLogin.insert(name) }
            usageByProfile[name] = error.label
        }
        return result
    }

    nonisolated static func usageSummary(_ usage: GeminiUsage) -> String {
        guard let top = usage.topLimit else { return "not available" }
        let pct = "\(Int(top.usedPercent))% \(top.shortLabel)"
        guard let reset = top.resetsAt else { return pct }
        return "\(pct) · \(UsageParser.countdown(to: reset))"
    }

    private func profileSummary(_ name: String) async -> String {
        let result = await usageClient.read(for: .profile(name))
        guard !Task.isCancelled, isEnabled(), profiles.contains(name) else { return "not available" }
        switch result {
        case .success(let (usage, _)):
            needsLogin.remove(name)
            return Self.usageSummary(usage)
        case .failure(let error):
            if error == .login(.signIn) { needsLogin.insert(name) }
            return error.label
        }
    }

    func refreshProfileUsage() async {
        guard Date().timeIntervalSince(lastProfileScan) >= 60 else { return }
        lastProfileScan = Date()
        let scannedProfiles = profiles
        let scannedActive = active
        var summaries: [String: String] = [:]
        if mismatch == nil, let active, let usage = usageModel.usage {
            summaries[active] = Self.usageSummary(usage)
        }
        for name in scannedProfiles where name != scannedActive {
            guard !Task.isCancelled, isEnabled() else { break }
            summaries[name] = await profileSummary(name)
        }
        guard !Task.isCancelled, isEnabled(), profiles == scannedProfiles, active == scannedActive else {
            lastProfileScan = .distantPast
            return
        }
        usageByProfile.merge(summaries) { _, new in new }
    }

    func profileEmail(_ name: String) -> String? {
        storage.readProfile(name)?["email"] as? String
    }

    @discardableResult
    func saveCurrent(as name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return false }
        guard let login = storage.read(.current),
              let creds = login.data,
              let email = login.email else {
            statusText = "Save failed: no Gemini CLI login found"
            return false
        }
        let replaced = profiles.contains(clean) ? profileEmail(clean) : nil
        let payload: [String: Any] = [
            "credentials": creds.base64EncodedString(),
            "email": email,
        ]
        guard storage.writeProfile(clean, payload) else {
            statusText = "Save failed: keychain write error"
            return false
        }
        if !profiles.contains(clean) { profiles.append(clean) }
        active = clean
        defaults.removeObject(forKey: PrefKey.geminiDeletedLogin)
        needsLogin.remove(clean)
        lastProfileScan = .distantPast
        refreshIdentity()
        statusText = replaced.flatMap { $0 == currentEmail ? nil : "Replaced \(clean) — was \($0)" }
        persist()
        return true
    }

    private func preserveCurrent() async -> Bool {
        guard storage.currentEmail() == nil || storage.read(.current) != nil else { return false }
        if let name = loginToPreserve() { saveCurrent(as: name) }
        guard loginToPreserve() == nil else { return false }
        return await logins.synchronizeCurrent()
    }

    func activate(_ name: String) async {
        guard !isAddingAccount, !isSwitchingAccount, profiles.contains(name) else { return }
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }
        statusText = "Switching to \(name)…"
        guard await preserveCurrent() else {
            statusText = "Switch failed: could not save the current login"
            return
        }
        let targetIsAgy = storage.read(.profile(name))?.isAntigravity == true
        if !targetIsAgy, case .failure(let error) = await profileToken(name) {
            statusText = "\(name): \(error.label)"
            return
        }
        guard await preserveCurrent() else {
            statusText = "Switch failed: could not save the current login"
            return
        }
        applyProfile(name)
    }

    private func applyProfile(_ name: String) {
        if case .failure(let error) = storage.apply(name) {
            statusText = "Switch failed: \(error.label)"
            return
        }
        active = name
        refreshIdentity()
        persist()
        usageModel.accountChanged()
        Task { [weak self] in
            let outcome = await self?.usageModel.refresh(force: true)
            guard self?.active == name else { return }
            if self?.usageModel.authFailed == true {
                self?.needsLogin.insert(name)
                self?.statusText = "\(name): sign in again"
            } else if outcome == .skipped {
                self?.statusText = "Switched. Usage is rate limited; it fills in when that clears."
            } else {
                self?.statusText = nil
            }
        }
    }

    private func finishLogin(_ name: String?, expected: String?, result: AccountStore.LoginWait) {
        guard result != .cancelled else { return }
        addTask = nil
        isAddingAccount = false
        guard case .found(let email) = result else {
            statusText = name.map { "No login found. \($0) still needs one." } ?? "No new login found. Nothing was saved."
            return
        }
        if let name, !AccountStore.mayOverwrite(profileEmail: expected, liveEmail: email) {
            statusText = "Logged in as \(email), not \(expected ?? name). Nothing saved."
            refreshIdentity()
            return
        }
        let target = name ?? profiles.first { profileEmail($0) == email }
            ?? AccountNaming.profileName(for: email, existing: profiles)
        guard saveCurrent(as: target) else { return }
        if name == nil { statusText = "Added \(email)" }
        usageModel.accountChanged()
        Task { [weak self] in await self?.usageModel.refresh(force: true) }
    }

    func loginToPreserve() -> String? {
        guard let current = storage.read(.current), let email = current.identity?.email,
              !profiles.contains(where: { storage.read(.profile($0)).map(current.matchesAccount) == true })
        else { return nil }
        return AccountNaming.profileName(for: email, existing: profiles)
    }

    func addAccount() async { await beginLogin(profile: nil) }

    func relogin(_ name: String) async {
        guard profiles.contains(name) else { return }
        await beginLogin(profile: name)
    }

    private func beginLogin(profile name: String?) async {
        guard !isAddingAccount, !isSwitchingAccount else { return }
        isAddingAccount = true
        loginGeneration += 1
        let generation = loginGeneration
        let preserved = await preserveCurrent()
        guard generation == loginGeneration else { return }
        guard preserved, !Task.isCancelled else {
            isAddingAccount = false
            statusText = "Could not save the current login"
            return
        }
        let expected = name.flatMap(profileEmail)
        let before = storage.currentEmail()
        let credentials = storage.readCredentials()
        if let error = launchLogin() {
            isAddingAccount = false
            statusText = error
            return
        }
        let loginHint = GeminiCLI.isAgyInstalled ? "sign in inside agy" : "run /auth in Gemini"
        statusText = name.map { "\($0) needs a login — \(loginHint) as \(expected ?? $0)." }
            ?? "Log in in the terminal — the profile saves itself."
        addTask = Task { [weak self] in
            guard let self else { return }
            let result = await waitForLogin(after: before, credentials: credentials)
            guard generation == loginGeneration else { return }
            finishLogin(name, expected: expected, result: result)
        }
    }

    func cancelAdd() {
        loginGeneration += 1
        addTask?.cancel()
        addTask = nil
        isAddingAccount = false
        statusText = nil
    }

    func waitForLogin(after before: String?, credentials: Data? = nil) async -> AccountStore.LoginWait {
        var waited = Duration.zero
        while waited < loginTimeout {
            try? await Task.sleep(for: loginPoll)
            if Task.isCancelled { return .cancelled }
            let (now, creds) = (storage.currentEmail(), storage.readCredentials())
            if let now {
                let renewedByApp = creds.map(logins.isManagedRenewal) ?? false
                if now != before || (credentials != nil && creds != credentials && !renewedByApp) {
                    return .found(now)
                }
            }
            waited += loginPoll
        }
        return .timedOut
    }

    func rename(_ old: String, to raw: String) async {
        guard !isSwitchingAccount, !isAddingAccount else { return }
        let clean: String
        switch AccountStore.validateRename(from: old, to: raw, existing: profiles) {
        case .rename(let name): clean = name
        case .reject(let message): statusText = message; return
        case .ignore: return
        }
        isSwitchingAccount = true
        defer { isSwitchingAccount = false }
        if case .failure(.storage) = await profileToken(old) {
            statusText = "Rename failed: keychain write error"
            return
        }
        renameSavedProfile(old, to: clean)
    }

    private func renameSavedProfile(_ old: String, to clean: String) {
        guard let index = profiles.firstIndex(of: old),
              let payload = storage.readProfile(old) else {
            statusText = "Rename failed: profile not readable"
            return
        }
        guard storage.writeProfile(clean, payload) else {
            statusText = "Rename failed: keychain write error"
            return
        }
        guard storage.deleteProfile(old) else {
            _ = storage.deleteProfile(clean)
            statusText = "Rename failed: cannot remove the old keychain entry"
            return
        }
        profiles[index] = clean
        if active == old { active = clean }
        usageByProfile[clean] = usageByProfile.removeValue(forKey: old)
        if needsLogin.remove(old) != nil { needsLogin.insert(clean) }
        refreshIdentity()
        statusText = nil
        persist()
    }

    func delete(_ name: String) {
        guard !isSwitchingAccount, !isAddingAccount else { return }
        let email = profileEmail(name)
        guard storage.deleteProfile(name) else {
            statusText = "Delete failed: cannot remove the saved login"
            return
        }
        if email == storage.currentEmail(), let email {
            defaults.set(email, forKey: PrefKey.geminiDeletedLogin)
        }
        profiles.removeAll { $0 == name }
        usageByProfile[name] = nil
        needsLogin.remove(name)
        if active == name { active = nil }
        refreshIdentity()
        persist()
    }
}
