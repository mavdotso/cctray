import Foundation
import Testing
@testable import cctray

@MainActor
private final class ProfileStorage {
    var credentials: Data?
    var configuration: Data?
    var profiles: [String: [String: Any]] = [:]
    var canReadCredentials = true
    var canWriteCredentials = true
    var canWriteConfiguration = true
    var canWriteProfiles = true
    var cannotDelete = Set<String>()
    var credentialWrites = 0
    var clears = 0
    var launches = 0

    var adapter: ClaudeLoginStorage {
        ClaudeLoginStorage(readCredentials: { self.canReadCredentials ? self.credentials : nil },
                           writeCredentials: {
                               self.credentialWrites += 1
                               guard self.canWriteCredentials else { return false }
                               self.credentials = $0
                               return true
                           }, clearCredentials: {
                               self.clears += 1
                               self.credentials = nil
                               return true
                           }, readConfiguration: { self.configuration }, writeConfiguration: {
                               guard self.canWriteConfiguration else { return false }
                               self.configuration = $0
                               return true
                           }, readProfile: { self.profiles[$0] }, writeProfile: {
                               guard self.canWriteProfiles else { return false }
                               self.profiles[$0] = $1
                               return true
                           }, deleteProfile: {
                               guard !self.cannotDelete.contains($0) else { return false }
                               self.profiles[$0] = nil
                               return true
                           })
    }

    func login(_ token: String, email: String, expired: Bool = false) throws -> ClaudeLogin {
        let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
            "accessToken": token, "refreshToken": "refresh-" + token,
            "expiresAt": Date().addingTimeInterval(expired ? -60 : 7200).timeIntervalSince1970 * 1000,
        ]])
        return try #require(ClaudeLogin(credentials: data, account: ["emailAddress": email]))
    }

    func select(_ login: ClaudeLogin) throws {
        credentials = login.data
        configuration = try JSONSerialization.data(withJSONObject: ["oauthAccount": login.account, "unrelated": "keep"])
    }

    func save(_ login: ClaudeLogin, as name: String) throws {
        profiles[name] = ["credentials": try #require(login.data).base64EncodedString(), "oauthAccount": login.account]
    }

    func store(_ defaults: UserDefaults,
               refresh: @escaping (ClaudeLogin) async -> ClaudeLoginManager.Renewal = { _ in .failure(.unavailable) }) -> AccountStore {
        AccountStore(defaults: defaults, storage: adapter, isEnabled: { true }, launchLogin: {
            self.launches += 1
            return "Synthetic terminal"
        }, refresh: refresh, fetch: { _ in throw UsageFetchError.http(503) })
    }
}

@MainActor
private final class ProfileRefreshGate {
    private var continuation: CheckedContinuation<ClaudeLoginManager.Renewal, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func refresh() async -> ClaudeLoginManager.Renewal {
        await withCheckedContinuation {
            continuation = $0
            started?.resume()
            started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func finish(_ login: ClaudeLogin) {
        continuation?.resume(returning: .success(login))
        continuation = nil
    }
}

@MainActor
struct AccountStoreTests {
    @Test func failedRenewalSaveBlocksSwitchAddAndReloginUntilRecovered() async throws {
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProfileStorage()
        let old = try storage.login("one", email: "one@example.test", expired: true)
        let fresh = try storage.login("fresh", email: "one@example.test")
        try storage.select(old)
        try storage.save(old, as: "one")
        try storage.save(storage.login("two", email: "two@example.test"), as: "two")
        defaults.set(["one", "two"], forKey: PrefKey.accountProfiles)
        defaults.set("one", forKey: PrefKey.accountActive)
        storage.canWriteCredentials = false
        storage.canWriteProfiles = false
        var refreshes = 0
        let accounts = storage.store(defaults) { _ in refreshes += 1; return .success(fresh) }

        _ = await accounts.logins.token(for: .current)
        await accounts.activate("two")
        await accounts.addAccount()
        await accounts.relogin("one")
        #expect(accounts.active == "one")
        #expect(storage.adapter.currentEmail() == "one@example.test")
        #expect(storage.launches == 0)
        storage.canWriteCredentials = true
        storage.canWriteProfiles = true
        await accounts.activate("two")
        #expect(accounts.active == "two")
        #expect(storage.adapter.read(.profile("one"))?.accessToken == "fresh")
        #expect(storage.adapter.read(.current)?.accessToken == "two")
        #expect(refreshes == 1)
    }

    @Test func switchDrainsPendingRenewalAndPreservesRotatedProfile() async throws {
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProfileStorage()
        let old = try storage.login("one", email: "one@example.test", expired: true)
        try storage.select(old)
        try storage.save(old, as: "one")
        try storage.save(storage.login("two", email: "two@example.test"), as: "two")
        defaults.set(["one", "two"], forKey: PrefKey.accountProfiles)
        defaults.set("one", forKey: PrefKey.accountActive)
        let gate = ProfileRefreshGate()
        let accounts = storage.store(defaults) { _ in await gate.refresh() }
        let refresh = Task { await accounts.logins.token(for: .current) }
        await gate.waitUntilStarted()
        let switching = Task { await accounts.activate("two") }
        await Task.yield()
        #expect(accounts.isSwitchingAccount)
        #expect(storage.adapter.read(.current)?.accessToken == "one")
        gate.finish(try storage.login("fresh", email: "one@example.test"))

        _ = await refresh.value
        await switching.value
        #expect(storage.adapter.read(.profile("one"))?.accessToken == "fresh")
        #expect(storage.adapter.read(.current)?.accessToken == "two")
        #expect(accounts.active == "two")
    }

    @Test func cancelledLoginPreflightDoesNotLaunchTerminal() async throws {
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProfileStorage()
        let old = try storage.login("one", email: "one@example.test", expired: true)
        try storage.select(old)
        try storage.save(old, as: "one")
        defaults.set(["one"], forKey: PrefKey.accountProfiles)
        let gate = ProfileRefreshGate()
        let accounts = storage.store(defaults) { _ in await gate.refresh() }
        let refresh = Task { await accounts.logins.token(for: .current) }
        await gate.waitUntilStarted()
        let adding = Task { await accounts.addAccount() }
        await Task.yield()
        #expect(accounts.isAddingAccount)
        accounts.cancelAdd()
        gate.finish(try storage.login("fresh", email: "one@example.test"))

        _ = await refresh.value
        await adding.value
        #expect(storage.launches == 0)
        #expect(!accounts.isAddingAccount)
        #expect(storage.adapter.read(.profile("one"))?.accessToken == "fresh")
    }

    @Test func failedConfigurationWriteRestoresPreviousLoginAndSelection() async throws {
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProfileStorage()
        let old = try storage.login("one", email: "one@example.test")
        try storage.select(old)
        try storage.save(old, as: "one")
        try storage.save(storage.login("two", email: "two@example.test"), as: "two")
        defaults.set(["one", "two"], forKey: PrefKey.accountProfiles)
        defaults.set("one", forKey: PrefKey.accountActive)
        storage.canWriteConfiguration = false
        let accounts = storage.store(defaults)

        await accounts.activate("two")
        #expect(accounts.active == "one")
        #expect(storage.adapter.read(.current)?.accessToken == "one")
        #expect(storage.adapter.currentEmail() == "one@example.test")
        #expect(storage.credentialWrites == 2)
        #expect(storage.clears == 0)
    }

    @Test func failedFirstSelectionRemovesNewCredentials() throws {
        let storage = ProfileStorage()
        try storage.save(storage.login("two", email: "two@example.test"), as: "two")
        storage.canWriteConfiguration = false
        if case .success = storage.adapter.apply("two") { Issue.record("The configuration write must fail") }
        #expect(storage.credentials == nil)
        #expect(storage.clears == 1)
    }

    @Test(arguments: [false, true])
    func failedRenameRetainsOriginalProfile(failsDeletion: Bool) async throws {
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProfileStorage()
        let login = try storage.login("one", email: "one@example.test")
        try storage.select(login)
        try storage.save(login, as: "one")
        defaults.set(["one"], forKey: PrefKey.accountProfiles)
        defaults.set("one", forKey: PrefKey.accountActive)
        storage.canWriteProfiles = failsDeletion
        if failsDeletion { storage.cannotDelete.insert("one") }
        let accounts = storage.store(defaults)

        await accounts.rename("one", to: "new")
        #expect(accounts.profiles == ["one"])
        #expect(accounts.active == "one")
        #expect(storage.adapter.read(.profile("one"))?.accessToken == "one")
        #expect(storage.profiles["new"] == nil)
        #expect(defaults.stringArray(forKey: PrefKey.accountProfiles) == ["one"])
        #expect(accounts.statusText != nil)
    }

    @Test func corruptSavedCopyDoesNotPreventPreservingCurrentLogin() async throws {
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProfileStorage()
        let login = try storage.login("one", email: "one@example.test")
        try storage.select(login)
        storage.profiles["one"] = ["credentials": Data("{}".utf8).base64EncodedString(), "oauthAccount": login.account]
        try storage.save(storage.login("two", email: "two@example.test"), as: "two")
        defaults.set(["one", "two"], forKey: PrefKey.accountProfiles)
        let accounts = storage.store(defaults)

        await accounts.activate("two")
        #expect(accounts.active == "two")
        #expect(storage.adapter.read(.profile("one@example.test"))?.accessToken == "one")
        #expect(accounts.profiles.contains("one@example.test"))
    }

    @Test func deletedLiveProfileIsNotImportedAgainByMaintenance() async throws {
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProfileStorage()
        let login = try storage.login("one", email: "one@example.test")
        try storage.select(login)
        try storage.save(login, as: "one")
        defaults.set(["one"], forKey: PrefKey.accountProfiles)
        defaults.set("one", forKey: PrefKey.accountActive)
        let accounts = storage.store(defaults)

        accounts.delete("one")
        await accounts.maintainLogins()
        #expect(accounts.profiles.isEmpty)
        #expect(accounts.active == nil)
        #expect(storage.profiles.isEmpty)
        #expect(storage.adapter.read(.current)?.accessToken == "one")
    }

    @Test func unreadableCurrentCredentialsBlockReplacementAndNewLogin() async throws {
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = ProfileStorage()
        let old = try storage.login("one", email: "one@example.test")
        try storage.select(old)
        try storage.save(old, as: "one")
        try storage.save(storage.login("two", email: "two@example.test"), as: "two")
        defaults.set(["one", "two"], forKey: PrefKey.accountProfiles)
        defaults.set("one", forKey: PrefKey.accountActive)
        storage.canReadCredentials = false
        let accounts = storage.store(defaults)

        await accounts.activate("two")
        await accounts.addAccount()
        await accounts.relogin("one")
        #expect(accounts.active == "one")
        #expect(storage.credentials == old.data)
        #expect(storage.credentialWrites == 0)
        #expect(storage.launches == 0)
        #expect(!accounts.isAddingAccount)
        #expect(!accounts.isSwitchingAccount)
    }

    @Test func unreadableCurrentCredentialsMustNotBeClearedDuringRollback() throws {
        let storage = ProfileStorage()
        let old = try storage.login("one", email: "one@example.test")
        try storage.select(old)
        try storage.save(storage.login("two", email: "two@example.test"), as: "two")
        storage.canReadCredentials = false
        storage.canWriteConfiguration = false

        if case .success = storage.adapter.apply("two") { Issue.record("An unreadable login cannot be safely replaced") }
        #expect(storage.credentials == old.data)
        #expect(storage.credentialWrites == 0)
        #expect(storage.clears == 0)
    }
}
