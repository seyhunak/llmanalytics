import Foundation
import Observation

/// One quota bar: "5-hour window 42% used, resets in 2h".
struct QuotaWindow: Identifiable, Hashable, Sendable {
    var id: String { label }
    let label: String
    let usedFraction: Double?        // 0...1, nil when unlimited/unknown
    var usedText: String? = nil      // "120 / 300 requests"
    var resetsAt: Date? = nil
}

enum ProviderStatus: Hashable, Sendable {
    case ok
    case notDetected(String)
    case disconnected       // live lookup available but not enabled by the user
    case error(String)
}

struct ProviderUsage: Identifiable, Hashable, Sendable {
    var id: String { provider }
    let provider: String
    let symbol: String
    var plan: String?
    var status: ProviderStatus
    var windows: [QuotaWindow] = []
    var notes: [String] = []
    var updatedAt: Date? = nil
    var supportsLive = false
}

/// A plan the user tracks by hand (e.g. Devin, Windsurf, ChatGPT) for monthly spend totals.
struct ManualPlan: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var monthlyPrice: Double
    var renewalDay: Int = 1
    var quotaLabel: String = ""
    var quotaUsed: Double = 0
    var quotaTotal: Double = 0
}

@MainActor
@Observable
final class SubscriptionService {
    static let shared = SubscriptionService()

    private(set) var providers: [ProviderUsage] = []
    private(set) var isRefreshing = false
    var manualPlans: [ManualPlan] = [] { didSet { saveManual() } }

    /// Live lookups use the vendor's own API with the token that tool already stored locally.
    /// They are opt-in per provider.
    var liveEnabled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "liveProviders") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "liveProviders"); Task { await refresh() } }
    }

    private var timer: Timer?

    private init() {
        if let d = UserDefaults.standard.data(forKey: "manualPlans"),
           let p = try? JSONDecoder().decode([ManualPlan].self, from: d) { manualPlans = p }
    }

    private func saveManual() {
        if let d = try? JSONEncoder().encode(manualPlans) { UserDefaults.standard.set(d, forKey: "manualPlans") }
    }

    var monthlySubscriptionTotal: Double { manualPlans.reduce(0) { $0 + $1.monthlyPrice } }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func setLive(_ provider: String, _ on: Bool) {
        var s = liveEnabled
        if on { s.insert(provider) } else { s.remove(provider) }
        liveEnabled = s
    }

    func refresh() async {
        isRefreshing = true
        let live = liveEnabled
        async let claude = Self.claude(live: live.contains("Claude Code"))
        async let codex = Self.codex()
        async let copilot = Self.copilot(live: live.contains("GitHub Copilot"))
        async let cursor = Self.cursor(live: live.contains("Cursor"))
        providers = await [claude, codex, copilot, cursor]
        isRefreshing = false
    }

    // MARK: - Claude Code

    nonisolated static func claudeCredentials() async -> [String: Any]? {
        if let out = await Shell.run("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]),
           let obj = parseJSONObject(out.trimmingCharacters(in: .whitespacesAndNewlines)) { return obj }
        return FS.readJSON(AppPaths.expand(".claude/.credentials.json")) as? [String: Any]
    }

    nonisolated static func claude(live: Bool) async -> ProviderUsage {
        var p = ProviderUsage(provider: "Claude Code", symbol: "sparkle", status: .ok, supportsLive: true)
        guard FS.exists(AppPaths.expand(".claude")) else {
            p.status = .notDetected("~/.claude not found"); return p
        }
        let config = FS.readJSON(AppPaths.expand(".claude.json")) as? [String: Any]
        if let acct = config?.obj("oauthAccount") {
            if let org = acct.str("organizationName") { p.notes.append(org) }
            if let b = acct.str("billingType") { p.notes.append("Billing: \(b.replacingOccurrences(of: "_", with: " "))") }
        }
        guard live else { p.status = .disconnected; return p }
        guard let creds = await claudeCredentials(), let oauth = creds.obj("claudeAiOauth"),
              let token = oauth.str("accessToken") else {
            p.status = .error("No Claude Code login found in Keychain"); return p
        }
        p.plan = oauth.str("subscriptionType")?.capitalized
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("LLMAnalytics", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { p.status = .error("Network error"); return p }
        guard http.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            p.status = .error(http.statusCode == 401 ? "Login expired — run claude once to refresh" : "HTTP \(http.statusCode)")
            return p
        }
        let names: [(String, String)] = [("five_hour", "5-hour session"), ("seven_day", "Weekly (all models)"),
                                         ("seven_day_opus", "Weekly Opus"), ("seven_day_sonnet", "Weekly Sonnet")]
        for (k, label) in names {
            guard let w = j.obj(k), let u = w.dbl("utilization") else { continue }
            p.windows.append(QuotaWindow(label: label, usedFraction: u / 100, resetsAt: Dates.parse(w["resets_at"])))
        }
        if let extra = j.obj("extra_usage"), extra["is_enabled"] as? Bool == true {
            let used = extra.dbl("used_credits") ?? 0, limit = extra.dbl("monthly_limit") ?? 0
            p.windows.append(QuotaWindow(label: "Extra usage", usedFraction: limit > 0 ? used / limit : nil,
                                         usedText: String(format: "$%.2f of $%.0f", used / 100, limit / 100)))
        }
        p.updatedAt = Date()
        return p
    }

    // MARK: - Codex (offline: read from Codex's own session logs)

    nonisolated static func codex() async -> ProviderUsage {
        var p = ProviderUsage(provider: "Codex", symbol: "terminal", status: .ok)
        guard FS.exists(CodexSource.home) else { p.status = .notDetected("~/.codex not found"); return p }
        if let auth = FS.readJSON((CodexSource.home as NSString).appendingPathComponent("auth.json")) as? [String: Any],
           let idToken = auth.obj("tokens")?.str("id_token"), let claims = JWT.payload(idToken),
           let a = claims.obj("https://api.openai.com/auth") {
            p.plan = a.str("chatgpt_plan_type")?.capitalized
            if let until = Dates.parse(a["chatgpt_subscription_active_until"]) {
                p.notes.append("Active until \(until.formatted(date: .abbreviated, time: .omitted))")
            }
        } else if (FS.readJSON((CodexSource.home as NSString).appendingPathComponent("auth.json")) as? [String: Any])?.str("OPENAI_API_KEY") != nil {
            p.plan = "API key"
        }
        guard let rl = CodexSource().latestRateLimits() else {
            p.notes.append("No rate-limit data yet — it appears after your next Codex turn.")
            return p
        }
        if p.plan == nil { p.plan = rl.plan?.capitalized }
        func label(_ minutes: Int) -> String {
            switch minutes {
            case 300: "5-hour window"
            case 10080: "Weekly"
            case 43200...44640: "Monthly"
            case let m where m >= 1440: "\(m / 1440)-day window"
            default: "\(minutes / 60)-hour window"
            }
        }
        for w in [rl.primary, rl.secondary].compactMap({ $0 }) {
            p.windows.append(QuotaWindow(label: label(w.windowMinutes), usedFraction: w.used / 100, resetsAt: w.resetsAt))
        }
        if let c = rl.creditsBalance { p.notes.append("Credits: \(c)") }
        p.updatedAt = rl.observedAt
        p.notes.append("As of your last Codex turn (\(rl.observedAt.formatted(.relative(presentation: .named))))")
        return p
    }

    // MARK: - GitHub Copilot

    nonisolated static func copilot(live: Bool) async -> ProviderUsage {
        var p = ProviderUsage(provider: "GitHub Copilot", symbol: "airplane", status: .ok, supportsLive: true)
        let detected = FS.exists(AppPaths.expand(".copilot")) || !CopilotVSCodeSource().storageRoots.isEmpty
        guard detected else { p.status = .notDetected("No Copilot CLI or VS Code data"); return p }
        guard live else { p.status = .disconnected; return p }
        guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"].first(where: FS.exists),
              let token = await Shell.run(gh, ["auth", "token"])?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            p.status = .error("Needs the GitHub CLI signed in (gh auth login)"); return p
        }
        var req = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("LLMAnalytics", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else {
            p.status = .error("Network error"); return p
        }
        guard http.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            p.status = .error("HTTP \(http.statusCode)"); return p
        }
        p.plan = (j.str("copilot_plan") ?? j.str("access_type_sku"))?.replacingOccurrences(of: "_", with: " ").capitalized
        let reset = Dates.parse(j["quota_reset_date_utc"]) ?? j.str("quota_reset_date").flatMap { Dates.parse($0 + "T00:00:00Z") }
        for (k, label) in [("premium_interactions", "Premium requests"), ("chat", "Chat"), ("completions", "Completions")] {
            guard let q = j.obj("quota_snapshots")?.obj(k) else { continue }
            if q["unlimited"] as? Bool == true {
                p.windows.append(QuotaWindow(label: label, usedFraction: nil, usedText: "Unlimited"))
            } else {
                let ent = q.dbl("entitlement") ?? 0, rem = q.dbl("remaining") ?? 0
                p.windows.append(QuotaWindow(label: label, usedFraction: ent > 0 ? (ent - rem) / ent : nil,
                                             usedText: String(format: "%.0f / %.0f used", ent - rem, ent), resetsAt: reset))
            }
        }
        p.updatedAt = Date()
        return p
    }

    // MARK: - Cursor

    nonisolated static func cursor(live: Bool) async -> ProviderUsage {
        var p = ProviderUsage(provider: "Cursor", symbol: "cursorarrow.rays", status: .ok, supportsLive: true)
        guard let db = SQLiteDB(path: CursorSource.globalDB) else { p.status = .notDetected("Cursor is not installed"); return p }
        func item(_ k: String) -> String? { db.rows("SELECT value FROM ItemTable WHERE key=?", [k]).first?[0] ?? nil }
        p.plan = item("cursorAuth/stripeMembershipType")?.capitalized
        guard live else { p.status = .disconnected; return p }
        guard let token = item("cursorAuth/accessToken"), let sub = JWT.payload(token)?.str("sub") else {
            p.status = .error("Not signed in to Cursor"); return p
        }
        let user = sub.components(separatedBy: "|").last ?? sub
        var req = URLRequest(url: URL(string: "https://cursor.com/api/usage?user=\(user)")!)
        req.setValue("WorkosCursorSessionToken=\(user)%3A%3A\(token)", forHTTPHeaderField: "Cookie")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse,
              http.statusCode == 200, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            p.status = .error("Cursor usage endpoint unavailable"); return p
        }
        let monthStart = Dates.parse(j["startOfMonth"])
        let reset = monthStart.flatMap { Calendar.current.date(byAdding: .month, value: 1, to: $0) }
        for (k, v) in j.sorted(by: { $0.key < $1.key }) {
            guard let m = v as? [String: Any] else { continue }
            let used = m.int("numRequests"); let max = m.int("maxRequestUsage")
            p.windows.append(QuotaWindow(label: k, usedFraction: max > 0 ? Double(used) / Double(max) : nil,
                                         usedText: max > 0 ? "\(used) / \(max) requests" : "\(used) requests", resetsAt: reset))
        }
        p.updatedAt = Date()
        return p
    }
}

enum JWT {
    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        guard let d = Data(base64Encoded: b) else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
}

enum Shell {
    /// Runs a binary (no shell) off the Swift concurrency pool and returns stdout,
    /// or nil on failure / non-zero exit / timeout.
    static func run(_ exe: String, _ args: [String], timeout: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(returning: runBlocking(exe, args, timeout: timeout)) }
        }
    }

    static func runBlocking(_ exe: String, _ args: [String], timeout: TimeInterval) -> String? {
        guard FS.exists(exe) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        // Drain stdout while the process runs so a large output can't fill the pipe and hang it.
        var data = Data()
        let reader = DispatchQueue(label: "shell.read")
        reader.async { data = out.fileHandleForReading.readDataToEndOfFile() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return nil }
        reader.sync {}
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
