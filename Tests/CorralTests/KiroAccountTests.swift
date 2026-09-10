import SQLite3
import XCTest
@testable import Corral

/// The one request Corral makes, pinned so it cannot drift.
///
/// None of this touches the network. The request is built and read back; the
/// answer is a fixture in the shape the IDE's own client documents; the store
/// is a temporary SQLite file with the table Kiro CLI keeps.
final class KiroAccountTests: XCTestCase {

    private let arn = "arn:aws:codewhisperer:us-east-1:699475941385:profile/EHGA3GRVQMUK"

    override func tearDown() {
        // The setting is global; a test that turned it on must not leave it.
        KiroAccount.isEnabled = false
        super.tearDown()
    }

    // ─ Where it goes ────────────────────────────────────────────────────────

    /// The host comes from the ARN's region and from nowhere else, and a
    /// region this file does not name goes to the commercial default rather
    /// than to a host built from a string.
    func testTheHostIsChosenFromTheProfileRegion() {
        XCTAssertEqual(KiroAccount.region(of: arn), "us-east-1")
        XCTAssertEqual(
            KiroAccount.region(of: "arn:aws:codewhisperer:eu-central-1:1:profile/x"), "eu-central-1"
        )
        XCTAssertEqual(KiroAccount.region(of: "arn:aws:codewhisperer:ap-south-1:1:profile/x"), "us-east-1")
        XCTAssertEqual(KiroAccount.region(of: "arn:aws:s3:eu-central-1:1:profile/x"), "us-east-1")
        XCTAssertEqual(KiroAccount.region(of: nil), "us-east-1")
        XCTAssertEqual(
            KiroAccount.endpoint(for: "arn:aws:codewhisperer:eu-central-1:1:profile/x").host,
            "q.eu-central-1.amazonaws.com"
        )
    }

    /// The token is in the Authorization header and nowhere else: not the
    /// URL, not the body.
    func testTheRequestCarriesTheTokenOnlyInItsHeader() throws {
        let credential = KiroCredential(token: "SECRET-TOKEN", expiresAt: .distantFuture, profileArn: arn)
        let request = KiroUsageAPI.request(credential: credential, profileArn: nil)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://codewhisperer.us-east-1.amazonaws.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer SECRET-TOKEN")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Amz-Target"), KiroUsageAPI.target)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-amz-json-1.0")
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("AmazonQ-For-CLI/") ?? false)

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["origin"] as? String, "AI_EDITOR")
        XCTAssertEqual(object["profileArn"] as? String, arn)
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("SECRET"))
        XCTAssertFalse(request.url?.absoluteString.contains("SECRET") ?? true)
    }

    /// A token that names no profile borrows the one Kiro's state names.
    func testTheStatesProfileFillsInForATokenWithoutOne() throws {
        let credential = KiroCredential(token: "t", expiresAt: .distantFuture, profileArn: nil)
        let request = KiroUsageAPI.request(credential: credential, profileArn: arn)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(object["profileArn"] as? String, arn)

        let bare = KiroUsageAPI.request(credential: credential, profileArn: nil)
        let bareObject = try XCTUnwrap(JSONSerialization.jsonObject(with: bare.httpBody!) as? [String: Any])
        XCTAssertNil(bareObject["profileArn"])
    }

    // ─ What comes back ──────────────────────────────────────────────────────

    private let answer = """
        {
          "usageBreakdownList": [
            {
              "resourceType": "CREDIT",
              "currentUsage": 312, "currentUsageWithPrecision": 312.4,
              "usageLimit": 500, "usageLimitWithPrecision": 500,
              "currentOverages": 0, "overageRate": 0.04
            },
            {
              "resourceType": "FREE_TRIAL_CREDIT", "title": "Welcome credits",
              "currentUsage": 100, "usageLimit": 100
            },
            { "resourceType": "TOKEN", "currentUsage": 1, "usageLimit": 2 }
          ],
          "subscriptionInfo": { "subscriptionTitle": "Kiro Pro", "type": "PRO" },
          "nextDateReset": 1791000000
        }
        """

    func testTheCreditEntryIsReadWithItsPreciseFiguresFirst() throws {
        let report = try XCTUnwrap(KiroUsageAPI.report(from: Data(answer.utf8)))
        XCTAssertEqual(report.used, 312.4, accuracy: 0.0001)
        XCTAssertEqual(report.limit, 500)
        XCTAssertEqual(report.overage, 0)
        XCTAssertEqual(report.plan, "Kiro Pro")
        XCTAssertEqual(report.resetsAt, Date(timeIntervalSince1970: 1_791_000_000))
    }

    /// A pool spent before the plan is kept as one; a quota in some other
    /// unit is not a credit figure and is left out.
    func testBonusPoolsAreKeptAndOtherQuotasAreNot() throws {
        let report = try XCTUnwrap(KiroUsageAPI.report(from: Data(answer.utf8)))
        XCTAssertEqual(report.bonuses.count, 1)
        XCTAssertEqual(report.bonuses[0].name, "Welcome credits")
        XCTAssertEqual(report.bonuses[0].used, 100)
        XCTAssertEqual(report.bonuses[0].limit, 100)
    }

    func testOverageIsDerivedWhenTheServiceOmitsIt() throws {
        let over = answer
            .replacingOccurrences(of: "\"currentUsageWithPrecision\": 312.4", with: "\"currentUsageWithPrecision\": 540")
            .replacingOccurrences(of: "\"currentOverages\": 0, ", with: "")
        let report = try XCTUnwrap(KiroUsageAPI.report(from: Data(over.utf8)))
        XCTAssertEqual(report.overage, 40, accuracy: 0.0001)
    }

    /// An answer with no credit entry, or with a limit of zero, is not a
    /// reading of zero. Nothing is shown.
    func testAnAnswerWithoutACreditEntryIsNotAReading() {
        XCTAssertNil(KiroUsageAPI.report(from: Data("{\"usageBreakdownList\": []}".utf8)))
        XCTAssertNil(KiroUsageAPI.report(from: Data("{\"usageBreakdownList\": [{\"resourceType\": \"TOKEN\", \"currentUsage\": 1, \"usageLimit\": 2}]}".utf8)))
        XCTAssertNil(KiroUsageAPI.report(from: Data("{\"usageBreakdownList\": [{\"resourceType\": \"CREDIT\", \"currentUsage\": 1, \"usageLimit\": 0}]}".utf8)))
        XCTAssertNil(KiroUsageAPI.report(from: Data("not json".utf8)))
    }

    /// In the panel's terms: one window for the plan with the count kept, a
    /// window per pool, the plan's name, and the fraction unclamped.
    func testTheReportBecomesLimitsWithTheirCounts() throws {
        let report = try XCTUnwrap(KiroUsageAPI.report(from: Data(answer.utf8)))
        let at = Date(timeIntervalSince1970: 1_789_000_000)
        let usage = KiroUsageAPI.usage(from: report, at: at)

        XCTAssertEqual(usage.tool, .kiroCLI)
        XCTAssertEqual(usage.plan, "Kiro Pro")
        XCTAssertEqual(usage.observedAt, at)
        XCTAssertEqual(usage.limits.map(\.label), ["monthly credits", "welcome credits"])
        XCTAssertEqual(usage.limits[0].usedFraction, 0.6248, accuracy: 0.0001)
        XCTAssertEqual(usage.limits[0].quantity?.remainingText, "187.6 of 500 credits left")
        XCTAssertEqual(usage.limits[0].resetsAt, Date(timeIntervalSince1970: 1_791_000_000))
        XCTAssertEqual(usage.limits[1].quantity?.remainingText, "none left")
    }

    func testAPlanInOverageReadsPastFull() throws {
        let over = answer.replacingOccurrences(
            of: "\"currentUsageWithPrecision\": 312.4", with: "\"currentUsageWithPrecision\": 540"
        )
        let usage = KiroUsageAPI.usage(from: try XCTUnwrap(KiroUsageAPI.report(from: Data(over.utf8))), at: Date())
        XCTAssertEqual(usage.limits[0].usedFraction, 1.08, accuracy: 0.0001)
        XCTAssertEqual(usage.limits[0].quantity?.remainingText, "none left")
    }

    // ─ The credential ───────────────────────────────────────────────────────

    private func makeStore(auth: [(String, String)], profile: String? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("corral-kiro-auth-\(UUID().uuidString).sqlite3")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for sql in [
            "CREATE TABLE auth_kv (key TEXT PRIMARY KEY, value TEXT)",
            "CREATE TABLE state (key TEXT PRIMARY KEY, value TEXT)",
        ] {
            XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        }
        for (key, value) in auth {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(handle, "INSERT INTO auth_kv VALUES (?, ?)", -1, &statement, nil)
            sqlite3_bind_text(statement, 1, key, -1, transient)
            sqlite3_bind_text(statement, 2, value, -1, transient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        if let profile {
            var statement: OpaquePointer?
            sqlite3_prepare_v2(handle, "INSERT INTO state VALUES ('api.codewhisperer.profile', ?)", -1, &statement, nil)
            sqlite3_bind_text(statement, 1, profile, -1, transient)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_finalize(statement)
        }
        return url
    }

    private let now = Date(timeIntervalSince1970: 1_789_000_000)

    /// The blob Kiro CLI writes for a Google sign-in, with its refresh token
    /// present and ignored.
    func testALiveTokenIsReadFromKiroCLIsOwnStore() throws {
        let store = try makeStore(auth: [(
            "kirocli:social:token",
            """
            {"access_token": "live", "expires_at": "2026-09-10T07:18:04.479133Z",
             "refresh_token": "never-read", "provider": "google", "profile_arn": "\(arn)"}
            """
        )])
        defer { try? FileManager.default.removeItem(at: store) }

        let outcome = KiroAuthStore.credential(in: store, now: now)
        guard case .found(let credential) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(credential.token, "live")
        XCTAssertEqual(credential.profileArn, arn)
        XCTAssertEqual(credential.expiresAt, KiroSessions.timestamp("2026-09-10T07:18:04.479133Z"))
    }

    /// Run out is run out, and Corral does not refresh: it says so and waits
    /// for Kiro CLI to.
    func testAnExpiredTokenIsReportedAsExpiredNotUsed() throws {
        let store = try makeStore(auth: [(
            "kirocli:social:token",
            "{\"access_token\": \"old\", \"expires_at\": \"2026-09-01T00:00:00Z\"}"
        )])
        defer { try? FileManager.default.removeItem(at: store) }
        XCTAssertEqual(
            KiroAuthStore.credential(in: store, now: now),
            .expired(KiroSessions.timestamp("2026-09-01T00:00:00Z")!)
        )
    }

    /// Two sign-ins in the store: the one that expires later was issued
    /// later, and is the one in use.
    func testTheFreshestOfSeveralTokensWins() throws {
        let store = try makeStore(auth: [
            ("kirocli:odic:token", "{\"access_token\": \"older\", \"expires_at\": \"2026-09-10T01:00:00Z\"}"),
            ("kirocli:social:token", "{\"access_token\": \"newer\", \"expires_at\": \"2026-09-10T02:00:00Z\"}"),
        ])
        defer { try? FileManager.default.removeItem(at: store) }
        guard case .found(let credential) = KiroAuthStore.credential(in: store, now: now)
        else { return XCTFail("no credential") }
        XCTAssertEqual(credential.token, "newer")
    }

    func testAMissingStoreIsMissingNotAnError() {
        XCTAssertEqual(
            KiroAuthStore.credential(in: URL(fileURLWithPath: "/nonexistent/data.sqlite3"), now: now),
            .missing
        )
        XCTAssertNil(KiroAuthStore.profileArn(in: URL(fileURLWithPath: "/nonexistent/data.sqlite3")))
    }

    func testTheProfileIsReadFromKiroCLIsState() throws {
        let store = try makeStore(auth: [], profile: "{\"arn\": \"\(arn)\", \"profile_name\": \"Social_Default_Profile\"}")
        defer { try? FileManager.default.removeItem(at: store) }
        XCTAssertEqual(KiroAuthStore.profileArn(in: store), arn)
    }

    // ─ The switch ───────────────────────────────────────────────────────────

    /// Off by default, and off means nothing: no store opened, no request,
    /// no figure, and a status that says so.
    func testOffMeansNothingIsAskedOrKept() throws {
        KiroAccount.isEnabled = false
        let store = KiroAccountStore(store: URL(fileURLWithPath: "/nonexistent/data.sqlite3"))
        XCTAssertNil(store.usage())
        XCTAssertEqual(store.status, .off)
        store.refreshIfDue(force: true)
        XCTAssertEqual(store.status, .off)
    }

    /// Turned on against a store with no token, the answer is a sentence
    /// about signing in — never a request with nothing in it.
    func testOnWithNoTokenFailsClosedWithAReason() throws {
        let empty = try makeStore(auth: [])
        defer { try? FileManager.default.removeItem(at: empty) }
        KiroAccount.isEnabled = true
        let store = KiroAccountStore(store: empty)
        store.refreshIfDue(force: true)

        let deadline = Date().addingTimeInterval(5)
        while store.status == .asking && Date() < deadline { usleep(20_000) }
        guard case .failed(let reason, _) = store.status else { return XCTFail("\(store.status)") }
        XCTAssertTrue(reason.contains("not signed in"), reason)
        XCTAssertNil(store.usage())

        // And turning it off forgets even the failure.
        KiroAccount.isEnabled = false
        store.forget()
        XCTAssertEqual(store.status, .off)
    }
}
