import Foundation
import Testing
@testable import cctray

@MainActor
private final class CodexTestGate<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var start: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false

    func wait() async -> Value {
        let value = await withCheckedContinuation { continuation in
            self.continuation = continuation
            start?.resume()
            start = nil
        }
        wasCancelled = Task.isCancelled
        return value
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { start = $0 }
    }

    func finish(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

@MainActor
struct CodexLoginTests {
    private enum Failure: Error { case expected }

    private func profile(defaultHome: Bool = false) -> CodexProfile {
        CodexProfile(id: UUID().uuidString, name: "One", usesDefaultHome: defaultHome)
    }

    private func reading() -> CodexLoginManager.Reading {
        .success(("one@example.test", CodexLimits(rateLimits: .init(
            primary: .init(usedPercent: 23, windowDurationMins: 300, resetsAt: nil),
            secondary: nil), rateLimitsByLimitId: nil)))
    }

    @Test(arguments: [false, true])
    func concurrentReadersShareRefreshAndCancellationDoesNotInterruptSaving(defaultHome: Bool) async throws {
        let profile = profile(defaultHome: defaultHome)
        let gate = CodexTestGate<CodexLoginManager.Reading>()
        var reads = 0
        var saved = false
        let manager = CodexLoginManager(read: { _ in
            reads += 1
            let result = await gate.wait()
            saved = true
            return result
        }, logout: { _ in .success(()) })
        let first = Task { await manager.read(profile: profile) }
        await gate.waitUntilStarted()
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await manager.read(profile: defaultHome ? nil : profile)
        }
        while !secondStarted { await Task.yield() }
        first.cancel()
        gate.finish(reading())

        #expect(try await first.value.get().0 == "one@example.test")
        #expect(try await second.value.get().1.sessionWindow?.usedPercent == 23)
        #expect(reads == 1)
        #expect(saved)
        #expect(!gate.wasCancelled)
    }

    @Test(arguments: [false, true])
    func logoutDrainsRefreshAndBlocksNewReadsUntilItCompletes(defaultHome: Bool) async throws {
        let profile = profile(defaultHome: defaultHome)
        let readGate = CodexTestGate<CodexLoginManager.Reading>()
        let logoutGate = CodexTestGate<Result<Void, Error>>()
        var reads = 0
        var saved = false
        var logouts = 0
        let manager = CodexLoginManager(read: { _ in
            reads += 1
            if reads > 1 { return self.reading() }
            let result = await readGate.wait()
            saved = true
            return result
        }, logout: { _ in
            #expect(saved)
            logouts += 1
            return await logoutGate.wait()
        })
        let read = Task { await manager.read(profile: defaultHome ? nil : profile) }
        await readGate.waitUntilStarted()
        var removalStarted = false
        let removal = Task {
            removalStarted = true
            return await manager.logout(profile: profile)
        }
        while !removalStarted { await Task.yield() }
        #expect(logouts == 0)
        if case .success = await manager.read(profile: profile) {
            Issue.record("Reads must not start while logout waits for refresh")
        }
        readGate.finish(reading())
        _ = try await read.value.get()
        await logoutGate.waitUntilStarted()
        if case .success = await manager.read(profile: profile) {
            Issue.record("Reads must not start while logout is running")
        }
        #expect(reads == 1)
        _ = try await manager.read(profile: self.profile()).get()
        #expect(reads == 2)
        logoutGate.finish(.success(()))
        try await removal.value.get()

        #expect(logouts == 1)
        _ = try await manager.read(profile: profile).get()
        #expect(reads == 3)
    }

    @Test func duplicateLogoutSharesOneOperationAndCancelledCallerDoesNotResumeReads() async throws {
        let profile = profile()
        let gate = CodexTestGate<Result<Void, Error>>()
        var logouts = 0
        var reads = 0
        let manager = CodexLoginManager(read: { _ in reads += 1; return self.reading() }, logout: { _ in
            logouts += 1
            return await gate.wait()
        })
        let first = Task { await manager.logout(profile: profile) }
        await gate.waitUntilStarted()
        var secondStarted = false
        let second = Task {
            secondStarted = true
            return await manager.logout(profile: profile)
        }
        while !secondStarted { await Task.yield() }
        first.cancel()
        if case .success = await manager.read(profile: profile) {
            Issue.record("A cancelled logout caller must not release the profile")
        }
        #expect(reads == 0)
        #expect(logouts == 1)
        gate.finish(.success(()))
        try await first.value.get()
        try await second.value.get()

        #expect(!gate.wasCancelled)
        #expect(logouts == 1)
    }

    @Test func failedLogoutRestoresReadAvailability() async throws {
        let profile = profile()
        let manager = CodexLoginManager(read: { _ in self.reading() }, logout: { _ in .failure(Failure.expected) })
        if case .success = await manager.logout(profile: profile) { Issue.record("The logout failure must be returned") }
        #expect(try await manager.read(profile: profile).get().0 == "one@example.test")
    }

    @Test(arguments: [false, true])
    func deletingDefaultProfileBlocksConflictingChangesAndReimport(succeeds: Bool) async throws {
        let suite = "cctray-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = profile(defaultHome: true)
        defaults.set(try JSONEncoder().encode([profile]), forKey: PrefKey.codexProfiles)
        defaults.set(profile.id, forKey: PrefKey.codexSelectedProfile)
        let gate = CodexTestGate<Result<Void, Error>>()
        var launches = 0
        var logouts = 0
        let manager = CodexLoginManager(read: { _ in self.reading() }, logout: { _ in
            logouts += 1
            return await gate.wait()
        })
        let accounts = CodexAccounts(logins: manager, defaults: defaults, launchLogin: { _ in
            launches += 1
            return nil
        })
        accounts.delete(profile.id)
        #expect(accounts.isDeletingAccount)
        await gate.waitUntilStarted()
        accounts.delete(profile.id)
        accounts.relogin(profile.id)
        accounts.add(name: profile.name)
        accounts.rename(profile.id, to: "Renamed")
        accounts.selected = ""
        accounts.captureCurrentLogin(email: "one@example.test")

        #expect(accounts.selected.isEmpty)
        #expect(accounts.profiles == [profile])
        #expect(accounts.error == nil)
        #expect(launches == 0)
        #expect(logouts == 1)
        gate.finish(succeeds ? .success(()) : .failure(Failure.expected))
        while accounts.isDeletingAccount { await Task.yield() }
        accounts.captureCurrentLogin(email: "one@example.test")

        #expect(defaults.bool(forKey: PrefKey.codexDefaultProfileDeleted) == succeeds)
        if succeeds {
            #expect(accounts.profiles.isEmpty)
            #expect(accounts.selected.isEmpty)
        } else {
            #expect(accounts.profiles == [profile])
            #expect(accounts.selected == profile.id)
            #expect(accounts.error != nil)
            accounts.relogin(profile.id)
            #expect(launches == 1)
        }
    }
}
