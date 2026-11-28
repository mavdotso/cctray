import Foundation
import Testing
@testable import cctray

@MainActor
private final class GeminiRefreshGate {
    private var continuation: CheckedContinuation<GeminiLoginManager.Renewal, Never>?
    private var start: CheckedContinuation<Void, Never>?
    var wasCancelled = false

    func refresh() async -> GeminiLoginManager.Renewal {
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

    func finish(_ result: GeminiLoginManager.Renewal) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class GeminiUsageGate {
    private var continuation: CheckedContinuation<Result<(GeminiUsage, Data, String?), Error>, Never>?
    private var started: CheckedContinuation<Void, Never>?

    func fetch() async throws -> (GeminiUsage, Data, String?) {
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

    func finish(_ result: Result<(GeminiUsage, Data, String?), Error>) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}

@MainActor
private final class GeminiMemoryStorage {
    var credentials: Data?
    var configuration: Data?
    var profiles: [String: [String: Any]] = [:]
    var canWriteCredentials = true
    var canWriteConfiguration = true
    var canWriteProfiles = true
    var cannotDelete = Set<String>()
    var credentialWrites = 0
    var clears = 0
    var launches = 0

    var adapter: GeminiLoginStorage {
        GeminiLoginStorage(
            readCredentials: { self.credentials },
            writeCredentials: {
                self.credentialWrites += 1
                guard self.canWriteCredentials else { return false }
                self.credentials = $0
                return true
            },
            clearCredentials: {
                self.clears += 1
                self.credentials = nil
                return true
            },
            readConfiguration: { self.configuration },
            writeConfiguration: {
                guard self.canWriteConfiguration else { return false }
                self.configuration = $0
                return true
            },
            readProfile: { self.profiles[$0] },
            writeProfile: {
                guard self.canWriteProfiles else { return false }
                self.profiles[$0] = $1
                return true
            },
            deleteProfile: {
                guard !self.cannotDelete.contains($0) else { return false }
                self.profiles[$0] = nil
                return true
            }
        )
    }

    func login(_ token: String, email: String, expired: Bool = false) throws -> GeminiLogin {
        let data = try JSONSerialization.data(withJSONObject: [
            "access_token": token,
            "refresh_token": "refresh-" + token,
            "expiry_date": Date().addingTimeInterval(expired ? -60 : 7200).timeIntervalSince1970 * 1000,
        ])
        return try #require(GeminiLogin(credentials: data, email: email))
    }

    func select(_ login: GeminiLogin) throws {
        credentials = login.data
        configuration = try JSONSerialization.data(withJSONObject: ["active": login.email ?? "", "old": []])
    }

    func save(_ login: GeminiLogin, as name: String) throws {
        profiles[name] = [
            "credentials": try #require(login.data).base64EncodedString(),
            "email": try #require(login.email),
        ]
    }

    func store(_ defaults: UserDefaults,
               refresh: @escaping (GeminiLogin) async -> GeminiLoginManager.Renewal = { _ in .failure(.unavailable) }) -> GeminiAccounts {
        GeminiAccounts(defaults: defaults, storage: adapter, isEnabled: { true }, launchLogin: {
            self.launches += 1
            return "Synthetic terminal"
        }, refresh: refresh, fetch: { _, _, _ in throw UsageFetchError.http(503) })
    }
}

struct GeminiUsageParsingTests {
    @Test func parsesAntigravitySummaryGroupsIntoSessionAndWeekWindows() throws {
        let json = """
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {"bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 0.88, "resetTime": "2026-12-05T04:24:04Z"},
                {"bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.52, "resetTime": "2026-11-28T09:24:04Z"}
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {"bucketId": "3p-5h", "window": "5h", "remainingFraction": 1.0}
              ]
            }
          ]
        }
        """
        let usage = try GeminiUsageParser.parse(Data(json.utf8))
        #expect(usage.windows.map(\.label) == ["Session", "Week"])
        #expect(Int(try #require(usage.sessionWindow).usedPercent.rounded()) == 48)
        #expect(Int(try #require(usage.weeklyWindow).usedPercent.rounded()) == 12)
        #expect(usage.topLimit?.shortLabel == "5h")
        #expect(usage.preWarmReset == usage.sessionWindow?.resetsAt)
    }

    @Test func parsesQuotaBucketsGroupedByTierAndPicksBindingLimit() throws {
        let json = """
        {
          "buckets": [
            {"modelId": "gemini-3-pro-preview", "tokenType": "REQUESTS", "remainingFraction": 0.76, "resetTime": "2026-11-29T10:00:00Z"},
            {"modelId": "gemini-2.5-pro", "tokenType": "REQUESTS", "remainingFraction": 0.90, "resetTime": "2026-11-29T12:00:00Z"},
            {"modelId": "gemini-2.5-flash", "tokenType": "REQUESTS", "remainingFraction": 0.45, "resetTime": "2026-11-29T08:00:00.500Z"},
            {"modelId": "gemini-2.5-flash-lite", "tokenType": "REQUESTS", "remainingFraction": 0.95, "resetTime": "2026-11-29T09:00:00Z"}
          ]
        }
        """
        let usage = try GeminiUsageParser.parse(Data(json.utf8))
        #expect(usage.windows.map(\.label) == ["Pro", "Flash", "Lite"])
        #expect(Int(try #require(usage.proWindow).usedPercent.rounded()) == 24)
        #expect(Int(try #require(usage.flashWindow).usedPercent.rounded()) == 55)
        #expect(Int(try #require(usage.liteWindow).usedPercent.rounded()) == 5)
        #expect(usage.topLimit?.label == "Flash")
        #expect(usage.preWarmReset == usage.proWindow?.resetsAt)
    }

    @Test func fallsBackToGenericWindowForUnknownModels() throws {
        let json = #"{"buckets":[{"modelId":"gemini-experimental","remainingFraction":0.3,"resetTime":"2026-11-29T10:00:00Z"}]}"#
        let usage = try GeminiUsageParser.parse(Data(json.utf8))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].label == "Usage")
        #expect(Int(usage.windows[0].usedPercent.rounded()) == 70)
    }

    @Test func parsesProjectIDFromStringAndObjectShapes() throws {
        let stringJSON = Data(#"{"cloudaicompanionProject":"proj-123"}"#.utf8)
        let objectJSON = Data(#"{"cloudaicompanionProject":{"id":"proj-456"}}"#.utf8)
        #expect(GeminiCodeAssist.parseProjectID(from: stringJSON) == "proj-123")
        #expect(GeminiCodeAssist.parseProjectID(from: objectJSON) == "proj-456")
    }
}

struct GeminiCredentialTests {
    private func fakeIDToken(email: String) throws -> String {
        let header = Data(#"{"alg":"RS256"}"#.utf8).base64EncodedString()
        let payload = try JSONSerialization.data(withJSONObject: ["email": email])
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(header).\(payload).sig"
    }

    @Test func normalizesAntigravityGoKeyringPayloadAndRoundTrips() throws {
        let inner = try JSONSerialization.data(withJSONObject: [
            "token": [
                "access_token": "agy-acc",
                "refresh_token": "agy-ref",
                "token_type": "Bearer",
                "expiry": "2026-11-28T14:22:07.787908+09:00",
                "expires_in": 3599,
            ],
            "auth_method": "consumer",
            "id_token_email": "agy@example.test",
        ])
        let wrapped = GeminiLogin.wrapGoKeyring(inner)
        let login = try #require(GeminiLogin(credentials: wrapped, email: nil))
        #expect(login.isAntigravity)
        #expect(login.accessToken == "agy-acc")
        #expect(login.refreshToken == "agy-ref")
        #expect(login.email == "agy@example.test")
        #expect(login.expiresAt > 0)

        let roundTripped = try #require(login.agyKeychainPayload)
        let reparsed = try #require(GeminiLogin(credentials: roundTripped, email: nil))
        #expect(reparsed.isAntigravity)
        #expect(reparsed.email == "agy@example.test")
        #expect(reparsed.matchesTokens(login))
    }

    @Test func normalizesFileAndKeychainFormatsAndExtractsIDTokenEmail() throws {
        let idToken = try fakeIDToken(email: "dev@example.test")
        let keychainJSON = try JSONSerialization.data(withJSONObject: [
            "serverName": "main-account",
            "token": [
                "accessToken": "acc-1",
                "refreshToken": "ref-1",
                "tokenType": "Bearer",
                "expiresAt": 1_900_000_000_000.0,
                "idToken": idToken,
            ],
            "updatedAt": 1_800_000_000_000,
        ])
        let login = try #require(GeminiLogin(credentials: keychainJSON, email: nil))
        #expect(login.accessToken == "acc-1")
        #expect(login.refreshToken == "ref-1")
        #expect(login.expiresAt == 1_900_000_000_000)
        #expect(login.email == "dev@example.test")

        let roundTripped = try #require(login.keychainPayload())
        let reparsed = try #require(GeminiLogin(credentials: roundTripped, email: nil))
        #expect(reparsed.matchesCredentials(login))
        #expect(reparsed.email == "dev@example.test")
    }

    @Test func replacesActiveEmailWhilePreservingOldAccounts() throws {
        let initial = Data(#"{"active":"first@example.test","old":["older@example.test"]}"#.utf8)
        let updated = try GeminiConfig.replaceActiveEmail(inAccountsJSON: initial, with: "second@example.test")
        #expect(GeminiConfig.readActiveEmail(fromAccountsJSON: updated) == "second@example.test")
        let obj = try #require(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let old = try #require(obj["old"] as? [String])
        #expect(old.contains("older@example.test"))
        #expect(old.contains("first@example.test"))
    }
}

@MainActor
struct GeminiLoginAndUsageTests {
    private func login(_ token: String, email: String = "one@example.test", expiresIn: Double = 7200) throws -> GeminiLogin {
        let data = try JSONSerialization.data(withJSONObject: [
            "access_token": token,
            "refresh_token": "refresh-" + token,
            "expiry_date": Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000,
        ])
        return try #require(GeminiLogin(credentials: data, email: email))
    }

    @Test func concurrentReadersShareRefreshAndCancellationDoesNotStopSave() async throws {
        var logins: [GeminiLoginStorage.Source: GeminiLogin] = [:]
        let old = try login("old", expiresIn: -60)
        let fresh = try login("fresh", expiresIn: 3600)
        logins = [.current: old, .profile("one"): old]
        let gate = GeminiRefreshGate()
        var refreshes = 0
        let manager = GeminiLoginManager(
            read: { logins[$0] },
            write: { logins[$0] = $1; return true },
            sources: { Array(logins.keys) },
            refresh: { _ in refreshes += 1; return await gate.refresh() }
        )

        let first = Task { await manager.token(for: .current) }
        await gate.waitUntilStarted()
        let second = Task { await manager.token(for: .profile("one")) }
        await Task.yield()
        first.cancel()
        gate.finish(.success(fresh))

        #expect(try await first.value.get() == "fresh")
        #expect(try await second.value.get() == "fresh")
        #expect(logins[.current]?.accessToken == "fresh")
        #expect(logins[.profile("one")]?.accessToken == "fresh")
        #expect(refreshes == 1)
        #expect(!gate.wasCancelled)
    }

    @Test func usage401RefreshesAndRetriesAndCachesProjectID() async throws {
        var current = try login("old")
        let fresh = try login("fresh")
        var refreshes = 0
        let manager = GeminiLoginManager(
            read: { _ in current },
            write: { _, login in current = login; return true },
            sources: { [.current] },
            refresh: { _ in refreshes += 1; return .success(fresh) }
        )
        var seenProjects: [String?] = []
        let client = GeminiUsageClient(logins: manager, fetch: { token, projectID, _ in
            seenProjects.append(projectID)
            if token == "old" { throw UsageFetchError.http(401) }
            let data = Data(#"{"buckets":[{"modelId":"gemini-2.5-pro","remainingFraction":0.6}]}"#.utf8)
            return (try GeminiUsageParser.parse(data), data, "proj-abc")
        })

        let first = try await client.read(for: .current).get().0
        #expect(Int(try #require(first.proWindow).usedPercent.rounded()) == 40)
        let second = try await client.read(for: .current).get().0
        #expect(Int(try #require(second.proWindow).usedPercent.rounded()) == 40)
        #expect(refreshes == 1)
        #expect(seenProjects == [nil, nil, "proj-abc"])
    }

    @Test func repeated401MarksSignInAndRateLimitSharesDeadline() async throws {
        let one = try login("one")
        let two = try login("two", email: "two@example.test")
        let map: [GeminiLoginStorage.Source: GeminiLogin] = [.current: one, .profile("one"): one, .profile("two"): two]
        let manager = GeminiLoginManager(
            read: { map[$0] },
            write: { _, _ in true },
            sources: { Array(map.keys) },
            refresh: { _ in Issue.record("No refresh expected"); return .failure(.unavailable) }
        )
        let gate = GeminiUsageGate()
        var requests = 0
        let deadline = Date().addingTimeInterval(3600)
        let client = GeminiUsageClient(logins: manager, fetch: { token, _, _ in
            requests += 1
            if token == "one" { return try await gate.fetch() }
            let data = Data(#"{"buckets":[{"modelId":"gemini-2.5-flash","remainingFraction":0.8}]}"#.utf8)
            return (try GeminiUsageParser.parse(data), data, nil)
        })

        let request = Task { await client.read(for: .current) }
        await gate.waitUntilStarted()
        request.cancel()
        gate.finish(.failure(UsageFetchError.rateLimited(deadline)))
        if case .failure(let error) = await request.value { #expect(error == .cancelled) }
        else { Issue.record("Expected cancelled") }
        if case .failure(let error) = await client.read(for: .profile("one")) { #expect(error == .retryLater) }
        else { Issue.record("Expected shared retryLater") }
        #expect(try await client.read(for: .profile("two")).get().0.flashWindow != nil)
        #expect(requests == 2)
    }

    @Test func accountSwitchPreservesCurrentAndRollsBackOnConfigWriteFailure() async throws {
        let suite = "cctray-gemini-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = GeminiMemoryStorage()
        let one = try storage.login("one", email: "one@example.test")
        let two = try storage.login("two", email: "two@example.test")
        try storage.select(one)
        try storage.save(one, as: "one")
        try storage.save(two, as: "two")
        defaults.set(["one", "two"], forKey: PrefKey.geminiProfiles)
        defaults.set("one", forKey: PrefKey.geminiActive)
        storage.canWriteConfiguration = false
        let accounts = storage.store(defaults)

        await accounts.activate("two")
        #expect(accounts.active == "one")
        #expect(storage.adapter.read(.current)?.accessToken == "one")
        #expect(storage.credentialWrites == 2)
        #expect(storage.clears == 0)

        storage.canWriteConfiguration = true
        await accounts.activate("two")
        #expect(accounts.active == "two")
        #expect(storage.adapter.read(.current)?.accessToken == "two")
        #expect(storage.adapter.currentEmail() == "two@example.test")
    }

    @Test func deletingLiveProfilePreventsAutoReimport() async throws {
        let suite = "cctray-gemini-tests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = GeminiMemoryStorage()
        let one = try storage.login("one", email: "one@example.test")
        try storage.select(one)
        let accounts = storage.store(defaults)

        await accounts.maintainLogins()
        #expect(accounts.profiles == ["one"])
        accounts.delete("one")
        #expect(accounts.profiles.isEmpty)
        await accounts.maintainLogins()
        #expect(accounts.profiles.isEmpty)
    }
}

struct GeminiHooksActivityAndDiscoveryTests {
    @Test func installsAndRemovesHooksWhilePreservingExistingSettings() throws {
        let initial = Data(#"{"theme":"Default","hooks":{"AfterAgent":[{"matcher":"*","hooks":[{"name":"user-hook","type":"command","command":"echo hi"}]}]}}"#.utf8)
        let installed = try GeminiHook.install(into: initial)
        let installedObj = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
        #expect(installedObj["theme"] as? String == "Default")
        let hooks = try #require(installedObj["hooks"] as? [String: Any])
        #expect((hooks["BeforeAgent"] as? [[String: Any]])?.count == 1)
        #expect((hooks["AfterAgent"] as? [[String: Any]])?.count == 2)

        let removed = try GeminiHook.remove(from: installed)
        let removedObj = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
        let remainingHooks = try #require(removedObj["hooks"] as? [String: Any])
        #expect(remainingHooks["BeforeAgent"] == nil)
        #expect((remainingHooks["AfterAgent"] as? [[String: Any]])?.count == 1)
    }

    @Test func parsesGeminiAttentionEventsAndTracksActivity() {
        let before = #"{"provider":"gemini","tty":"ttys005","pid":4242,"raw":{"hook_event_name":"BeforeAgent","cwd":"/tmp/app","transcript_path":"/tmp/session.jsonl"}}"#
        let after = #"{"provider":"gemini","tty":"ttys005","pid":4242,"raw":{"hook_event_name":"AfterAgent","cwd":"/tmp/app","prompt_response":"All tests pass","stop_hook_active":false,"transcript_path":"/tmp/session.jsonl"}}"#
        let stopActive = #"{"provider":"gemini","tty":"ttys005","pid":4242,"raw":{"hook_event_name":"AfterAgent","cwd":"/tmp/app","prompt_response":"Retrying","stop_hook_active":true}}"#

        #expect(AttentionParser.parse(line: before) == nil)
        #expect(AttentionParser.parse(line: stopActive) == nil)
        let event = AttentionParser.parse(line: after)
        #expect(event == AttentionEvent(tty: "ttys005", cwd: "/tmp/app", message: "All tests pass", agent: .gemini))

        let activity = GeminiActivity()
        #expect(activity.record(line: before))
        #expect(activity.state(pid: 4242, tty: "ttys005")?.working == true)
        #expect(activity.record(line: after))
        #expect(activity.state(pid: 4242, tty: "ttys005")?.working == false)
    }

    @Test func extractsTitleAndWorkingStateFromJsonlAndLegacyJsonTranscripts() {
        let jsonl = """
        {"type":"session_metadata","sessionId":"s1"}
        {"type":"user","message":"Refactor auth client"}
        {"type":"gemini","message":"Working on it"}
        """
        #expect(GeminiActivity.titleFromTranscript(jsonl) == "Refactor auth client")
        #expect(GeminiActivity.working(text: jsonl) == false)

        let legacy = #"{"sessionId":"s2","messages":[{"type":"user","content":[{"text":"Fix race condition"}]}]}"#
        #expect(GeminiActivity.titleFromTranscript(legacy) == "Fix race condition")
        #expect(GeminiActivity.working(text: legacy) == true)
    }

    @Test func installsAndRemovesAgyHooksWhilePreservingOtherEntries() throws {
        let initial = Data(#"{"other-hook":{"Stop":[{"type":"command","command":"echo ok"}]}}"#.utf8)
        let installed = try GeminiHook.installAgy(into: initial)
        let installedObj = try #require(try JSONSerialization.jsonObject(with: installed) as? [String: Any])
        #expect(installedObj["other-hook"] != nil)
        let ours = try #require(installedObj[GeminiHook.hookName] as? [String: Any])
        #expect((ours["PreInvocation"] as? [[String: Any]])?.count == 1)
        #expect((ours["Stop"] as? [[String: Any]])?.count == 1)

        let removed = try GeminiHook.removeAgy(from: installed)
        let removedObj = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
        #expect(removedObj["other-hook"] != nil)
        #expect(removedObj[GeminiHook.hookName] == nil)
    }

    @Test func parsesAgyAttentionEventsAndTranscripts() {
        let pre = #"{"provider":"agy","tty":"ttys002","pid":700,"raw":{"hookEventName":"PreInvocation","cwd":"/tmp/proj","transcriptPath":"/tmp/t.jsonl"}}"#
        let stop = #"{"provider":"agy","tty":"ttys002","pid":700,"raw":{"hookEventName":"Stop","cwd":"/tmp/proj","fullyIdle":true,"terminationReason":"NO_TOOL_CALL","transcriptPath":"/tmp/t.jsonl"}}"#
        let canceled = #"{"provider":"agy","tty":"ttys002","pid":700,"raw":{"hookEventName":"Stop","cwd":"/tmp/proj","fullyIdle":true,"terminationReason":"USER_CANCELED"}}"#

        #expect(AttentionParser.parse(line: pre) == nil)
        #expect(AttentionParser.parse(line: canceled) == nil)
        #expect(AttentionParser.parse(line: stop) == AttentionEvent(tty: "ttys002", cwd: "/tmp/proj", message: "", agent: .gemini))

        let activity = GeminiActivity()
        #expect(activity.record(line: pre))
        #expect(activity.state(pid: 700, tty: "ttys002")?.working == true)
        #expect(activity.record(line: stop))
        #expect(activity.state(pid: 700, tty: "ttys002")?.working == false)

        let agyTranscript = """
        {"step_index":0,"type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\\nAdd Gemini limits\\n</USER_REQUEST>"}
        {"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[]}
        """
        #expect(GeminiActivity.titleFromTranscript(agyTranscript) == "Add Gemini limits")
        #expect(GeminiActivity.working(text: agyTranscript) == false)

        let agyWorking = """
        {"step_index":0,"type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\\nAdd Gemini limits\\n</USER_REQUEST>"}
        {"step_index":1,"type":"PLANNER_RESPONSE","status":"DONE","tool_calls":[{"name":"run_command"}]}
        """
        #expect(GeminiActivity.working(text: agyWorking) == true)
    }

    @Test func detectsInteractiveAgyAndGeminiProcessesAndFiltersHeadlessOnes() {
        let agyInteractive = ProcRow(pid: 9, ppid: 2, tty: "ttys000", elapsed: 10, comm: "agy", arguments: "agy")
        let agyPrint = ProcRow(pid: 16, ppid: 2, tty: "ttys006", elapsed: 2, comm: "agy", arguments: "agy -p hi")
        let agyModels = ProcRow(pid: 17, ppid: 2, tty: "ttys007", elapsed: 2, comm: "agy", arguments: "agy models")
        let direct = ProcRow(pid: 10, ppid: 2, tty: "ttys001", elapsed: 12, comm: "/opt/homebrew/bin/gemini", arguments: "gemini")
        let viaNode = ProcRow(pid: 11, ppid: 2, tty: "ttys002", elapsed: 15, comm: "/opt/homebrew/bin/node", arguments: "node /opt/homebrew/bin/gemini --model gemini-2.5-pro")
        let childOfDirect = ProcRow(pid: 12, ppid: 10, tty: "ttys001", elapsed: 12, comm: "/opt/homebrew/bin/node", arguments: "node /opt/homebrew/lib/node_modules/@google/gemini-cli/dist/index.js")
        let headless = ProcRow(pid: 13, ppid: 2, tty: "ttys003", elapsed: 3, comm: "/opt/homebrew/bin/node", arguments: "node /opt/homebrew/bin/gemini -p hi")
        let subcommand = ProcRow(pid: 14, ppid: 2, tty: "ttys004", elapsed: 3, comm: "/opt/homebrew/bin/node", arguments: "node /opt/homebrew/bin/gemini mcp list")
        let unrelatedNode = ProcRow(pid: 15, ppid: 2, tty: "ttys005", elapsed: 3, comm: "/opt/homebrew/bin/node", arguments: "node server.js")

        #expect(agyInteractive.agent == .gemini && agyInteractive.isInteractive)
        #expect(agyPrint.agent == .gemini && !agyPrint.isInteractive)
        #expect(agyModels.agent == .gemini && !agyModels.isInteractive)
        #expect(direct.agent == .gemini && direct.isInteractive)
        #expect(viaNode.agent == .gemini && viaNode.isInteractive)
        #expect(headless.agent == .gemini && !headless.isInteractive)
        #expect(subcommand.agent == .gemini && !subcommand.isInteractive)
        #expect(unrelatedNode.agent == nil)

        let active = Sessions.active([agyInteractive, agyPrint, agyModels, direct, viaNode, childOfDirect, headless, subcommand, unrelatedNode])
        #expect(active.map(\.pid) == [9, 10, 11])
        #expect(active.allSatisfy { $0.agent == .gemini })
    }

    @Test func defaultGeminiHotkeyAndSessionCommand() {
        let key = CodingAgent.gemini.hotkeyKey
        let previous = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
        }
        let hotkey = AgentHotkey.read(for: .gemini)
        #expect(hotkey.label == "⌥⌘G")
        let expected = "cd '/tmp/my app' && " + GeminiCLI.executable
        #expect(TerminalLauncher.sessionCommand(for: "/tmp/my app", agent: .gemini) == expected)
    }
}
