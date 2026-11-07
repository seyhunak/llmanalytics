import Foundation
import UserNotifications

// MARK: - Budgets

enum BudgetPeriod: String, CaseIterable, Identifiable, Sendable {
    case day, week, month
    var id: String { rawValue }
    var title: String { switch self { case .day: "Daily"; case .week: "Weekly"; case .month: "Monthly" } }
    var noun: String { switch self { case .day: "today"; case .week: "this week"; case .month: "this month" } }
    var defaultsKey: String { "budget.\(rawValue)" }

    /// Stable id for the current period, used to send each alert once per period.
    func periodID(_ now: Date = Date()) -> String {
        let cal = Calendar.current
        switch self {
        case .day:
            let c = cal.dateComponents([.year, .month, .day], from: now)
            return "\(c.year!)-\(c.month!)-\(c.day!)"
        case .week:
            let start = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
            return "w\(Int(start.timeIntervalSince1970))"
        case .month:
            let c = cal.dateComponents([.year, .month], from: now)
            return "\(c.year!)-\(c.month!)"
        }
    }
}

/// User-set limits, in USD at API list prices. 0 means "no budget".
enum Budgets {
    static func limit(_ p: BudgetPeriod) -> Double { UserDefaults.standard.double(forKey: p.defaultsKey) }
    static var all: [BudgetPeriod: Double] {
        Dictionary(uniqueKeysWithValues: BudgetPeriod.allCases.map { ($0, limit($0)) }).filter { $0.value > 0 }
    }
}

struct BudgetStatus: Identifiable, Sendable {
    let period: BudgetPeriod
    let limit: Double
    let spent: Double
    var id: BudgetPeriod { period }
    var fraction: Double { limit > 0 ? spent / limit : 0 }
    var window: QuotaWindow {
        QuotaWindow(label: "\(period.title) budget", usedFraction: fraction,
                    usedText: "\(Fmt.cost(spent)) of \(Fmt.cost(limit))")
    }
}

extension LiveSnapshot {
    func spent(_ p: BudgetPeriod) -> Double {
        switch p { case .day: todayCost; case .week: weekCost; case .month: monthCost }
    }
    func budgets(_ limits: [BudgetPeriod: Double] = Budgets.all) -> [BudgetStatus] {
        BudgetPeriod.allCases.compactMap { p in limits[p].map { BudgetStatus(period: p, limit: $0, spent: spent(p)) } }
    }
}

// MARK: - Alert rules (pure, so they can be tested)

struct PendingAlert: Hashable, Sendable {
    let key: String     // dedupe key: the same alert is never sent twice
    let title: String
    let body: String
}

struct AlertSettings: Sendable {
    var enabled = true
    var threshold = 0.8                  // warn at this fraction of a budget or quota
    var runawayCost = 10.0               // warn when one live session passes this (0 = off)

    static var current: AlertSettings {
        let d = UserDefaults.standard
        var s = AlertSettings()
        if d.object(forKey: "alerts.enabled") != nil { s.enabled = d.bool(forKey: "alerts.enabled") }
        if d.object(forKey: "alerts.threshold") != nil { s.threshold = d.double(forKey: "alerts.threshold") }
        if d.object(forKey: "alerts.runawayCost") != nil { s.runawayCost = d.double(forKey: "alerts.runawayCost") }
        return s
    }
}

enum AlertRules {
    static func budgetAlerts(_ statuses: [BudgetStatus], settings: AlertSettings, now: Date = Date()) -> [PendingAlert] {
        statuses.compactMap { b in
            let pid = b.period.periodID(now)
            if b.fraction >= 1 {
                return PendingAlert(key: "budget.\(b.period.rawValue).\(pid).100",
                                    title: "\(b.period.title) budget exceeded",
                                    body: "\(Fmt.cost(b.spent)) spent \(b.period.noun), over your \(Fmt.cost(b.limit)) budget.")
            }
            if b.fraction >= settings.threshold {
                return PendingAlert(key: "budget.\(b.period.rawValue).\(pid).warn",
                                    title: "\(Fmt.percent(b.fraction)) of \(b.period.title.lowercased()) budget used",
                                    body: "\(Fmt.cost(b.spent)) of \(Fmt.cost(b.limit)) spent \(b.period.noun).")
            }
            return nil
        }
    }

    /// One alert per session each time its cost passes 1×, 2×, 4×, 8×… the runaway threshold.
    static func runawayAlerts(_ active: [SessionSummary], settings: AlertSettings) -> [PendingAlert] {
        guard settings.runawayCost > 0 else { return [] }
        return active.compactMap { s in
            let ratio = s.cost / settings.runawayCost
            guard ratio >= 1 else { return nil }
            let level = 1 << Int(log2(ratio))
            return PendingAlert(key: "runaway.\(s.id).\(level)",
                                title: "Expensive session running in \(s.editor.displayName)",
                                body: "\"\(s.title)\" has reached \(Fmt.cost(s.cost)) (\(Fmt.tokens(s.tokens.total)) tokens) on \(Fmt.model(s.primaryModel)).")
        }
    }

    static func quotaAlerts(_ providers: [ProviderUsage], manual: [ManualPlan], settings: AlertSettings) -> [PendingAlert] {
        var out: [PendingAlert] = []
        for p in providers {
            for w in p.windows {
                guard let f = w.usedFraction, f >= settings.threshold else { continue }
                let reset = w.resetsAt.map { String(Int($0.timeIntervalSince1970 / 3600)) } ?? "none"
                let level = f >= 1 ? "100" : "warn"
                let when = w.resetsAt.map { " Resets \(Fmt.relative($0))." } ?? ""
                out.append(PendingAlert(key: "quota.\(p.provider).\(w.label).\(reset).\(level)",
                                        title: "\(p.provider): \(Fmt.percent(f)) of \(w.label) used",
                                        body: ((w.usedText.map { "\($0)." } ?? "") + when).trimmingCharacters(in: .whitespaces)))
            }
        }
        for m in manual where m.quotaTotal > 0 {
            let f = m.quotaUsed / m.quotaTotal
            guard f >= settings.threshold else { continue }
            out.append(PendingAlert(key: "quota.manual.\(m.id).\(Int(m.quotaUsed)).\(f >= 1 ? "100" : "warn")",
                                    title: "\(m.name): \(Fmt.percent(f)) of \(m.quotaLabel.isEmpty ? "quota" : m.quotaLabel) used",
                                    body: "\(Fmt.number(m.quotaUsed)) of \(Fmt.number(m.quotaTotal))."))
        }
        return out
    }
}

// MARK: - Delivery

/// Posts macOS notifications for budget, quota and runaway-session alerts, at most once each.
@MainActor
final class AlertCenter {
    static let shared = AlertCenter()
    private let sentKey = "alerts.sent"
    private var authorized: Bool?

    /// Notifications need a real app bundle; `swift run` and tests have none.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func requestPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, _ in
            Task { @MainActor in self.authorized = ok }
        }
    }

    func evaluate(live: LiveSnapshot) {
        let s = AlertSettings.current
        guard s.enabled else { return }
        deliver(AlertRules.budgetAlerts(live.budgets(), settings: s) + AlertRules.runawayAlerts(live.activeSessions, settings: s))
    }

    func evaluate(providers: [ProviderUsage], manual: [ManualPlan]) {
        let s = AlertSettings.current
        guard s.enabled else { return }
        deliver(AlertRules.quotaAlerts(providers, manual: manual, settings: s))
    }

    func sendTest() {
        post(PendingAlert(key: "test", title: "LLM Analytics alerts are on",
                          body: "You'll be notified about budgets, quotas and runaway sessions."))
    }

    private func deliver(_ alerts: [PendingAlert]) {
        guard !alerts.isEmpty else { return }
        var sent = UserDefaults.standard.dictionary(forKey: sentKey) as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        sent = sent.filter { now - $0.value < 45 * 86_400 }   // forget alerts older than 45 days
        for a in alerts where sent[a.key] == nil {
            sent[a.key] = now
            post(a)
        }
        UserDefaults.standard.set(sent, forKey: sentKey)
    }

    private func post(_ a: PendingAlert) {
        guard canNotify else { print("[alert] \(a.title) — \(a.body)"); return }
        let content = UNMutableNotificationContent()
        content.title = a.title
        content.body = a.body
        content.sound = .default
        let req = UNNotificationRequest(identifier: a.key, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
