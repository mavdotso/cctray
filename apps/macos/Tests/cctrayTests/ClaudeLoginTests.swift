import Foundation
import Testing
@testable import cctray

@MainActor
private final class MemoryLogins {
    var logins: [ClaudeLoginStorage.Source: ClaudeLogin] = [:]
    var canWrite = true
    var canRead = true
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var refreshes = 0

    func login(_ token: String = "old", email: String = "one@example.test", expiresIn: Double = -1,
               refreshToken: String? = nil) throws -> ClaudeLogin {
        let data = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": token, "refreshToken": refreshToken ?? "refresh-" + token,
                              "expiresAt": now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000,
                              "scopes": ["user:profile"]],
            "unrelated": "keep me",
        ])
        return try #require(ClaudeLogin(credentials: data, account: ["emailAddress": email]))
    }

    func manager(refresh: @escaping (ClaudeLogin) async -> ClaudeLoginManager.Renewal) -> ClaudeLoginManager {
        ClaudeLoginManager(read: { self.canRead ? self.logins[$0] : nil }, write: { source, login in
            guard self.canWrite else { return false }
            self.logins[source] = login
            return true
        }, sources: { Array(self.logins.keys) }, now: { self.now }, refresh: { login in
            self.refreshes += 1
            return await refresh(login)
        })
    }
}

@MainActor
private final class RefreshGate {
    private var continuation: CheckedContinuation<ClaudeLoginManager.Renewal, Never>?
    private var start: CheckedContinuation<Void, Never>?
    var wasCancelled = false

    func refresh() async -> ClaudeLoginManager.Renewal {
        let result = await withCheckedContinuation { continuation in
            self.continuation = continuation
            start?.resume()
            start = nil
        }
        wasCancelled = Task.isCancelled
        return result
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { start = $0 }
    }

    func finish(_ result: ClaudeLoginManager.Renewal) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
struct ClaudeLoginTests {
    @Test func newerCliAccessTokenClearsRejectedCredentialWithUnchangedRefreshToken() async throws {
        let storage = MemoryLogins()
        storage.logins[.current] = try storage.login(expiresIn: 3600)
        let manager = storage.manager { _ in Issue.record("The new CLI login is already valid"); return .failure(.unavailable) }
        manager.reject(.current, token: "old")
        if case .failure(let error) = await manager.token(for: .current) { #expect(error == .signIn) }
        else { Issue.record("Rejected credentials require sign-in") }
        storage.logins[.current] = try storage.login("external", expiresIn: 7200, refreshToken: "refresh-old")

        #expect(try await manager.token(for: .current).get() == "external")
        #expect(storage.refreshes == 0)
    }

    @Test func unreadableStorageDuringConcurrentRenewalKeepsRotatedCredential() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        storage.logins = [.current: old, .profile("one"): old]
        let fresh = try storage.login("fresh", expiresIn: 3600)
        let gate = RefreshGate()
        var probe: Task<Result<String, ClaudeLoginError>, Never>?
        var manager: ClaudeLoginManager!
        manager = storage.manager { _ in
            let result = await gate.refresh()
            probe = Task { await manager.token(for: .profile("one")) }
            return result
        }
        let request = Task { await manager.token(for: .current) }
        await gate.waitUntilStarted()
        storage.canRead = false
        gate.finish(.success(fresh))
        _ = await request.value
        _ = await probe?.value
        storage.canRead = true

        #expect(try await manager.token(for: .current).get() == "fresh")
        #expect(storage.logins[.profile("one")]?.refreshToken == "refresh-fresh")
        #expect(storage.refreshes == 1)
    }

    @Test func cachedRotationSurvivesTemporaryUnreadableStorage() async throws {
        let storage = MemoryLogins()
        storage.logins[.current] = try storage.login()
        storage.canWrite = false
        let fresh = try storage.login("fresh", expiresIn: 3600)
        let manager = storage.manager { _ in .success(fresh) }
        _ = await manager.token(for: .current)
        storage.canRead = false

        if case .failure(let error) = await manager.token(for: .current) { #expect(error == .storage) }
        else { Issue.record("An unreadable pending save must remain a storage failure") }
        #expect(await manager.synchronizeCurrent() == false)
        storage.canRead = true
        storage.canWrite = true
        #expect(try await manager.token(for: .current).get() == "fresh")
        #expect(storage.refreshes == 1)
    }

    @Test func successiveUnchangedRefreshTokenRenewalsRecoverAllFailedSaves() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        storage.logins = [.current: old, .profile("one"): old]
        storage.canWrite = false
        let first = try storage.login("first", expiresIn: 3600, refreshToken: "refresh-old")
        let second = try storage.login("second", expiresIn: 7200, refreshToken: "refresh-old")
        let manager = storage.manager { _ in .success(storage.refreshes == 1 ? first : second) }

        _ = await manager.token(for: .current)
        storage.now = storage.now.addingTimeInterval(3601)
        _ = await manager.token(for: .current)
        storage.canWrite = true
        #expect(try await manager.token(for: .profile("one")).get() == "second")
        #expect(storage.logins[.current]?.accessToken == "second")
        #expect(storage.refreshes == 2)
    }

    @Test func refreshHonorsProviderRetryDeadline() async throws {
        let storage = MemoryLogins()
        storage.logins[.current] = try storage.login()
        let deadline = storage.now.addingTimeInterval(3600)
        let manager = storage.manager { _ in .failure(.rateLimited(deadline)) }

        _ = await manager.token(for: .current)
        storage.now = storage.now.addingTimeInterval(301)
        _ = await manager.token(for: .current)
        #expect(storage.refreshes == 1)
        storage.now = deadline.addingTimeInterval(1)
        _ = await manager.token(for: .current)
        #expect(storage.refreshes == 2)
    }

    @Test func newerCliCredentialsWithUnchangedRefreshTokenWinOverCachedRenewal() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        let fresh = try storage.login("fresh", expiresIn: 3600, refreshToken: "refresh-old")
        let external = try storage.login("external", expiresIn: 7200, refreshToken: "refresh-old")
        storage.logins = [.current: old, .profile("one"): old]
        let manager = storage.manager { _ in .success(fresh) }

        #expect(try await manager.token(for: .current).get() == "fresh")
        storage.logins[.current] = external
        #expect(try await manager.token(for: .profile("one")).get() == "external")
        #expect(storage.logins[.current]?.accessToken == "external")
        #expect(storage.logins[.profile("one")]?.accessToken == "external")
        #expect(storage.refreshes == 1)
    }

    @Test func unchangedRefreshTokenCanRenewAgainAfterExpiry() async throws {
        let storage = MemoryLogins()
        storage.logins[.current] = try storage.login()
        let first = try storage.login("first", expiresIn: 3600, refreshToken: "refresh-old")
        let second = try storage.login("second", expiresIn: 7200, refreshToken: "refresh-old")
        let manager = storage.manager { _ in .success(storage.refreshes == 1 ? first : second) }

        #expect(try await manager.token(for: .current).get() == "first")
        storage.now = storage.now.addingTimeInterval(3601)
        #expect(try await manager.token(for: .current).get() == "second")
        #expect(storage.refreshes == 2)
    }

    @Test func preservationMustFlushUnsavedRotatedCredentials() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        let fresh = try storage.login("fresh", expiresIn: 3600)
        storage.logins = [.current: old, .profile("one"): old]
        storage.canWrite = false
        let manager = storage.manager { _ in .success(fresh) }

        _ = await manager.token(for: .current)
        #expect(await manager.synchronizeCurrent() == false)
        storage.canWrite = true
        #expect(await manager.synchronizeCurrent())
        #expect(storage.logins[.profile("one")]?.refreshToken == "refresh-fresh")
        #expect(storage.refreshes == 1)
    }

    @Test func profileCreatedDuringRenewalReceivesRotatedCredential() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        storage.logins[.current] = old
        let fresh = try storage.login("fresh", expiresIn: 3600)
        let gate = RefreshGate()
        let manager = storage.manager { _ in await gate.refresh() }
        let request = Task { await manager.token(for: .current) }
        await gate.waitUntilStarted()
        storage.logins[.profile("new")] = old
        storage.logins[.current] = try storage.login("two", email: "two@example.test", expiresIn: 3600)
        gate.finish(.success(fresh))

        _ = await request.value
        #expect(storage.logins[.profile("new")]?.refreshToken == "refresh-fresh")
        #expect(storage.logins[.current]?.accessToken == "two")
    }

    @Test func renewsBeforeExpiryAndSavesBothCopies() async throws {
        let storage = MemoryLogins()
        let old = try storage.login(expiresIn: 240)
        let fresh = try storage.login("fresh", expiresIn: 3600)
        storage.logins = [.current: old, .profile("one"): old]
        let manager = storage.manager { _ in .success(fresh) }

        #expect(try await manager.token(for: .profile("one")).get() == "fresh")
        #expect(storage.logins[.current]?.accessToken == "fresh")
        #expect(storage.logins[.profile("one")]?.refreshToken == "refresh-fresh")
        #expect(storage.logins[.profile("one")]?.file["unrelated"] as? String == "keep me")
        #expect(storage.refreshes == 1)
    }

    @Test func inactiveRenewalDoesNotChangeSelectedAccount() async throws {
        let storage = MemoryLogins()
        let selected = try storage.login("selected", email: "two@example.test", expiresIn: 3600)
        storage.logins = [.current: selected, .profile("one"): try storage.login()]
        let fresh = try storage.login("fresh", expiresIn: 3600)
        let manager = storage.manager { _ in .success(fresh) }

        #expect(try await manager.token(for: .profile("one")).get() == "fresh")
        #expect(storage.logins[.current]?.accessToken == "selected")
    }

    @Test func concurrentReadersShareRefreshAndCancellationStillSaves() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        let fresh = try storage.login("fresh", expiresIn: 3600)
        storage.logins = [.current: old, .profile("one"): old]
        let gate = RefreshGate()
        let manager = storage.manager { _ in await gate.refresh() }
        let first = Task { await manager.token(for: .current) }
        await gate.waitUntilStarted()
        let second = Task { await manager.token(for: .profile("one")) }
        await Task.yield()
        first.cancel()
        gate.finish(.success(fresh))

        #expect(try await first.value.get() == "fresh")
        #expect(try await second.value.get() == "fresh")
        #expect(storage.refreshes == 1)
        #expect(!gate.wasCancelled)
        #expect(storage.logins[.profile("one")]?.refreshToken == "refresh-fresh")
    }

    @Test func failedWriteRetriesSavingWithoutSpendingRefreshTokenAgain() async throws {
        let storage = MemoryLogins()
        storage.logins[.profile("one")] = try storage.login()
        storage.canWrite = false
        let fresh = try storage.login("fresh", expiresIn: 3600)
        let manager = storage.manager { _ in .success(fresh) }

        if case .failure(let error) = await manager.token(for: .profile("one")) {
            #expect(error == .storage)
        } else { Issue.record("A failed save must be reported") }
        storage.canWrite = true
        #expect(try await manager.token(for: .profile("one")).get() == "fresh")
        #expect(storage.refreshes == 1)
    }

    @Test func changedLoginDuringRefreshIsNotOverwritten() async throws {
        let storage = MemoryLogins()
        storage.logins[.current] = try storage.login()
        let fresh = try storage.login("fresh", expiresIn: 7200)
        let external = try storage.login("external", expiresIn: 3600)
        let gate = RefreshGate()
        let manager = storage.manager { _ in await gate.refresh() }
        let request = Task { await manager.token(for: .current) }
        await gate.waitUntilStarted()
        storage.logins[.current] = external
        gate.finish(.success(fresh))

        #expect(try await request.value.get() == "external")
        #expect(storage.logins[.current]?.refreshToken == "refresh-external")
    }

    @Test func switchDuringRefreshSavesOriginalProfileOnly() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        let fresh = try storage.login("fresh", expiresIn: 3600)
        storage.logins = [.current: old, .profile("one"): old]
        let gate = RefreshGate()
        let manager = storage.manager { _ in await gate.refresh() }
        let request = Task { await manager.token(for: .current) }
        await gate.waitUntilStarted()
        storage.logins[.current] = try storage.login("two", email: "two@example.test", expiresIn: 3600)
        gate.finish(.success(fresh))

        if case .failure(let error) = await request.value { #expect(error == .changed) }
        else { Issue.record("The request belonged to the previous account") }
        #expect(storage.logins[.current]?.accessToken == "two")
        #expect(storage.logins[.profile("one")]?.accessToken == "fresh")
    }

    @Test func deletedProfileIsNotRecreatedByRefresh() async throws {
        let storage = MemoryLogins()
        storage.logins[.profile("one")] = try storage.login()
        let fresh = try storage.login("fresh", expiresIn: 3600)
        let gate = RefreshGate()
        let manager = storage.manager { _ in await gate.refresh() }
        let request = Task { await manager.token(for: .profile("one")) }
        await gate.waitUntilStarted()
        storage.logins[.profile("one")] = nil
        gate.finish(.success(fresh))

        if case .failure(let error) = await request.value { #expect(error == .changed) }
        else { Issue.record("A deleted profile must stay deleted") }
        #expect(storage.logins[.profile("one")] == nil)
    }

    @Test func failedInactiveRefreshDoesNotUseAnotherAccountsToken() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        storage.logins = [.current: old, .profile("one"): old]
        let gate = RefreshGate()
        let manager = storage.manager { _ in await gate.refresh() }
        let request = Task { await manager.token(for: .profile("one")) }
        await gate.waitUntilStarted()
        storage.logins[.current] = try storage.login("two", email: "two@example.test", expiresIn: 7200)
        gate.finish(.failure(.signIn))

        if case .failure(let error) = await request.value { #expect(error == .signIn) }
        else { Issue.record("An account cannot recover with another account's token") }
        #expect(storage.logins[.profile("one")]?.accessToken == "old")
    }

    @Test func cliRotationDuringFailedRefreshRepairsSavedProfile() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        let external = try storage.login("external", expiresIn: 7200)
        storage.logins = [.current: old, .profile("one"): old]
        let gate = RefreshGate()
        let manager = storage.manager { _ in await gate.refresh() }
        let request = Task { await manager.token(for: .profile("one")) }
        await gate.waitUntilStarted()
        storage.logins[.current] = external
        gate.finish(.failure(.signIn))

        #expect(try await request.value.get() == "external")
        #expect(storage.logins[.profile("one")]?.refreshToken == "refresh-external")
    }

    @Test(arguments: [ClaudeLoginError.offline, .rateLimited(nil), .signIn])
    func refreshFailuresKeepCredentialsAndBackOff(error: ClaudeLoginError) async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        storage.logins[.current] = old
        let manager = storage.manager { _ in .failure(error) }

        _ = await manager.token(for: .current)
        _ = await manager.token(for: .current)
        #expect(storage.refreshes == 1)
        #expect(storage.logins[.current]?.refreshToken == old.refreshToken)
        storage.now = storage.now.addingTimeInterval(301)
        _ = await manager.token(for: .current)
        #expect(storage.refreshes == (error == .signIn ? 1 : 2))
    }

    @Test func importsCliRotationAndKeepsNewerSavedCredentials() async throws {
        let storage = MemoryLogins()
        let old = try storage.login()
        let fresh = try storage.login("fresh", expiresIn: 3600)
        storage.logins = [.current: fresh, .profile("one"): old]
        let manager = storage.manager { _ in Issue.record("No refresh needed"); return .failure(.unavailable) }

        #expect(await manager.synchronizeCurrent())
        #expect(storage.logins[.profile("one")]?.accessToken == "fresh")
        storage.logins[.current] = old
        #expect(await manager.synchronizeCurrent())
        #expect(storage.logins[.current]?.accessToken == "fresh")
    }

    @Test func usage401RefreshesAndRetriesWithNewAccessToken() async throws {
        let storage = MemoryLogins()
        storage.logins[.current] = try storage.login(expiresIn: 3600)
        let fresh = try storage.login("fresh", expiresIn: 7200)
        let manager = storage.manager { _ in .success(fresh) }
        let data = Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        var requestedTokens: [String] = []
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ClaudeUsageClient(logins: manager, fetch: { token in
            requestedTokens.append(token)
            if token == "old" { throw UsageFetchError.http(401) }
            return (try UsageParser.parse(data), data)
        })
        let model = UsageModel(client: client, defaults: defaults, currentAccount: { "one@example.test" }, isEnabled: { true })

        #expect(await model.refresh(force: true) == .fetched)
        #expect(requestedTokens == ["old", "fresh"])
        #expect(model.usage?.fiveHour.utilization == 12)
        #expect(!model.authFailed)
        #expect(storage.refreshes == 1)
    }

    @Test func usageRateLimitKeepsCachedUsageAndStopsForcedRequests() async throws {
        let storage = MemoryLogins()
        storage.logins[.current] = try storage.login(expiresIn: 7200)
        let manager = storage.manager { _ in Issue.record("A usage limit must not rotate credentials"); return .failure(.unavailable) }
        let data = Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        var requests = 0
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = ClaudeUsageClient(logins: manager, now: { storage.now }, fetch: { _ in
            requests += 1
            if requests > 1 { throw UsageFetchError.rateLimited(storage.now.addingTimeInterval(3600)) }
            return (try UsageParser.parse(data), data)
        })
        let model = UsageModel(client: client, defaults: defaults, currentAccount: { "one@example.test" },
                               isEnabled: { true }, now: { storage.now })

        #expect(await model.refresh(force: true) == .fetched)
        #expect(await model.refresh(force: true) == .failed)
        storage.now = storage.now.addingTimeInterval(1200)
        #expect(await model.refresh(force: true) == .skipped)
        #expect(model.usage?.fiveHour.utilization == 12)
        #expect(model.isStale)
        #expect(!model.authFailed)
        #expect(requests == 2)
        #expect(storage.refreshes == 0)
        storage.now = storage.now.addingTimeInterval(2401)
        #expect(await model.refresh(force: true) == .failed)
        #expect(requests == 3)
    }

    @Test func retryAfterSupportsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(RetryAfter.date("3531", now: now) == now.addingTimeInterval(3531))
        #expect(RetryAfter.date("Wed, 21 Oct 2015 07:28:00 GMT") == Date(timeIntervalSince1970: 1_445_412_480))
        #expect(RetryAfter.date("invalid") == nil)
        #expect(RetryAfter.date("-1") == nil)
    }
}
