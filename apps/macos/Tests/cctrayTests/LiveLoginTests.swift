import Foundation
import Testing
@testable import cctray

@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CCTRAY_LIVE_LOGIN_TESTS"] == "1"), .serialized)
struct LiveLoginTests {
    private func preferences() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "com.mav.cctray"))
    }

    @Test func claudeRefreshPersistsAndSynchronizesProfiles() async throws {
        let names = try preferences().stringArray(forKey: PrefKey.accountProfiles) ?? []
        let sources: [ClaudeLoginStorage.Source] = [.current] + names.map { .profile($0) }
        let original = try #require(ClaudeLoginStorage.live.read(.current), "No current Claude login available")
        let manager = ClaudeLoginManager(sources: { sources })
        let token = try await manager.token(for: .current, rejectedToken: original.accessToken).get()
        let stored = try #require(ClaudeLoginStorage.live.read(.current))
        let persisted = stored.accessToken == token
        let identityUnchanged = stored.matchesAccount(original)
        let expiryAdvanced = stored.expiresAt > original.expiresAt
        #expect(persisted)
        #expect(identityUnchanged)
        #expect(expiryAdvanced)
        for source in sources.dropFirst() {
            guard let login = ClaudeLoginStorage.live.read(source), login.matchesAccount(original) else { continue }
            let profileSynchronized = login.matchesTokens(stored)
            #expect(profileSynchronized)
        }
    }

    @Test func claudeCurrentLoginCanReadLiveUsage() async throws {
        let login = try #require(ClaudeLoginStorage.live.read(.current), "No current Claude login available")
        let token = try #require(login.accessToken, "No current Claude access token available")
        _ = try await fetchUsage(token: token)
    }

    @Test func claudeCurrentLoginCanReadLiveProfile() async throws {
        let login = try #require(ClaudeLoginStorage.live.read(.current))
        let token = try #require(login.accessToken)
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (_, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        #expect(status == 200)
    }

    @Test func savedClaudeLoginsCanRenew() async throws {
        let names = try preferences().stringArray(forKey: PrefKey.accountProfiles) ?? []
        try #require(!names.isEmpty, "No saved Claude profiles available")
        let sources: [ClaudeLoginStorage.Source] = [.current] + names.map { .profile($0) }
        let manager = ClaudeLoginManager(sources: { sources })
        for (index, name) in names.enumerated() {
            if case .failure(let error) = await manager.token(for: .profile(name)) {
                Issue.record("Saved Claude profile \(index + 1) could not renew: \(error.label)")
            }
        }
    }

    @Test func codexAccountsRefreshAndReadLiveLimits() async throws {
        let data = try preferences().data(forKey: PrefKey.codexProfiles)
        let profiles = try data.map { try JSONDecoder().decode([CodexProfile].self, from: $0) } ?? []
        var homes = Set<String>()
        for profile in profiles where UUID(uuidString: profile.id) != nil && homes.insert(profile.home).inserted {
            _ = try await CodexLoginManager.shared.read(profile: profile).get()
        }
        if profiles.isEmpty { _ = try await CodexLoginManager.shared.read(profile: nil).get() }
        else { #expect(!homes.isEmpty) }
    }
}
