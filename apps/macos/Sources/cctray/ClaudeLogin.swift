import Foundation

enum ClaudeLoginError: Error, Equatable {
    case notSaved, signIn, offline, unavailable, storage, changed
    case rateLimited(Date?)

    var label: String {
        switch self {
        case .notSaved: "not saved"
        case .signIn: "sign in again"
        case .offline: "offline"
        case .rateLimited: "rate limited"
        case .unavailable: "not available"
        case .storage: "keychain error"
        case .changed: "login changed; try again"
        }
    }
}

struct ClaudeLogin {
    struct Identity: Hashable {
        let email: String
        let account: String?
        let organization: String?
    }
    var file: [String: Any]
    let account: [String: Any]

    init?(credentials: Data, account: [String: Any]) {
        guard let file = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any],
              file["claudeAiOauth"] is [String: Any] else { return nil }
        self.file = file
        self.account = account
    }

    var oauth: [String: Any] { file["claudeAiOauth"] as? [String: Any] ?? [:] }
    var accessToken: String? { oauth["accessToken"] as? String }
    var refreshToken: String? { oauth["refreshToken"] as? String }
    var expiresAt: Double { oauth["expiresAt"] as? Double ?? 0 }
    var data: Data? { try? JSONSerialization.data(withJSONObject: file) }
    var identity: Identity? {
        guard let email = account["emailAddress"] as? String else { return nil }
        return Identity(email: email, account: account["accountUuid"] as? String,
                        organization: account["organizationUuid"] as? String)
    }

    func matchesCredentials(_ other: ClaudeLogin) -> Bool {
        NSDictionary(dictionary: oauth).isEqual(to: other.oauth)
    }

    func matchesAccount(_ other: ClaudeLogin) -> Bool {
        guard let email = account["emailAddress"] as? String,
              email == other.account["emailAddress"] as? String else { return false }
        for key in ["accountUuid", "organizationUuid"] {
            if let value = account[key] as? String, let otherValue = other.account[key] as? String,
               value != otherValue { return false }
        }
        return true
    }

    func matchesTokens(_ other: ClaudeLogin) -> Bool {
        accessToken == other.accessToken && refreshToken == other.refreshToken
    }
}

struct ClaudeLoginStorage {
    enum Source: Hashable { case current, profile(String) }
    static let live = ClaudeLoginStorage()
    var readCredentials: () -> Data? = ClaudeKeychain.readRaw
    var writeCredentials: (Data) -> Bool = ClaudeKeychain.writeRaw
    var clearCredentials: () -> Bool = ClaudeKeychain.clearLogin
    var readConfiguration: () -> Data? = { FileManager.default.contents(atPath: ClaudeConfig.path) }
    var writeConfiguration: (Data) -> Bool = {
        (try? $0.write(to: URL(fileURLWithPath: ClaudeConfig.path), options: .atomic)) != nil
    }
    var readProfile: (String) -> [String: Any]? = { name in
        guard let data = Keychain.read(service: "cctray-profile-\(name)") else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    var writeProfile: (String, [String: Any]) -> Bool = { name, payload in
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return Keychain.write(service: "cctray-profile-\(name)", data: data)
    }
    var deleteProfile: (String) -> Bool = { Keychain.delete(service: "cctray-profile-\($0)") }

    func currentEmail() -> String? {
        readConfiguration().flatMap(ClaudeConfig.readOauthAccount)?["emailAddress"] as? String
    }

    func read(_ source: Source) -> ClaudeLogin? {
        switch source {
        case .current:
            guard let credentials = readCredentials(), let config = readConfiguration(),
                  let account = ClaudeConfig.readOauthAccount(fromClaudeJSON: config) else { return nil }
            return ClaudeLogin(credentials: credentials, account: account)
        case .profile(let name):
            guard let payload = readProfile(name), let encoded = payload["credentials"] as? String,
                  let credentials = Data(base64Encoded: encoded),
                  let account = payload["oauthAccount"] as? [String: Any] else { return nil }
            return ClaudeLogin(credentials: credentials, account: account)
        }
    }

    func write(_ source: Source, login: ClaudeLogin) -> Bool {
        guard let data = login.data else { return false }
        switch source {
        case .current: return writeCredentials(data)
        case .profile(let name):
            guard var payload = readProfile(name) else { return false }
            payload["credentials"] = data.base64EncodedString()
            return writeProfile(name, payload)
        }
    }

    enum ApplyError: Error {
        case unreadable, credentials, configuration, rollback
        var label: String {
            switch self {
            case .unreadable: "profile not readable"
            case .credentials: "keychain write error"
            case .configuration: "cannot write ~/.claude.json"
            case .rollback: "could not restore the previous login. Choose its saved profile to retry."
            }
        }
    }

    func apply(_ name: String) -> Result<Void, ApplyError> {
        guard let login = read(.profile(name)), let credentials = login.data else { return .failure(.unreadable) }
        let existingConfiguration = readConfiguration() ?? Data("{}".utf8)
        let previous = readCredentials()
        guard previous != nil || ClaudeConfig.readOauthAccount(fromClaudeJSON: existingConfiguration) == nil
        else { return .failure(.credentials) }
        guard let configuration = try? ClaudeConfig.replaceOauthAccount(
            inClaudeJSON: existingConfiguration, with: login.account)
        else { return .failure(.configuration) }
        guard writeCredentials(credentials) else { return .failure(.credentials) }
        guard writeConfiguration(configuration) else {
            let restored = previous.map(writeCredentials) ?? clearCredentials()
            return .failure(restored ? .configuration : .rollback)
        }
        return .success(())
    }

    static func sources() -> [Source] {
        [.current] + (UserDefaults.standard.stringArray(forKey: PrefKey.accountProfiles) ?? []).map(Source.profile)
    }
}

@MainActor
final class ClaudeLoginManager {
    typealias Source = ClaudeLoginStorage.Source
    typealias Renewal = Result<ClaudeLogin, ClaudeLoginError>

    private let read: (Source) -> ClaudeLogin?
    private let write: (Source, ClaudeLogin) -> Bool
    private let sources: () -> [Source]
    private let refresh: (ClaudeLogin) async -> Renewal
    private let now: () -> Date
    private struct CachedRenewal {
        var previous: [ClaudeLogin]
        var login: ClaudeLogin
    }
    private var pending: [String: Task<Renewal, Never>] = [:]
    private var renewalReaders: [String: Int] = [:]
    private var renewed: [String: CachedRenewal] = [:]
    private var failures: [String: (login: ClaudeLogin, error: ClaudeLoginError, retryAt: Date)] = [:]
    private var managedAccessTokens = Set<String>()
    private var recovery: [Source: ClaudeLogin] = [:]

    init(read: @escaping (Source) -> ClaudeLogin? = ClaudeLoginStorage.live.read,
         write: @escaping (Source, ClaudeLogin) -> Bool = ClaudeLoginStorage.live.write,
         sources: @escaping () -> [Source] = ClaudeLoginStorage.sources,
         now: @escaping () -> Date = Date.init,
         refresh: @escaping (ClaudeLogin) async -> Renewal = ClaudeOAuth.refresh) {
        self.read = read
        self.write = write
        self.sources = sources
        self.now = now
        self.refresh = refresh
    }

    /* Refresh tokens rotate. Share the request and finish saving even when a
       menu task is cancelled; keep its result if a Keychain write needs retrying. */
    private func renew(_ login: ClaudeLogin) async -> Renewal {
        guard let key = login.refreshToken, !key.isEmpty else { return .failure(.signIn) }
        if let cached = renewed[key], cached.previous.contains(where: login.matchesCredentials) {
            return .success(cached.login)
        }
        if let failure = failures[key], now() < failure.retryAt,
           failure.error != .signIn || failure.login.matchesCredentials(login) { return .failure(failure.error) }
        if let task = pending[key] { return await task.value }
        let task = Task {
            let result = await refresh(login)
            switch result {
            case .success(let fresh):
                var previous = renewed[key]?.previous ?? []
                if !previous.contains(where: login.matchesCredentials) { previous.append(login) }
                renewed[key] = CachedRenewal(previous: previous, login: fresh)
                failures[key] = nil
                if let token = fresh.accessToken { managedAccessTokens.insert(token) }
            case .failure(let error):
                var retryAt = now().addingTimeInterval(300)
                if error == .signIn { retryAt = .distantFuture }
                if case .rateLimited(let deadline) = error, let deadline { retryAt = max(retryAt, deadline) }
                failures[key] = (login, error, retryAt)
            }
            pending[key] = nil
            return result
        }
        pending[key] = task
        return await task.value
    }

    private func copies(of login: ClaudeLogin, including source: Source) -> [(Source, ClaudeLogin)] {
        var seen = Set<Source>()
        return (sources() + [source]).compactMap { candidate in
            guard seen.insert(candidate).inserted, let copy = read(candidate), login.matchesAccount(copy) else { return nil }
            return (candidate, copy)
        }
    }

    private func latest(_ login: ClaudeLogin, among copies: [(Source, ClaudeLogin)]) -> ClaudeLogin {
        copies.reduce(login) { best, copy in
            let (location, candidate) = copy
            return candidate.expiresAt > best.expiresAt
                || (location == .current && candidate.expiresAt == best.expiresAt) ? candidate : best
        }
    }

    private func cachedRenewal(of original: ClaudeLogin) -> ClaudeLogin {
        var login = original
        var followed = Set<String>()
        while let key = login.refreshToken, followed.insert(key).inserted, let cached = renewed[key],
              cached.login.matchesAccount(login), cached.previous.contains(where: login.matchesCredentials) {
            login = cached.login
        }
        return login
    }

    private func pruneHistory() {
        let locations = Set(sources())
        let stored = locations.compactMap(read)
        recovery = recovery.filter { locations.contains($0.key) }
        let copies = stored + recovery.values
        let references = Set(copies.compactMap(\.refreshToken)).union(pending.keys).union(renewalReaders.keys)
        renewed = renewed.filter { references.contains($0.key) }.mapValues { cached in
            CachedRenewal(previous: cached.previous.filter { old in
                old.refreshToken.flatMap { renewalReaders[$0] } != nil || copies.contains(where: old.matchesCredentials)
            },
                          login: cachedRenewal(of: cached.login))
        }.filter { !$0.value.previous.isEmpty }
        let liveKeys = references.union(renewed.values.compactMap { $0.login.refreshToken })
        failures = failures.filter { liveKeys.contains($0.key) }
        managedAccessTokens.formIntersection(Set(stored.compactMap(\.accessToken)).union(renewed.values.compactMap { $0.login.accessToken }))
    }

    private func save(_ login: ClaudeLogin, replacing original: ClaudeLogin, at source: Source) -> Bool {
        guard let current = read(source) else {
            guard sources().contains(source) else { recovery[source] = nil; return true }
            recovery[source] = original
            return false
        }
        guard current.matchesAccount(original), current.matchesCredentials(original), !current.matchesCredentials(login) else {
            recovery[source] = nil
            return true
        }
        var merged = current
        merged.file["claudeAiOauth"] = login.oauth
        let saved = write(source, merged)
        recovery[source] = saved ? nil : original
        return saved
    }

    @discardableResult
    func synchronizeCurrent() async -> Bool {
        defer { pruneHistory() }
        guard let original = read(.current) else { return recovery[.current] == nil && pending.isEmpty }
        let candidate = cachedRenewal(of: latest(original, among: copies(of: original, including: .current)))
        if let key = candidate.refreshToken { _ = await pending[key]?.value }
        guard let login = read(.current), login.matchesAccount(original) else { return false }
        let snapshots = copies(of: login, including: .current)
        let fresh = cachedRenewal(of: latest(login, among: snapshots))
        var saved = true
        for (location, snapshot) in snapshots {
            if !save(fresh, replacing: snapshot, at: location) { saved = false }
        }
        return saved
    }

    func token(for source: Source, rejectedToken: String? = nil) async -> Result<String, ClaudeLoginError> {
        var renewalKey: String?
        defer {
            if let key = renewalKey, let readers = renewalReaders[key] {
                renewalReaders[key] = readers > 1 ? readers - 1 : nil
            }
            pruneHistory()
        }
        guard let original = read(source) else { return .failure(recovery[source] == nil ? .notSaved : .storage) }
        var snapshots = copies(of: original, including: source)
        var login = cachedRenewal(of: latest(original, among: snapshots))
        if let key = login.refreshToken, let failure = failures[key],
           failure.error == .signIn, failure.login.matchesCredentials(login) { return .failure(.signIn) }
        let mustRefresh = rejectedToken != nil && rejectedToken == login.accessToken
        let expiresSoon = login.expiresAt > 0 && login.expiresAt <= now().addingTimeInterval(300).timeIntervalSince1970 * 1000
        if mustRefresh || expiresSoon || login.accessToken?.isEmpty != false || login.refreshToken.flatMap({ pending[$0] }) != nil {
            renewalKey = login.refreshToken
            if let key = renewalKey { renewalReaders[key, default: 0] += 1 }
            switch await renew(login) {
            case .success(let fresh): login = fresh
            case .failure(let error):
                guard read(source)?.matchesAccount(original) == true else { return .failure(.changed) }
                let recovered = latest(original, among: copies(of: original, including: source))
                guard !recovered.matchesTokens(login), recovered.accessToken?.isEmpty == false,
                      recovered.expiresAt == 0 || recovered.expiresAt > now().timeIntervalSince1970 * 1000 else {
                    return .failure(error)
                }
                login = recovered
            }
        }
        let captured = Set(snapshots.map(\.0))
        snapshots += copies(of: original, including: source).filter { candidate in
            !captured.contains(candidate.0) && snapshots.contains { $0.1.matchesCredentials(candidate.1) }
        }
        var saved = true
        for (location, snapshot) in snapshots {
            if !save(login, replacing: snapshot, at: location) { saved = false }
        }
        guard saved else { return .failure(.storage) }
        guard let current = read(source), current.matchesAccount(original) else { return .failure(.changed) }
        guard let token = current.accessToken, !token.isEmpty else { return .failure(.signIn) }
        return .success(token)
    }

    func reject(_ source: Source, token: String) {
        guard let login = read(source), login.accessToken == token, let key = login.refreshToken else { return }
        failures[key] = (login, .signIn, .distantFuture)
    }

    func identity(for source: Source) -> ClaudeLogin.Identity? { read(source)?.identity ?? recovery[source]?.identity }

    func isCurrent(_ source: Source, token: String) -> Bool { read(source)?.accessToken == token }

    func isManagedRenewal(_ credentials: Data) -> Bool {
        guard let file = try? JSONSerialization.jsonObject(with: credentials) as? [String: Any],
              let oauth = file["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return false }
        return managedAccessTokens.contains(token)
    }
}
