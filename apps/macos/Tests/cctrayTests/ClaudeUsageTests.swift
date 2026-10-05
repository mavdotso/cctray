import Foundation
import Testing
@testable import cctray

@MainActor
private final class UsageGate {
    private var continuation: CheckedContinuation<Result<(Usage, Data), Error>, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func fetch() async throws -> (Usage, Data) {
        try await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }.get()
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func finish(_ result: Result<(Usage, Data), Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
struct ClaudeUsageTests {
    private func login(_ token: String, email: String = "one@example.test") throws -> ClaudeLogin {
        let credentials = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
            "accessToken": token, "refreshToken": "refresh-" + token,
            "expiresAt": Date().addingTimeInterval(7200).timeIntervalSince1970 * 1000,
        ]])
        return try #require(ClaudeLogin(credentials: credentials, account: ["emailAddress": email]))
    }

    @Test func currentAndSavedReadsShareUsageRequestDespiteCallerCancellation() async throws {
        let login = try login("one")
        let manager = ClaudeLoginManager(read: { _ in login }, write: { _, _ in true },
                                        sources: { [.current, .profile("one")] },
                                        refresh: { _ in Issue.record("No refresh expected"); return .failure(.unavailable) })
        let gate = UsageGate()
        var requests = 0
        let client = ClaudeUsageClient(logins: manager, fetch: { _ in requests += 1; return try await gate.fetch() })
        let current = Task { await client.read(for: .current) }
        await gate.waitUntilStarted()
        let profile = Task { await client.read(for: .profile("one")) }
        await Task.yield()
        current.cancel()
        let data = Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
        gate.finish(.success((try UsageParser.parse(data), data)))

        if case .failure(let error) = await current.value { #expect(error == .cancelled) }
        else { Issue.record("Cancelled display results must be dropped") }
        #expect(try await profile.value.get().0.fiveHour.utilization == 12)
        #expect(requests == 1)
    }

    @Test func retryDeadlineIsSharedByAccountButDoesNotBlockAnotherAccount() async throws {
        let one = try login("one")
        let two = try login("two", email: "two@example.test")
        let logins: [ClaudeLoginStorage.Source: ClaudeLogin] = [.current: one, .profile("one"): one, .profile("two"): two]
        let manager = ClaudeLoginManager(read: { logins[$0] }, write: { _, _ in true }, sources: { Array(logins.keys) },
                                        refresh: { _ in Issue.record("No refresh expected"); return .failure(.unavailable) })
        var requests = 0
        let client = ClaudeUsageClient(logins: manager, fetch: { token in
            requests += 1
            if token == "one" { throw UsageFetchError.rateLimited(Date().addingTimeInterval(3600)) }
            let data = Data(#"{"five_hour":{"utilization":12},"seven_day":{"utilization":34}}"#.utf8)
            return (try UsageParser.parse(data), data)
        })

        _ = await client.read(for: .current)
        if case .failure(let error) = await client.read(for: .profile("one")) { #expect(error == .retryLater) }
        else { Issue.record("The saved copy must respect the same account deadline") }
        #expect(try await client.read(for: .profile("two")).get().0.fiveHour.utilization == 12)
        #expect(requests == 2)
    }

    @Test func repeated401RequiresLoginWithoutRepeatedRefresh() async throws {
        var current = try login("old")
        let fresh = try login("fresh")
        var refreshes = 0
        let manager = ClaudeLoginManager(read: { _ in current }, write: { _, login in current = login; return true },
                                        sources: { [.current] }, refresh: { _ in refreshes += 1; return .success(fresh) })
        var requests = 0
        let client = ClaudeUsageClient(logins: manager, fetch: { _ in requests += 1; throw UsageFetchError.http(401) })

        for _ in 0..<2 {
            if case .failure(let error) = await client.read(for: .current) { #expect(error == .login(.signIn)) }
            else { Issue.record("A provider-rejected renewed login requires sign-in") }
        }
        #expect(refreshes == 1)
        #expect(requests == 2)
        #expect(current.accessToken == "fresh")
    }

    @Test func cancelledUsageCheckStillRemembersProviderRetryDeadline() async throws {
        let now = Date()
        let credentials = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [
            "accessToken": "synthetic", "refreshToken": "synthetic-refresh",
            "expiresAt": now.addingTimeInterval(7200).timeIntervalSince1970 * 1000,
        ]])
        let login = try #require(ClaudeLogin(credentials: credentials, account: ["emailAddress": "one@example.test"]))
        let manager = ClaudeLoginManager(read: { _ in login }, write: { _, _ in true }, sources: { [.current] },
                                        refresh: { _ in Issue.record("No refresh expected"); return .failure(.unavailable) })
        let gate = UsageGate()
        var requests = 0
        let deadline = now.addingTimeInterval(3600)
        let client = ClaudeUsageClient(logins: manager, now: { now }, fetch: { _ in
            requests += 1
            if requests == 1 { return try await gate.fetch() }
            throw UsageFetchError.rateLimited(deadline)
        })
        let request = Task { await client.read(for: .current) }
        await gate.waitUntilStarted()
        request.cancel()
        gate.finish(.failure(UsageFetchError.rateLimited(deadline)))

        if case .failure(let error) = await request.value { #expect(error == .cancelled) }
        else { Issue.record("Cancelled readers must discard the usage result") }
        if case .failure(let error) = await client.read(for: .current) { #expect(error == .retryLater) }
        else { Issue.record("The provider retry deadline must survive cancellation") }
        #expect(requests == 1)
    }
}
