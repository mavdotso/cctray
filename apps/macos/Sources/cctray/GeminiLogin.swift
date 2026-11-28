import Foundation

enum GeminiCLI {
    static var isAgyInstalled: Bool {
        let fm = FileManager.default
        let candidates = [
            NSHomeDirectory() + "/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
        ]
        if candidates.contains(where: { fm.isExecutableFile(atPath: $0) }) { return true }
        return fm.fileExists(atPath: NSHomeDirectory() + "/.gemini/antigravity-cli")
    }

    static var executable: String {
        isAgyInstalled ? "agy" : "gemini"
    }

    static var preWarmCommand: String {
        isAgyInstalled ? "cd /tmp && agy -p \"hi\"" : "cd /tmp && gemini -p \"hi\""
    }
}

enum GeminiLoginError: Error, Equatable {
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

enum GeminiConfig {
    static var homeDir: String {
        if let custom = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"], !custom.isEmpty {
            return custom
        }
        return NSHomeDirectory()
    }

    static var dir: String { homeDir + "/.gemini" }
    static var accountsPath: String { dir + "/google_accounts.json" }
    static var settingsPath: String { dir + "/settings.json" }
    static var oauthCredsPath: String { dir + "/oauth_creds.json" }
    static var agyHooksPath: String { NSHomeDirectory() + "/.gemini/config/hooks.json" }
    static var agyBrainDir: String { NSHomeDirectory() + "/.gemini/antigravity-cli/brain" }

    enum ConfigError: Error { case notAnObject }

    static func readActiveEmail(fromAccountsJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = obj["active"] as? String, !active.isEmpty else { return nil }
        return active
    }

    static func replaceActiveEmail(inAccountsJSON data: Data, with email: String) throws -> Data {
        var obj: [String: Any]
        if data.isEmpty {
            obj = [:]
        } else {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw ConfigError.notAnObject }
            obj = parsed
        }
        if let previous = obj["active"] as? String, !previous.isEmpty, previous != email {
            var old = obj["old"] as? [String] ?? []
            if !old.contains(previous) { old.append(previous) }
            obj["old"] = old
        } else if obj["old"] == nil {
            obj["old"] = [String]()
        }
        obj["active"] = email
        return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    }

    static func emailFromIDToken(_ token: String?) -> String? {
        guard let token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 { base64 += String(repeating: "=", count: 4 - remainder) }
        guard let payload = Data(base64Encoded: base64),
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let email = obj["email"] as? String, !email.isEmpty else { return nil }
        return email
    }

    static func currentEmail() -> String? {
        if let raw = GeminiKeychain.readRaw(), let login = GeminiLogin(credentials: raw, email: nil),
           let email = login.email, !email.isEmpty {
            return email
        }
        if let data = FileManager.default.contents(atPath: accountsPath),
           let active = readActiveEmail(fromAccountsJSON: data) {
            return active
        }
        return nil
    }
}

struct GeminiLogin {
    enum Format: String {
        case antigravity
        case geminiCLI
    }

    struct Identity: Hashable {
        let email: String
    }

    static let goKeyringPrefix = "go-keyring-base64:"

    var credentials: [String: Any]
    let email: String?
    let format: Format
    var agyEnvelope: [String: Any]?

    init?(credentials data: Data, email: String?) {
        let decoded = Self.unwrapGoKeyring(data)
        guard let obj = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { return nil }
        if let tokenObj = obj["token"] as? [String: Any],
           (obj["id_token_email"] is String || obj["auth_method"] is String || tokenObj["access_token"] is String) {
            var out: [String: Any] = [:]
            if let v = tokenObj["access_token"] as? String ?? tokenObj["accessToken"] as? String {
                out["access_token"] = v
            }
            if let v = tokenObj["refresh_token"] as? String ?? tokenObj["refreshToken"] as? String {
                out["refresh_token"] = v
            }
            if let v = tokenObj["token_type"] as? String ?? tokenObj["tokenType"] as? String {
                out["token_type"] = v
            }
            if let v = tokenObj["scope"] as? String {
                out["scope"] = v
            }
            if let v = tokenObj["id_token"] as? String ?? tokenObj["idToken"] as? String {
                out["id_token"] = v
            }
            if let expiryStr = tokenObj["expiry"] as? String, let date = UsageParser.parseDate(expiryStr) {
                out["expiry_date"] = date.timeIntervalSince1970 * 1000
            } else if let v = Self.numberValue(tokenObj["expiresAt"] ?? tokenObj["expiry_date"]) {
                out["expiry_date"] = v
            }
            guard out["access_token"] != nil || out["refresh_token"] != nil else { return nil }
            let resolvedEmail = (obj["id_token_email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? email
                ?? GeminiConfig.emailFromIDToken(out["id_token"] as? String)
            self.credentials = out
            self.email = resolvedEmail
            self.format = .antigravity
            self.agyEnvelope = obj
            return
        }
        guard let normalized = Self.normalizeGeminiCLI(obj) else { return nil }
        self.credentials = normalized
        self.email = email ?? GeminiConfig.emailFromIDToken(normalized["id_token"] as? String)
        self.format = .geminiCLI
        self.agyEnvelope = nil
    }

    init(credentials: [String: Any], email: String?, format: Format = .geminiCLI, agyEnvelope: [String: Any]? = nil) {
        self.credentials = credentials
        self.email = email ?? GeminiConfig.emailFromIDToken(credentials["id_token"] as? String)
        self.format = format
        self.agyEnvelope = agyEnvelope
    }

    static func unwrapGoKeyring(_ data: Data) -> Data {
        if let str = String(data: data, encoding: .utf8),
           str.hasPrefix(goKeyringPrefix),
           let decoded = Data(base64Encoded: String(str.dropFirst(goKeyringPrefix.count))) {
            return decoded
        }
        return data
    }

    static func wrapGoKeyring(_ json: Data) -> Data {
        Data((goKeyringPrefix + json.base64EncodedString()).utf8)
    }

    private static func normalizeGeminiCLI(_ obj: [String: Any]) -> [String: Any]? {
        if let tokenObj = obj["token"] as? [String: Any] {
            var out: [String: Any] = [:]
            if let v = tokenObj["accessToken"] as? String ?? tokenObj["access_token"] as? String {
                out["access_token"] = v
            }
            if let v = tokenObj["refreshToken"] as? String ?? tokenObj["refresh_token"] as? String {
                out["refresh_token"] = v
            }
            if let v = tokenObj["tokenType"] as? String ?? tokenObj["token_type"] as? String {
                out["token_type"] = v
            }
            if let v = tokenObj["scope"] as? String {
                out["scope"] = v
            }
            if let v = tokenObj["idToken"] as? String ?? tokenObj["id_token"] as? String {
                out["id_token"] = v
            }
            if let v = numberValue(tokenObj["expiresAt"] ?? tokenObj["expiry_date"]) {
                out["expiry_date"] = v
            }
            if let v = obj["client_id"] as? String { out["client_id"] = v }
            if let v = obj["client_secret"] as? String { out["client_secret"] = v }
            guard out["access_token"] != nil || out["refresh_token"] != nil else { return nil }
            return out
        }
        var out = obj
        if out["access_token"] == nil, let v = obj["accessToken"] as? String { out["access_token"] = v }
        if out["refresh_token"] == nil, let v = obj["refreshToken"] as? String { out["refresh_token"] = v }
        if out["token_type"] == nil, let v = obj["tokenType"] as? String { out["token_type"] = v }
        if out["id_token"] == nil, let v = obj["idToken"] as? String { out["id_token"] = v }
        if out["expiry_date"] == nil, let v = numberValue(obj["expiresAt"]) { out["expiry_date"] = v }
        guard out["access_token"] is String || out["refresh_token"] is String else { return nil }
        return out
    }

    private static func numberValue(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let n = raw as? NSNumber { return n.doubleValue }
        return nil
    }

    var accessToken: String? { credentials["access_token"] as? String }
    var refreshToken: String? { credentials["refresh_token"] as? String }
    var idToken: String? { credentials["id_token"] as? String }
    var scope: String? { credentials["scope"] as? String }
    var tokenType: String { credentials["token_type"] as? String ?? "Bearer" }
    var expiresAt: Double { Self.numberValue(credentials["expiry_date"]) ?? 0 }
    var clientID: String? { credentials["client_id"] as? String }
    var clientSecret: String? { credentials["client_secret"] as? String }
    var isAntigravity: Bool { format == .antigravity }

    var data: Data? {
        if format == .antigravity {
            var root = agyEnvelope ?? [:]
            var tok = root["token"] as? [String: Any] ?? [:]
            if let accessToken { tok["access_token"] = accessToken }
            if let refreshToken { tok["refresh_token"] = refreshToken }
            tok["token_type"] = tokenType
            if expiresAt > 0 {
                let date = Date(timeIntervalSince1970: expiresAt / 1000)
                tok["expiry"] = Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
            }
            root["token"] = tok
            if let email { root["id_token_email"] = email }
            if root["auth_method"] == nil { root["auth_method"] = "consumer" }
            return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        }
        return try? JSONSerialization.data(withJSONObject: credentials, options: [.sortedKeys])
    }

    var agyKeychainPayload: Data? {
        guard let json = data else { return nil }
        return Self.wrapGoKeyring(json)
    }

    var identity: Identity? {
        guard let email, !email.isEmpty else { return nil }
        return Identity(email: email)
    }

    func keychainPayload(merging existing: Data? = nil, now: Date = Date()) -> Data? {
        var root = (existing.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
        var token = root["token"] as? [String: Any] ?? [:]
        if let accessToken { token["accessToken"] = accessToken }
        if let refreshToken { token["refreshToken"] = refreshToken }
        token["tokenType"] = tokenType
        if let scope { token["scope"] = scope }
        if expiresAt > 0 { token["expiresAt"] = expiresAt }
        if let idToken { token["idToken"] = idToken }
        root["serverName"] = root["serverName"] as? String ?? GeminiKeychain.cliAccount
        root["token"] = token
        root["updatedAt"] = Int64(now.timeIntervalSince1970 * 1000)
        return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    func matchesCredentials(_ other: GeminiLogin) -> Bool {
        accessToken == other.accessToken && refreshToken == other.refreshToken && expiresAt == other.expiresAt
    }

    func matchesAccount(_ other: GeminiLogin) -> Bool {
        guard let email, !email.isEmpty, let otherEmail = other.email, !otherEmail.isEmpty else { return false }
        return email.caseInsensitiveCompare(otherEmail) == .orderedSame
    }

    func matchesTokens(_ other: GeminiLogin) -> Bool {
        accessToken == other.accessToken && refreshToken == other.refreshToken
    }
}

enum GeminiOAuth {
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    static func installedCLICredentials() -> (clientID: String, clientSecret: String)? {
        let lookup = Shell.run("/bin/zsh", ["-ilc", "command -v gemini"])
        let binPath = lookup.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard lookup.status == 0, !binPath.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: binPath).resolvingSymlinksInPath().path
        let packageRoot = ((resolved as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        let candidates = [
            packageRoot + "/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            ((packageRoot as NSString).deletingLastPathComponent) + "/gemini-cli-core/dist/src/code_assist/oauth2.js",
        ]
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8),
                  let idMatch = text.firstMatch(of: #/OAUTH_CLIENT_ID\s*=\s*['"]([^'"]+)['"]/#),
                  let secretMatch = text.firstMatch(of: #/OAUTH_CLIENT_SECRET\s*=\s*['"]([^'"]+)['"]/#) else {
                continue
            }
            return (String(idMatch.1), String(secretMatch.1))
        }
        return nil
    }

    static func reason(code: Int, body: Data, retryAfter: String? = nil) -> GeminiLoginError {
        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"]
        let type = error as? String ?? (error as? [String: Any])?["status"] as? String
        if type == "invalid_grant" { return .signIn }
        return code == 429 ? .rateLimited(RetryAfter.date(retryAfter)) : .unavailable
    }

    static func refresh(_ login: GeminiLogin) async -> Result<GeminiLogin, GeminiLoginError> {
        if login.isAntigravity {
            return await refreshAntigravity(login)
        }
        guard let refreshToken = login.refreshToken, !refreshToken.isEmpty else {
            return .failure(.signIn)
        }
        let discovered = login.clientID == nil || login.clientSecret == nil ? installedCLICredentials() : nil
        guard let clientID = login.clientID ?? discovered?.clientID,
              let clientSecret = login.clientSecret ?? discovered?.clientSecret else {
            return .failure(.unavailable)
        }
        var req = URLRequest(url: tokenURL)
        req.timeoutInterval = 30
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "client_secret", value: clientSecret),
        ]
        req.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return .failure(.offline)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            return .failure(reason(code: code, body: data,
                                   retryAfter: (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")))
        }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = body["access_token"] as? String, !access.isEmpty
        else { return .failure(.unavailable) }
        var updated = login.credentials
        updated["access_token"] = access
        if let rotated = body["refresh_token"] as? String, !rotated.isEmpty {
            updated["refresh_token"] = rotated
        }
        if let seconds = body["expires_in"] as? Double {
            updated["expiry_date"] = (Date().timeIntervalSince1970 + seconds) * 1000
        } else if let seconds = (body["expires_in"] as? NSNumber)?.doubleValue {
            updated["expiry_date"] = (Date().timeIntervalSince1970 + seconds) * 1000
        } else {
            updated.removeValue(forKey: "expiry_date")
        }
        if let idToken = body["id_token"] as? String, !idToken.isEmpty {
            updated["id_token"] = idToken
        }
        if let scope = body["scope"] as? String, !scope.isEmpty {
            updated["scope"] = scope
        }
        if let tokenType = body["token_type"] as? String, !tokenType.isEmpty {
            updated["token_type"] = tokenType
        }
        return .success(GeminiLogin(credentials: updated, email: login.email, format: .geminiCLI))
    }

    /* Antigravity CLI manages its own OAuth refresh in Keychain; only refresh when this
       account is the live keychain login so inactive profiles never overwrite the active one. */
    private static func refreshAntigravity(_ login: GeminiLogin) async -> Result<GeminiLogin, GeminiLoginError> {
        await Task.detached { () -> Result<GeminiLogin, GeminiLoginError> in
            guard let liveRaw = GeminiKeychain.readAntigravityRaw(),
                  let live = GeminiLogin(credentials: liveRaw, email: nil),
                  live.matchesAccount(login) else {
                return .failure(.unavailable)
            }
            if live.expiresAt > Date().addingTimeInterval(300).timeIntervalSince1970 * 1000,
               live.accessToken != login.accessToken {
                return .success(live)
            }
            let result = Shell.run("/bin/zsh", ["-ilc", "agy models"])
            guard result.status == 0 else { return .failure(.unavailable) }
            guard let refreshedRaw = GeminiKeychain.readAntigravityRaw(),
                  let refreshed = GeminiLogin(credentials: refreshedRaw, email: nil),
                  refreshed.matchesAccount(login),
                  let token = refreshed.accessToken, !token.isEmpty else {
                return .failure(.unavailable)
            }
            return .success(refreshed)
        }.value
    }
}

enum GeminiKeychain {
    static let agyService = "gemini"
    static let agyAccount = "antigravity"
    static let cliService = "gemini-cli-oauth"
    static let cliAccount = "main-account"

    private static func readKeychainItem(service: String, account: String) -> Data? {
        let found = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"])
        let out = found.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if found.status == 0, !out.isEmpty {
            return Keychain.hexDecoded(out) ?? Data(out.utf8)
        }
        return Keychain.read(service: service)
    }

    private static func writeKeychainItem(service: String, account: String, data: Data) -> Bool {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-a", account,
                                               "-s", service, "-X", hex]).status == 0
    }

    static func readAntigravityRaw() -> Data? {
        let found = Shell.run("/usr/bin/security", ["find-generic-password", "-s", agyService, "-a", agyAccount, "-w"])
        let out = found.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard found.status == 0, !out.isEmpty else { return nil }
        return Keychain.hexDecoded(out) ?? Data(out.utf8)
    }

    static func readRaw() -> Data? {
        if let agyData = readAntigravityRaw(),
           let agyLogin = GeminiLogin(credentials: agyData, email: nil),
           agyLogin.data != nil {
            return agyData
        }
        let fileData = FileManager.default.contents(atPath: GeminiConfig.oauthCredsPath)
        let keychainData = readKeychainItem(service: cliService, account: cliAccount)
        let fileLogin = fileData.flatMap { GeminiLogin(credentials: $0, email: nil) }
        let keychainLogin = keychainData.flatMap { GeminiLogin(credentials: $0, email: nil) }
        switch (fileLogin, keychainLogin) {
        case (.some(let f), .some(let k)):
            return k.expiresAt > f.expiresAt ? k.data : f.data
        case (.some(let f), .none):
            return f.data
        case (.none, .some(let k)):
            return k.data
        case (.none, .none):
            return nil
        }
    }

    static func writeRaw(_ data: Data) -> Bool {
        guard let login = GeminiLogin(credentials: data, email: nil) else { return false }
        if login.isAntigravity {
            guard let payload = login.agyKeychainPayload else { return false }
            return writeKeychainItem(service: agyService, account: agyAccount, data: payload)
        }
        let fm = FileManager.default
        let filePath = GeminiConfig.oauthCredsPath
        let fileExists = fm.fileExists(atPath: filePath)
        let existingKeychain = readKeychainItem(service: cliService, account: cliAccount)
        var ok = true
        if fileExists || existingKeychain == nil {
            do {
                try fm.createDirectory(atPath: (filePath as NSString).deletingLastPathComponent,
                                       withIntermediateDirectories: true)
                var merged = (fm.contents(atPath: filePath)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
                for (key, value) in login.credentials { merged[key] = value }
                let mergedData = try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
                try mergedData.write(to: URL(fileURLWithPath: filePath), options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
            } catch {
                ok = false
            }
        }
        if existingKeychain != nil {
            if let payload = login.keychainPayload(merging: existingKeychain) {
                if !writeKeychainItem(service: cliService, account: cliAccount, data: payload) { ok = false }
            } else {
                ok = false
            }
        }
        return ok
    }

    static func clearLogin() -> Bool {
        let fm = FileManager.default
        let filePath = GeminiConfig.oauthCredsPath
        var ok = true
        if fm.fileExists(atPath: filePath) {
            do { try fm.removeItem(atPath: filePath) } catch { ok = false }
        }
        if !Keychain.delete(service: cliService) { ok = false }
        let deleteAgy = Shell.run("/usr/bin/security", ["delete-generic-password", "-s", agyService, "-a", agyAccount])
        if deleteAgy.status != 0 && deleteAgy.status != 44 { ok = false }
        return ok
    }
}

struct GeminiLoginStorage {
    enum Source: Hashable { case current, profile(String) }
    static let profileCache = ProfileCache()
    static let live = GeminiLoginStorage()

    var readCredentials: () -> Data? = GeminiKeychain.readRaw
    var writeCredentials: (Data) -> Bool = GeminiKeychain.writeRaw
    var clearCredentials: () -> Bool = GeminiKeychain.clearLogin
    var readConfiguration: () -> Data? = { FileManager.default.contents(atPath: GeminiConfig.accountsPath) }
    var writeConfiguration: (Data) -> Bool = { data in
        let path = GeminiConfig.accountsPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }
    var readProfile: (String) -> [String: Any]? = { name in
        guard let data = profileCache.read(name, load: { Keychain.read(service: "cctray-gemini-profile-\($0)") })
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    var writeProfile: (String, [String: Any]) -> Bool = { name, payload in
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        defer { profileCache.invalidate(name) }
        return Keychain.write(service: "cctray-gemini-profile-\(name)", data: data)
    }
    var deleteProfile: (String) -> Bool = { name in
        defer { profileCache.invalidate(name) }
        return Keychain.delete(service: "cctray-gemini-profile-\(name)")
    }

    func currentEmail() -> String? {
        if let raw = readCredentials(), let login = GeminiLogin(credentials: raw, email: nil),
           let email = login.email, !email.isEmpty {
            return email
        }
        if let config = readConfiguration(), let email = GeminiConfig.readActiveEmail(fromAccountsJSON: config) {
            return email
        }
        return nil
    }

    func read(_ source: Source) -> GeminiLogin? {
        switch source {
        case .current:
            guard let credentials = readCredentials() else { return nil }
            let configEmail = readConfiguration().flatMap(GeminiConfig.readActiveEmail)
            return GeminiLogin(credentials: credentials, email: configEmail)
        case .profile(let name):
            guard let payload = readProfile(name),
                  let encoded = payload["credentials"] as? String,
                  let credentials = Data(base64Encoded: encoded) else { return nil }
            let email = payload["email"] as? String
            return GeminiLogin(credentials: credentials, email: email)
        }
    }

    func write(_ source: Source, login: GeminiLogin) -> Bool {
        guard let data = login.data else { return false }
        switch source {
        case .current:
            return writeCredentials(data)
        case .profile(let name):
            guard var payload = readProfile(name) else { return false }
            payload["credentials"] = data.base64EncodedString()
            if let email = login.email { payload["email"] = email }
            return writeProfile(name, payload)
        }
    }

    enum ApplyError: Error {
        case unreadable, credentials, configuration, rollback
        var label: String {
            switch self {
            case .unreadable: "profile not readable"
            case .credentials: "keychain write error"
            case .configuration: "cannot write ~/.gemini/google_accounts.json"
            case .rollback: "could not restore the previous login. Choose its saved profile to retry."
            }
        }
    }

    func apply(_ name: String) -> Result<Void, ApplyError> {
        guard let login = read(.profile(name)), let credentials = login.data, let email = login.email
        else { return .failure(.unreadable) }
        if login.isAntigravity {
            guard writeCredentials(credentials) else { return .failure(.credentials) }
            return .success(())
        }
        let existingConfiguration = readConfiguration() ?? Data("{}".utf8)
        let previous = readCredentials()
        guard previous != nil || GeminiConfig.readActiveEmail(fromAccountsJSON: existingConfiguration) == nil
        else { return .failure(.credentials) }
        guard let configuration = try? GeminiConfig.replaceActiveEmail(
            inAccountsJSON: existingConfiguration, with: email)
        else { return .failure(.configuration) }
        guard writeCredentials(credentials) else { return .failure(.credentials) }
        guard writeConfiguration(configuration) else {
            let restored = previous.map(writeCredentials) ?? clearCredentials()
            return .failure(restored ? .configuration : .rollback)
        }
        return .success(())
    }

    static func sources() -> [Source] {
        [.current] + (UserDefaults.standard.stringArray(forKey: PrefKey.geminiProfiles) ?? []).map(Source.profile)
    }
}

@MainActor
final class GeminiLoginManager {
    typealias Source = GeminiLoginStorage.Source
    typealias Renewal = Result<GeminiLogin, GeminiLoginError>

    private let read: (Source) -> GeminiLogin?
    private let write: (Source, GeminiLogin) -> Bool
    private let sources: () -> [Source]
    private let refresh: (GeminiLogin) async -> Renewal
    private let now: () -> Date
    private struct CachedRenewal {
        var previous: [GeminiLogin]
        var login: GeminiLogin
    }
    private var pending: [String: Task<Renewal, Never>] = [:]
    private var renewalReaders: [String: Int] = [:]
    private var renewed: [String: CachedRenewal] = [:]
    private var failures: [String: (login: GeminiLogin, error: GeminiLoginError, retryAt: Date)] = [:]
    private var managedAccessTokens = Set<String>()
    private var recovery: [Source: GeminiLogin] = [:]

    init(read: @escaping (Source) -> GeminiLogin? = GeminiLoginStorage.live.read,
         write: @escaping (Source, GeminiLogin) -> Bool = GeminiLoginStorage.live.write,
         sources: @escaping () -> [Source] = GeminiLoginStorage.sources,
         now: @escaping () -> Date = Date.init,
         refresh: @escaping (GeminiLogin) async -> Renewal = GeminiOAuth.refresh) {
        self.read = read
        self.write = write
        self.sources = sources
        self.now = now
        self.refresh = refresh
    }

    private func renew(_ login: GeminiLogin) async -> Renewal {
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

    private func copies(of login: GeminiLogin, including source: Source) -> [(Source, GeminiLogin)] {
        var seen = Set<Source>()
        return (sources() + [source]).compactMap { candidate in
            guard seen.insert(candidate).inserted, let copy = read(candidate), login.matchesAccount(copy) else { return nil }
            return (candidate, copy)
        }
    }

    private func latest(_ login: GeminiLogin, among copies: [(Source, GeminiLogin)]) -> GeminiLogin {
        copies.reduce(login) { best, copy in
            let (location, candidate) = copy
            return candidate.expiresAt > best.expiresAt
                || (location == .current && candidate.expiresAt == best.expiresAt) ? candidate : best
        }
    }

    private func cachedRenewal(of original: GeminiLogin) -> GeminiLogin {
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

    private func save(_ login: GeminiLogin, replacing original: GeminiLogin, at source: Source) -> Bool {
        guard let current = read(source) else {
            guard sources().contains(source) else { recovery[source] = nil; return true }
            recovery[source] = original
            return false
        }
        guard current.matchesAccount(original), current.matchesCredentials(original), !current.matchesCredentials(login) else {
            recovery[source] = nil
            return true
        }
        let saved = write(source, login)
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

    func token(for source: Source, rejectedToken: String? = nil) async -> Result<String, GeminiLoginError> {
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

    func identity(for source: Source) -> GeminiLogin.Identity? { read(source)?.identity ?? recovery[source]?.identity }

    func isAntigravity(for source: Source) -> Bool {
        (read(source) ?? recovery[source])?.isAntigravity ?? GeminiCLI.isAgyInstalled
    }

    func isCurrent(_ source: Source, token: String) -> Bool { read(source)?.accessToken == token }

    func isManagedRenewal(_ credentials: Data) -> Bool {
        guard let login = GeminiLogin(credentials: credentials, email: nil),
              let token = login.accessToken else { return false }
        return managedAccessTokens.contains(token)
    }
}
