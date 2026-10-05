import Foundation

enum Keychain {
    static func read(service: String) -> Data? {
        let found = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service])
        guard found.status == 0 else { return nil }
        let out = Shell.capture("/usr/bin/security",
                                ["find-generic-password", "-s", service, "-w"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }
        return hexDecoded(out) ?? Data(out.utf8)
    }

    private static func account(in attributes: String) -> String? {
        attributes.firstMatch(of: #/"acct"<blob>="([^"]*)"/#).map { String($0.1) }
    }

    static func write(service: String, data: Data) -> Bool {
        let found = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service])
        let account = account(in: found.out)
        if found.status == 0, account == nil { delete(service: service) }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        return Shell.run("/usr/bin/security", ["add-generic-password", "-U", "-a", account ?? NSUserName(),
                                               "-s", service, "-X", hex]).status == 0
    }

    @discardableResult
    static func delete(service: String) -> Bool {
        let result = Shell.run("/usr/bin/security", ["delete-generic-password", "-s", service])
        return result.status == 0 || result.status == 44
    }

    static func hexDecoded(_ s: String) -> Data? {
        guard s.count > 1, s.count % 2 == 0, s.allSatisfy(\.isHexDigit) else { return nil }
        var out = Data(capacity: s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let next = s.index(i, offsetBy: 2)
            guard let byte = UInt8(s[i..<next], radix: 16) else { return nil }
            out.append(byte)
            i = next
        }
        return out
    }
}

enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!

    /* invalid_grant is unrecoverable: the saved refresh token is spent. */
    static func reason(code: Int, body: Data, retryAfter: String? = nil) -> ClaudeLoginError {
        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"]
        let type = error as? String ?? (error as? [String: Any])?["type"] as? String
        if type == "invalid_grant" { return .signIn }
        return code == 429 ? .rateLimited(RetryAfter.date(retryAfter)) : .unavailable
    }

    static func refresh(_ login: ClaudeLogin) async -> Result<ClaudeLogin, ClaudeLoginError> {
        let oauth = login.oauth
        guard let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            return .failure(.signIn)
        }
        var req = URLRequest(url: tokenURL)
        req.timeoutInterval = 30
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty {
            payload["scope"] = scopes.joined(separator: " ")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
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
        var updated = oauth
        updated["accessToken"] = access
        if let rotated = body["refresh_token"] as? String, !rotated.isEmpty { updated["refreshToken"] = rotated }
        if let seconds = body["expires_in"] as? Double {
            updated["expiresAt"] = (Date().timeIntervalSince1970 + seconds) * 1000
        } else {
            updated.removeValue(forKey: "expiresAt")
        }
        if let scope = body["scope"] as? String {
            updated["scopes"] = scope.split(whereSeparator: \.isWhitespace).map(String.init)
        }
        var renewed = login
        renewed.file["claudeAiOauth"] = updated
        return .success(renewed)
    }
}

enum ClaudeKeychain {
    static let service = "Claude Code-credentials"
    static let filePath = NSHomeDirectory() + "/.claude/.credentials.json"

    private static func hasLogin(_ data: Data) -> Bool {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return obj?["claudeAiOauth"] != nil
    }

    static func readRaw() -> Data? {
        if let data = FileManager.default.contents(atPath: filePath), hasLogin(data) {
            return data
        }
        guard let data = Keychain.read(service: service), hasLogin(data) else { return nil }
        return data
    }

    static func replaceLogin(inFile current: Data, with incoming: Data) -> Data? {
        guard let new = try? JSONSerialization.jsonObject(with: incoming) as? [String: Any],
              let login = new["claudeAiOauth"] else { return nil }
        var merged = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any] ?? [:]
        merged["claudeAiOauth"] = login
        return try? JSONSerialization.data(withJSONObject: merged)
    }

    static func writeRaw(_ data: Data) -> Bool {
        let fm = FileManager.default
        guard let current = fm.contents(atPath: filePath) else {
            return Keychain.write(service: service, data: data)
        }
        guard let merged = replaceLogin(inFile: current, with: data),
              (try? merged.write(to: URL(fileURLWithPath: filePath), options: .atomic)) != nil
        else { return false }
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
        return true
    }

    static func clearLogin() -> Bool {
        guard let data = FileManager.default.contents(atPath: filePath) else { return Keychain.delete(service: service) }
        guard var file = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        file.removeValue(forKey: "claudeAiOauth")
        guard let updated = try? JSONSerialization.data(withJSONObject: file),
              (try? updated.write(to: URL(fileURLWithPath: filePath), options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath)
        return true
    }

}
