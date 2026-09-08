import XCTest
@testable import cctray

/* Shape copied from a real /api/oauth/usage response. */
private func payload(session: Int, weekly: Int, scoped: Int) -> String { """
{"five_hour":{"utilization":\(session),"resets_at":"2026-09-06T06:50:00.000000Z"},
 "seven_day":{"utilization":\(weekly),"resets_at":"2026-09-12T08:59:59.000000Z"},
 "limits":[
  {"kind":"session","group":"session","percent":\(session),
   "resets_at":"2026-09-06T06:50:00.000000Z","scope":null},
  {"kind":"weekly_all","group":"weekly","percent":\(weekly),
   "resets_at":"2026-09-12T08:59:59.000000Z","scope":null},
  {"kind":"weekly_scoped","group":"weekly","percent":\(scoped),
   "resets_at":"2026-09-12T09:00:00.000000Z",
   "scope":{"model":{"id":null,"display_name":"Claude Opus 4.5"}}}]}
""" }

private let now = try! Date("2026-09-06T06:00:00.000000Z", strategy: .iso8601)

private func summary(_ json: String) throws -> String {
    AccountStore.usageSummary(try UsageParser.parse(Data(json.utf8)), now: now)
}

final class UsageSummaryTests: XCTestCase {
    func testShowsTheWindowThatBindsFirst() throws {
        XCTAssertEqual(try summary(payload(session: 80, weekly: 33, scoped: 22)), "80% 5h · 50m")
        XCTAssertEqual(try summary(payload(session: 16, weekly: 95, scoped: 22)), "95% week · 6d 2h")
    }

    func testModelScopedLimitReportsItsWindow() throws {
        XCTAssertEqual(try summary(payload(session: 16, weekly: 33, scoped: 99)),
                       "99% week · 6d 3h")
    }

    func testFallsBackWhenTheResponseHasNoLimitsArray() throws {
        XCTAssertEqual(try summary("""
        {"five_hour":{"utilization":41,"resets_at":"2026-09-06T08:00:00.000000Z"},
         "seven_day":{"utilization":9,"resets_at":null}}
        """), "41% 5h · 2h")
    }

    func testFallsBackWhenTheLimitsArrayIsEmpty() throws {
        XCTAssertEqual(try summary("""
        {"five_hour":{"utilization":41,"resets_at":"2026-09-06T08:00:00.000000Z"},
         "seven_day":{"utilization":9,"resets_at":null},"limits":[]}
        """), "41% 5h · 2h")
    }

    func testWindowLabelSurvivesAKindThisBuildHasNeverSeen() {
        XCTAssertEqual(Usage.windowLabel("session"), "5h")
        XCTAssertEqual(Usage.windowLabel("weekly_scoped"), "week")
        XCTAssertEqual(Usage.windowLabel("monthly"), "month")
        XCTAssertEqual(Usage.windowLabel("quarterly"), "quarterly")
    }
}

final class MenuLabelTests: XCTestCase {
    func testClipsTheNameNotTheNumber() {
        XCTAssertEqual(AccountStore.menuLabel("mavdotso@gmail.com", summary: "24% week · 6d 4h"),
                       "mavdotso@…  24% week · 6d 4h")
        XCTAssertEqual(AccountStore.menuLabel("exactlyten", summary: "5% 5h · 1h"),
                       "exactlyten  5% 5h · 1h")
    }

    func testKeepsTheWholeNameWhenThereIsNoUsageYet() {
        XCTAssertEqual(AccountStore.menuLabel("mavdotso@gmail.com", summary: nil),
                       "mavdotso@gmail.com")
    }

    func testStaysNarrowEnoughToRender() {
        let label = AccountStore.menuLabel("mavdotso@gmail.com", summary: "100% month · 27d 12h")
        XCTAssertLessThanOrEqual(label.count, 32, label)
    }
}

final class RefreshReasonTests: XCTestCase {
    private func reason(_ code: Int, _ body: String) -> String {
        ClaudeOAuth.reason(code: code, body: Data(body.utf8))
    }

    func testSpentRefreshTokenAsksForALogin() {
        XCTAssertEqual(reason(400, #"{"error":{"type":"invalid_grant"}}"#), "sign in again")
        XCTAssertEqual(reason(400, #"{"error":"invalid_grant"}"#), "sign in again")
    }

    func testEverythingElseIsTransient() {
        XCTAssertEqual(reason(429, #"{"error":{"type":"rate_limit_error"}}"#), "rate limited")
        XCTAssertEqual(reason(500, "upstream exploded"), "not available")
        XCTAssertEqual(reason(400, #"{"error":{"type":"invalid_request"}}"#), "not available")
    }

    func testNeverLeaksRawServerTextToTheMenu() {
        XCTAssertEqual(reason(418, "<html>teapot</html>"), "not available")
    }
}

final class DateParsingTests: XCTestCase {
    func testAcceptsTheMicrosecondsTheApiActuallySends() {
        XCTAssertNotNil(UsageParser.parseDate("2026-09-06T06:50:00.000000Z"))
        XCTAssertNotNil(UsageParser.parseDate("2026-09-06T06:50:00.123Z"))
        XCTAssertNotNil(UsageParser.parseDate("2026-09-06T06:50:00Z"))
        XCTAssertNil(UsageParser.parseDate("not a date"))
    }
}

final class ExpiryTests: XCTestCase {
    func testExpiryIsReadAsMillisecondsSinceEpoch() {
        let past = ["expiresAt": (Date().timeIntervalSince1970 - 60) * 1000]
        let future = ["expiresAt": (Date().timeIntervalSince1970 + 3600) * 1000]
        XCTAssertTrue(ClaudeOAuth.isExpired(past))
        XCTAssertFalse(ClaudeOAuth.isExpired(future))
        XCTAssertFalse(ClaudeOAuth.isExpired([:]))
    }
}

@MainActor
final class ProfileRulesTests: XCTestCase {
    func testNeverOverwritesADifferentAccount() {
        XCTAssertTrue(AccountStore.mayOverwrite(profileEmail: "a@x.com", liveEmail: "a@x.com"))
        XCTAssertFalse(AccountStore.mayOverwrite(profileEmail: "a@x.com", liveEmail: "b@x.com"))
        XCTAssertFalse(AccountStore.mayOverwrite(profileEmail: nil, liveEmail: "a@x.com"))
        XCTAssertFalse(AccountStore.mayOverwrite(profileEmail: "a@x.com", liveEmail: nil))
        XCTAssertFalse(AccountStore.mayOverwrite(profileEmail: nil, liveEmail: nil))
    }

    func testWarnsOnlyWhenTheLiveLoginIsTheWrongAccount() {
        XCTAssertEqual(AccountStore.mismatchWarning(active: "work", expected: "a@x.com",
                                                    live: "b@x.com"),
                       "Logged in as b@x.com — work is a@x.com")
        XCTAssertNil(AccountStore.mismatchWarning(active: "work", expected: "a@x.com",
                                                  live: "a@x.com"))
        XCTAssertNil(AccountStore.mismatchWarning(active: nil, expected: "a@x.com",
                                                  live: "b@x.com"))
        XCTAssertNil(AccountStore.mismatchWarning(active: "work", expected: nil, live: "b@x.com"))
        XCTAssertNil(AccountStore.mismatchWarning(active: "work", expected: "a@x.com", live: nil))
    }

    func testRenameRejectsACollisionAndIgnoresANoOp() {
        let existing = ["work", "personal"]
        XCTAssertEqual(AccountStore.validateRename(from: "work", to: "mav", existing: existing),
                       .rename("mav"))
        XCTAssertEqual(AccountStore.validateRename(from: "work", to: "  mav  ", existing: existing),
                       .rename("mav"))
        XCTAssertEqual(AccountStore.validateRename(from: "work", to: "personal", existing: existing),
                       .reject("Rename failed: personal already exists"))
        XCTAssertEqual(AccountStore.validateRename(from: "work", to: "work", existing: existing),
                       .ignore)
        XCTAssertEqual(AccountStore.validateRename(from: "work", to: "   ", existing: existing),
                       .ignore)
        XCTAssertEqual(AccountStore.validateRename(from: "ghost", to: "x", existing: existing),
                       .ignore)
    }
}
