import Foundation
import Testing
@testable import LLMAnalytics

private func session(_ id: String, editor: Editor = .claudeCode, model: String = "claude-opus-5-5",
                     tokens: TokenUsage, at t: Date = Date(), prompts: Int = 1, tools: [String: Int] = [:]) -> SessionSummary {
    SessionSummary(nativeID: id, editor: editor, sourcePath: "/x", title: id, project: "/p", start: t, end: t,
                   userMessages: prompts, assistantMessages: prompts, tools: tools,
                   events: [UsageEvent(timestamp: t, model: model, tokens: tokens, reportedCost: nil)], userTimes: [t])
}

@Suite struct BudgetAlertTests {
    @Test func budgetWarnsThenExceeds() {
        let s = AlertSettings(enabled: true, threshold: 0.8, runawayCost: 0)
        let now = Date()
        let warn = AlertRules.budgetAlerts([BudgetStatus(period: .day, limit: 10, spent: 8.5)], settings: s, now: now)
        #expect(warn.count == 1 && warn[0].key.hasSuffix(".warn"))
        let over = AlertRules.budgetAlerts([BudgetStatus(period: .day, limit: 10, spent: 12)], settings: s, now: now)
        #expect(over.count == 1 && over[0].key.hasSuffix(".100") && over[0].key != warn[0].key)
        #expect(AlertRules.budgetAlerts([BudgetStatus(period: .month, limit: 100, spent: 50)], settings: s).isEmpty)
    }

    @Test func runawayAlertsAtDoublings() {
        let s = AlertSettings(enabled: true, threshold: 0.8, runawayCost: 10)
        // Opus 5.5 output is $20 / 1M, so 1M output = $20 (2× the threshold).
        let big = session("big", tokens: TokenUsage(output: 1_000_000))
        let small = session("small", tokens: TokenUsage(output: 100_000))
        let a = AlertRules.runawayAlerts([big, small], settings: s)
        #expect(a.map(\.key) == ["runaway.claudeCode:big.2"])
        #expect(AlertRules.runawayAlerts([big], settings: AlertSettings(runawayCost: 0)).isEmpty)
    }

    @Test func quotaAlertsIncludeManualPlans() {
        let s = AlertSettings()
        let p = ProviderUsage(provider: "Claude Code", symbol: "x", status: .ok,
                              windows: [QuotaWindow(label: "5-hour", usedFraction: 0.85), QuotaWindow(label: "Weekly", usedFraction: 0.3)])
        let m = ManualPlan(name: "Devin", monthlyPrice: 500, quotaLabel: "ACUs", quotaUsed: 240, quotaTotal: 250)
        let a = AlertRules.quotaAlerts([p], manual: [m], settings: s)
        #expect(a.count == 2)
        #expect(a.contains { $0.title.contains("5-hour") } && a.contains { $0.title.hasPrefix("Devin") })
    }

    @Test func weekCostCountsCalendarWeek() {
        let now = Date()
        let s = session("w", tokens: TokenUsage(output: 50_000), at: now.addingTimeInterval(-60))
        let l = LiveSnapshot.compute(all: [s], now: now)
        #expect(abs(l.weekCost - 1.0) < 1e-9 && abs(l.todayCost - 1.0) < 1e-9)
        #expect(l.budgets([.day: 2]).first?.fraction == 0.5)
    }
}

@Suite struct PlanValueTests {
    @Test func catalogPrices() {
        #expect(PlanCatalog.price(provider: "Claude Code", plan: "Max") == 100)
        #expect(PlanCatalog.price(provider: "Codex", plan: "Plus") == 20)
        #expect(PlanCatalog.price(provider: "Codex", plan: "Free") == nil)
        #expect(PlanCatalog.price(provider: "GitHub Copilot", plan: "Pro Plus") == 39)
        #expect(PlanCatalog.price(provider: "Cursor", plan: "Pro") == 20)
    }

    @Test func manualPlanOverridesDetectedAndProjects() {
        let cal = Calendar.current
        let month = cal.dateInterval(of: .month, for: Date())!
        let now = month.start.addingTimeInterval(month.duration / 2)       // halfway through
        let s = session("a", tokens: TokenUsage(output: 2_500_000), at: now.addingTimeInterval(-60))  // $50
        let detected = ProviderUsage(provider: "Claude Code", symbol: "x", plan: "Max", status: .ok)
        let rowsDetected = PlanValue.rows(sessions: [s], providers: [detected], manual: [], now: now)
        #expect(rowsDetected.count == 1 && rowsDetected[0].monthlyPrice == 100)
        #expect(abs(rowsDetected[0].projected - 100) < 0.01 && abs(rowsDetected[0].multiple - 1) < 0.01)
        let manual = ManualPlan(name: "Claude Max 20x", monthlyPrice: 200, editor: .claudeCode)
        let rows = PlanValue.rows(sessions: [s], providers: [detected], manual: [manual], now: now)
        #expect(rows.map(\.name) == ["Claude Max 20x"])
    }
}

@Suite struct WhatIfTests {
    @Test func repricesOnTarget() {
        let s = session("a", tokens: TokenUsage(input: 1_000_000, output: 1_000_000))   // opus 5.5: $4 + $20
        let rows = WhatIf.reprice([s], on: "claude-sonnet-5-5")                          // sonnet: $2 + $10
        #expect(rows.count == 1)
        #expect(abs(rows[0].actual - 24) < 1e-9 && abs(rows[0].repriced - 12) < 1e-9)
    }

    @Test func flagsLightOpusSessionsOnly() {
        // Light: one prompt, lots of input, little output, no tools.
        let light = session("light", tokens: TokenUsage(input: 400_000, output: 1_000))
        // Heavy agentic run: many tools and lots of output per prompt.
        let heavy = session("heavy", tokens: TokenUsage(input: 400_000, output: 200_000), prompts: 2, tools: ["Edit": 40])
        let sonnet = session("sonnet", model: "claude-sonnet-5-5", tokens: TokenUsage(input: 900_000))
        let c = WhatIf.overpowered([light, heavy, sonnet])
        #expect(c.map(\.session.nativeID) == ["light"])
        #expect(c[0].savings > 0)
    }
}
