import Foundation
import SQLite3

/// Asking Kiro what the account has left.
///
/// This is the one place Corral talks to a server, and it is off until you
/// turn it on. Everything else in the app reads files the tools left on this
/// Mac; Kiro leaves none for this — credits spent per turn are in its session
/// files, the balance is not — and the app that shows a balance, the Kiro
/// IDE, gets it by asking Kiro's servers. So does this.
///
/// What that takes, exactly:
///
///  - The sign-in token Kiro CLI keeps for itself, read out of its own store at
///    `~/Library/Application Support/kiro-cli/data.sqlite3`. It is a bearer
///    token; it is held in memory for the length of one request and is never
///    written down, logged, or shown.
///  - One HTTPS request every five minutes to a fixed AWS host — the same
///    `GetUsageLimits` call the Kiro IDE makes — carrying that token and the
///    profile it belongs to. Nothing else about you or your work is sent.
///  - The numbers that come back: credits used, the plan's limit, when it
///    resets, and any bonus pool. Those are all that is kept.
///
/// The token is read from Kiro CLI's own store and nowhere else, and that is
/// the whole ownership argument: a credential there is the signed-in account's
/// by construction. Kiro CLI refreshes it while it runs and Corral never
/// tries to; an expired token means "run Kiro once", and the panel says so.
///
/// Every failure is silent to the user except as a sentence in the Usage tab.
/// A balance that cannot be read is a balance that is not shown — never a
/// guess, never a stale number without its age.
enum KiroAccount {

    /// The setting, persisted. Nothing here runs while it is false.
    static let settingKey = "kiroAccountFetch"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    /// How often to ask. The Kiro IDE polls on a similar clock, and the figure
    /// moves only when a turn completes somewhere.
    static let interval: TimeInterval = 300

    /// Hardcoded hosts, chosen by the region in the profile ARN. Never read
    /// from configuration: a request carrying a bearer token goes to an AWS
    /// production host named in this file or it does not go at all.
    ///
    /// The EU host is a different hostname, not a regional spelling of the
    /// first one — `codewhisperer.eu-central-1.amazonaws.com` does not resolve.
    static let endpoints: [String: URL] = [
        "us-east-1": URL(string: "https://codewhisperer.us-east-1.amazonaws.com")!,
        "eu-central-1": URL(string: "https://q.eu-central-1.amazonaws.com")!,
    ]
    static let defaultRegion = "us-east-1"

    static let service = "com.amazon.aws.codewhisperer.runtime.AmazonCodeWhispererService"
    /// The service refuses a request that does not present itself as a Kiro
    /// or Q client. This string is what Kiro CLI sends, with the app named.
    static let userAgent = "AmazonQ-For-CLI/1.24.0 ua/2.0 os/darwin lang/rust Corral"
    static let timeout: TimeInterval = 15

    /// Profile ARNs read `arn:aws:codewhisperer:<region>:<account>:profile/<name>`.
    /// A missing or unfamiliar region goes to the commercial default, which
    /// is still a host named above.
    static func region(of arn: String?) -> String {
        guard let arn else { return defaultRegion }
        let parts = arn.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 6, parts[2] == "codewhisperer" else { return defaultRegion }
        let region = String(parts[3])
        return endpoints[region] != nil ? region : defaultRegion
    }

    static func endpoint(for arn: String?) -> URL {
        endpoints[region(of: arn)] ?? endpoints[defaultRegion]!
    }

    static var defaultStore: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
    }
}

// ─ The credential ───────────────────────────────────────────────────────────

/// A live sign-in token and the profile it belongs to.
struct KiroCredential {
    let token: String
    let expiresAt: Date
    let profileArn: String?
}

/// Reads Kiro CLI's own auth store, and only that.
///
/// The store is SQLite; `auth_kv` holds one JSON blob per key with the token
/// in `access_token` and its expiry in `expires_at`. Which key depends on how
/// the person signed in — with a Google account it is `kirocli:social:token`,
/// with AWS Builder ID or IAM Identity Center one of the `odic` ones — so all
/// are tried and the freshest unexpired one wins.
///
/// Opened read-only. The table also holds a refresh token, which is never
/// read: refreshing is Kiro CLI's job, and a Corral that refreshed tokens
/// would be a Corral that could keep a session alive after you signed out.
enum KiroAuthStore {

    static let keys = [
        "kirocli:odic:token",
        "kirocli:social:token",
        "codewhisperer:odic:token",
        "kirocli:pkce:token",
    ]

    enum Outcome: Equatable {
        case found(KiroCredential)
        /// A token was there and has run out. The date is when.
        case expired(Date)
        /// No store, or nothing in it.
        case missing

        static func == (a: Outcome, b: Outcome) -> Bool {
            switch (a, b) {
            case (.found(let x), .found(let y)):
                return x.token == y.token && x.expiresAt == y.expiresAt && x.profileArn == y.profileArn
            case (.expired(let x), .expired(let y)): return x == y
            case (.missing, .missing): return true
            default: return false
            }
        }
    }

    static func credential(in store: URL = KiroAccount.defaultStore, now: Date = Date()) -> Outcome {
        var best: KiroCredential?
        var expired: Date?
        for blob in blobs(in: store) {
            switch parse(blob, now: now) {
            case .found(let credential):
                if best == nil || credential.expiresAt > best!.expiresAt { best = credential }
            case .expired(let at):
                if expired == nil || at > expired! { expired = at }
            case .missing:
                continue
            }
        }
        if let best { return .found(best) }
        if let expired { return .expired(expired) }
        return .missing
    }

    /// One blob, judged.
    static func parse(_ blob: [String: Any], now: Date) -> Outcome {
        guard let token = (blob["access_token"] ?? blob["accessToken"]) as? String, !token.isEmpty
        else { return .missing }
        guard let expiry = KiroSessions.timestamp(blob["expires_at"] ?? blob["expiresAt"])
        else { return .missing }
        guard expiry > now.addingTimeInterval(30) else { return .expired(expiry) }
        return .found(KiroCredential(
            token: token,
            expiresAt: expiry,
            profileArn: (blob["profile_arn"] ?? blob["profileArn"]) as? String
        ))
    }

    /// The profile Kiro CLI is signed in to, from its own state. The token
    /// usually names it as well; this is for the ones that do not.
    static func profileArn(in store: URL = KiroAccount.defaultStore) -> String? {
        guard let raw = value(in: store, table: "state", key: "api.codewhisperer.profile"),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["arn"] as? String
    }

    private static func blobs(in store: URL) -> [[String: Any]] {
        keys.compactMap { key in
            guard let raw = value(in: store, table: "auth_kv", key: key),
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object
        }
    }

    /// One value out of a key/value table, read-only, with a moment's
    /// patience for a Kiro that is mid-write.
    private static func value(in store: URL, table: String, key: String) -> String? {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(store.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 200)

        var statement: OpaquePointer?
        // The table name is one of two literals above, never input.
        let sql = "SELECT value FROM \(table) WHERE key = ?"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            return nil
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: text)
    }
}

// ─ The request and the answer ───────────────────────────────────────────────

/// What Kiro said the account has.
struct KiroUsageReport: Equatable {
    struct Pool: Equatable {
        let name: String
        let used: Double
        let limit: Double
    }

    let used: Double
    let limit: Double
    let overage: Double
    let plan: String?
    let resetsAt: Date?
    let bonuses: [Pool]
}

enum KiroUsageAPI {

    static let target = "\(KiroAccount.service).GetUsageLimits"

    /// The request, complete. Everything about it is fixed here so a test can
    /// read it back: the host is chosen from the ARN, the token goes in the
    /// `Authorization` header and nowhere else, and the body names the profile
    /// and the origin the service expects from an editor.
    static func request(credential: KiroCredential, profileArn: String?) -> URLRequest {
        let arn = credential.profileArn ?? profileArn
        var request = URLRequest(url: KiroAccount.endpoint(for: arn))
        request.httpMethod = "POST"
        request.timeoutInterval = KiroAccount.timeout
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-amz-json-1.0", forHTTPHeaderField: "Content-Type")
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        request.setValue(KiroAccount.userAgent, forHTTPHeaderField: "User-Agent")

        var body: [String: Any] = ["origin": "AI_EDITOR"]
        if let arn { body["profileArn"] = arn }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    /// Reads the answer.
    ///
    /// The shape, from the IDE's own use of it: `usageBreakdownList` holds
    /// one entry per resource, and the one typed `CREDIT` is the plan. Its
    /// `*WithPrecision` fields are preferred when they are numbers and the
    /// plain ones used when they are not. Other entries with names like
    /// `FREE_TRIAL` or `BONUS` are pools spent before the plan, and are kept
    /// as such. Anything typed as something else — a token quota, say — is
    /// not a credit figure and is not shown as one.
    static func report(from data: Data) -> KiroUsageReport? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let breakdowns = (root["usageBreakdownList"] as? [[String: Any]]) ?? []

        let credit = breakdowns.first { ($0["resourceType"] as? String) == "CREDIT" }
            ?? breakdowns.first { ($0["resourceType"] as? String ?? "").isEmpty }
        guard let credit,
              let used = amount(credit["currentUsageWithPrecision"]) ?? amount(credit["currentUsage"]),
              let limit = amount(credit["usageLimitWithPrecision"]) ?? amount(credit["usageLimit"]),
              limit > 0
        else { return nil }

        let overage = amount(credit["currentOverages"]) ?? max(0, used - limit)

        let subscription = root["subscriptionInfo"] as? [String: Any] ?? [:]
        let plan = (subscription["subscriptionTitle"] as? String)
            ?? (subscription["type"] as? String)

        let markers = ["FREE_TRIAL", "FREETRIAL", "TRIAL", "BONUS", "PROMO", "GIFT", "WELCOME"]
        let bonuses = breakdowns.compactMap { entry -> KiroUsageReport.Pool? in
            let type = (entry["resourceType"] as? String ?? "").uppercased()
            guard type != "CREDIT", markers.contains(where: type.contains),
                  let used = amount(entry["currentUsageWithPrecision"]) ?? amount(entry["currentUsage"]),
                  let limit = amount(entry["usageLimitWithPrecision"]) ?? amount(entry["usageLimit"]),
                  limit > 0
            else { return nil }
            let name = (entry["title"] as? String) ?? (entry["displayName"] as? String)
                ?? type.replacingOccurrences(of: "_", with: " ").capitalized
            return KiroUsageReport.Pool(name: String(name.prefix(40)), used: used, limit: limit)
        }

        return KiroUsageReport(
            used: used,
            limit: limit,
            overage: overage,
            plan: plan.map { String($0.prefix(60)) },
            resetsAt: JSONNumber.double(root["nextDateReset"]).map { Date(timeIntervalSince1970: $0) },
            bonuses: Array(bonuses.prefix(3))
        )
    }

    /// A finite, non-negative, believable number, or nothing.
    private static func amount(_ raw: Any?) -> Double? {
        guard let value = JSONNumber.double(raw), value.isFinite, value >= 0, value <= 1_000_000
        else { return nil }
        return value
    }

    /// The report in the panel's terms.
    ///
    /// The plan is one window, labelled by what it is rather than by a span:
    /// Kiro's cycle is a calendar month with a reset date, not a rolling
    /// number of minutes. The fraction can pass 1 on a plan with overage,
    /// and the panel already knows to keep that rather than clamp it.
    static func usage(from report: KiroUsageReport, at observedAt: Date) -> ToolUsage {
        var limits = [
            UsageLimit(
                label: "monthly credits",
                usedFraction: report.used / report.limit,
                resetsAt: report.resetsAt,
                quantity: UsageQuantity(used: report.used, limit: report.limit, unit: "credits")
            ),
        ]
        for pool in report.bonuses {
            limits.append(UsageLimit(
                label: pool.name.lowercased(),
                usedFraction: pool.used / pool.limit,
                resetsAt: nil,
                quantity: UsageQuantity(used: pool.used, limit: pool.limit, unit: "credits")
            ))
        }
        return ToolUsage(tool: .kiroCLI, limits: limits, plan: report.plan, observedAt: observedAt)
    }
}

// ─ Keeping the answer ───────────────────────────────────────────────────────

/// Holds the last answer and asks for a new one on its own clock.
///
/// A `UsageReader` like the others, with the difference that its answer takes
/// a network round trip to produce. So `usage()` never waits: it returns what
/// was last heard and, if a new ask is due, starts one on a background queue.
/// The inventory calls this every minute from the main thread and must not
/// notice.
final class KiroAccountStore: UsageReader {

    static let shared = KiroAccountStore()

    /// Where things stand, for the sentence in the Usage tab.
    enum Status: Equatable {
        /// The setting is off.
        case off
        /// On, and no answer yet.
        case asking
        case answered(Date)
        case failed(String, Date)
    }

    private let store: URL
    private let session: URLSession
    private let lock = NSLock()
    private var current: ToolUsage?
    private var currentStatus: Status = .off
    private var lastAttempt: Date = .distantPast
    private var inFlight = false

    init(store: URL = KiroAccount.defaultStore) {
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = KiroAccount.timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        // No redirects. A token must never be replayed to a host this file
        // did not name; see `NoRedirects`.
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return KiroAccount.isEnabled ? currentStatus : .off
    }

    func usage() -> ToolUsage? {
        guard KiroAccount.isEnabled else {
            forget()
            return nil
        }
        refreshIfDue()
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Drop what was heard. Turning the setting off means the figures go
    /// too — they were fetched under a permission that no longer stands.
    func forget() {
        lock.lock()
        current = nil
        currentStatus = .off
        lastAttempt = .distantPast
        lock.unlock()
    }

    /// Ask now if it has been long enough, or if asked to regardless.
    func refreshIfDue(force: Bool = false, now: Date = Date()) {
        guard KiroAccount.isEnabled else { return }
        lock.lock()
        let due = !inFlight && (force || now.timeIntervalSince(lastAttempt) >= KiroAccount.interval)
        if due {
            inFlight = true
            lastAttempt = now
            if case .off = currentStatus { currentStatus = .asking }
        }
        lock.unlock()
        guard due else { return }
        DispatchQueue.global(qos: .utility).async { [self] in fetch() }
    }

    private func fetch() {
        let now = Date()
        switch KiroAuthStore.credential(in: store, now: now) {
        case .missing:
            finish(nil, .failed("Kiro CLI is not signed in on this Mac — run kiro-cli login.", now))
        case .expired:
            finish(nil, .failed(
                "Kiro's sign-in token has run out. Kiro CLI refreshes it when it runs; "
                    + "start a session and this fills in.", now
            ))
        case .found(let credential):
            let request = KiroUsageAPI.request(
                credential: credential,
                profileArn: KiroAuthStore.profileArn(in: store)
            )
            let task = session.dataTask(with: request) { [self] data, response, error in
                let at = Date()
                if let error {
                    finish(nil, .failed(Self.explain(error, host: request.url?.host), at))
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else {
                    finish(nil, .failed(Self.explain(code, host: request.url?.host), at))
                    return
                }
                guard let data, let report = KiroUsageAPI.report(from: data) else {
                    finish(nil, .failed("Kiro answered in a shape Corral does not read.", at))
                    return
                }
                finish(KiroUsageAPI.usage(from: report, at: at), .answered(at))
            }
            task.resume()
        }
    }

    private func finish(_ usage: ToolUsage?, _ status: Status) {
        lock.lock()
        // A failure keeps the last good figure, with its own age on it; the
        // status says the newer ask did not land.
        if let usage { current = usage }
        currentStatus = status
        inFlight = false
        lock.unlock()
    }

    /// The status code in words that say what to do, where there is anything.
    ///
    /// The host is a literal in this file, which is the safe way to send a
    /// token and the fragile way to name a server: if Kiro moves it, every
    /// copy of Corral is wrong at once. That case has a shape — the name no
    /// longer resolves, or the host answers with nothing at that path — and
    /// it gets a sentence that says what happened and where to report it,
    /// rather than a bare error code.
    static func explain(_ code: Int, host: String? = nil) -> String {
        switch code {
        case 401, 403:
            return "Kiro refused the sign-in token. Sign in again with kiro-cli login."
        case 404, 410, 301, 302, 307, 308:
            return moved(host)
        case 429:
            return "Kiro is rate-limiting the request; it will be asked again later."
        case 500...:
            return "Kiro's servers answered with an error (HTTP \(code))."
        default:
            return "Kiro answered HTTP \(code)."
        }
    }

    static func explain(_ error: Error, host: String? = nil) -> String {
        let code = (error as NSError).code
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return moved(host)
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "Not connected to the internet; Kiro will be asked again later."
        case NSURLErrorTimedOut:
            return "Kiro's servers did not answer in time; they will be asked again later."
        default:
            return "Could not reach Kiro: \(error.localizedDescription)"
        }
    }

    private static func moved(_ host: String?) -> String {
        "Kiro's servers did not answer at the address Corral knows"
            + (host.map { " (\($0))" } ?? "")
            + ". The address may have moved: check for a newer Corral, or report it at "
            + "\(BuildInfo.supportURL.host ?? "GitHub")\(BuildInfo.supportURL.path)."
    }
}

/// Refuses every redirect.
///
/// A bearer token in a request that follows a redirect goes wherever the
/// redirect points. The hosts this file names are the only ones it may go to,
/// so a 3xx is treated as the failure it would be, not as a hop.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
