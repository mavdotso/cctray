import Foundation
import Security

enum Keychain {
    static func read(service: String) -> Data? {
        let found = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service])
        guard found.status == 0 else { return nil }
        if account(in: found.out) == nil, let data = legacyRead(service: service) {
            _ = write(service: service, data: data)
            return data
        }
        let out = Shell.capture("/usr/bin/security",
                                ["find-generic-password", "-s", service, "-w"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }
        return hexDecoded(out) ?? Data(out.utf8)
    }

    private static func legacyRead(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
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

    static func delete(service: String) {
        _ = Shell.run("/usr/bin/security", ["delete-generic-password", "-s", service])
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
    enum RefreshResult { case ok([String: Any]), failed(String) }

    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!

    static func isExpired(_ oauth: [String: Any], now: Date = Date()) -> Bool {
        guard let ms = oauth["expiresAt"] as? Double else { return false }
        return Date(timeIntervalSince1970: ms / 1000) <= now
    }

    /* invalid_grant is unrecoverable: the saved refresh token is spent. */
    static func reason(code: Int, body: Data) -> String {
        let error = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["error"]
        let type = error as? String ?? (error as? [String: Any])?["type"] as? String
        if type == "invalid_grant" { return "sign in again" }
        return code == 429 ? "rate limited" : "not available"
    }

    /* The old refresh token stops working as soon as this succeeds. */
    static func refresh(_ oauth: [String: Any]) async -> RefreshResult {
        guard let refreshToken = oauth["refreshToken"] as? String else { return .failed("sign in again") }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            return .failed("offline")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { return .failed(reason(code: code, body: data)) }
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = body["access_token"] as? String
        else { return .failed("not available") }
        var updated = oauth
        updated["accessToken"] = access
        if let rotated = body["refresh_token"] as? String { updated["refreshToken"] = rotated }
        if let seconds = body["expires_in"] as? Double {
            updated["expiresAt"] = (Date().timeIntervalSince1970 + seconds) * 1000
        }
        return .ok(updated)
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
        invalidateCache()
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

    private static var cachedToken: String?

    static func accessToken() -> String? {
        if let cachedToken { return cachedToken }
        guard let data = readRaw(),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }
        cachedToken = token
        return token
    }

    static func invalidateCache() {
        cachedToken = nil
    }
}
