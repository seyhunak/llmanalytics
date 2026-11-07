import Foundation

// MARK: - Plan value: what you pay vs what the same usage would cost on the API

enum PlanCatalog {
    /// Editors whose usage a detected provider plan covers.
    static func editors(for provider: String) -> [Editor] {
        switch provider {
        case "Claude Code": [.claudeCode]
        case "Codex": [.codex]
        case "GitHub Copilot": [.copilotCLI, .copilotVSCode]
        case "Cursor": [.cursor]
        default: []
        }
    }

    /// List price (USD/month) for a plan name a tool reports. nil when unknown or free.
    static func price(provider: String, plan: String?) -> Double? {
        guard let p = plan?.lowercased().replacingOccurrences(of: "_", with: " ") else { return nil }
        switch provider {
        case "Claude Code":
            if p.contains("20x") { return 200 }
            if p.contains("max") { return 100 }
            if p.contains("team") { return 30 }
            if p.contains("pro") { return 20 }
        case "Codex":
            if p.contains("pro") { return 200 }
            if p.contains("plus") { return 20 }
            if p.contains("team") || p.contains("business") { return 30 }
        case "GitHub Copilot":
            if p.contains("pro+") || p.contains("pro plus") || p.contains("enterprise") { return 39 }
            if p.contains("business") { return 19 }
            if p.contains("pro") || p.contains("individual") { return 10 }
        case "Cursor":
            if p.contains("ultra") { return 200 }
            if p.contains("pro+") || p.contains("pro plus") { return 60 }
            if p.contains("business") || p.contains("team") { return 40 }
            if p.contains("pro") { return 20 }
        default: break
        }
        return nil
    }
}

struct PlanValueRow: Identifiable, Sendable {
    let name: String
    let detail: String
    let editors: [Editor]
    let monthlyPrice: Double
    let apiSpendToDate: Double     // this calendar month
    let projected: Double          // month-to-date extrapolated to the full month
    var id: String { name }
    /// How many times over the plan pays for itself (projected API cost ÷ price).
    var multiple: Double { monthlyPrice > 0 ? projected / monthlyPrice : 0 }
}

enum PlanValue {
    static func rows(sessions: [SessionSummary], providers: [ProviderUsage], manual: [ManualPlan],
                     now: Date = Date()) -> [PlanValueRow] {
        let cal = Calendar.current
        guard let month = cal.dateInterval(of: .month, for: now) else { return [] }
        let elapsed = max(now.timeIntervalSince(month.start), 3600)
        let scale = month.duration / elapsed

        var spend: [Editor: Double] = [:]
        for s in sessions where s.end >= month.start {
            for e in s.events where e.timestamp >= month.start && e.timestamp <= now { spend[s.editor, default: 0] += e.cost }
        }
        func row(_ name: String, _ detail: String, _ editors: [Editor], _ price: Double) -> PlanValueRow {
            let mtd = editors.reduce(0) { $0 + (spend[$1] ?? 0) }
            return PlanValueRow(name: name, detail: detail, editors: editors, monthlyPrice: price,
                                apiSpendToDate: mtd, projected: mtd * scale)
        }

        var out: [PlanValueRow] = []
        // A manual plan linked to an editor replaces the detected plan for that editor.
        let manualEditors = Set(manual.compactMap(\.editor))
        for p in providers {
            let eds = PlanCatalog.editors(for: p.provider)
            guard !eds.isEmpty, manualEditors.isDisjoint(with: eds),
                  let price = PlanCatalog.price(provider: p.provider, plan: p.plan) else { continue }
            out.append(row(p.provider, "\(p.plan ?? "") · detected", eds, price))
        }
        for m in manual where m.monthlyPrice > 0 {
            let eds = m.editor.map { [$0] } ?? []
            out.append(row(m.name, eds.isEmpty ? "manual plan · not linked to an editor" : "manual plan", eds, m.monthlyPrice))
        }
        return out.sorted { $0.multiple > $1.multiple }
    }
}

// MARK: - What-if pricing

enum WhatIf {
    static let targets: [String] = [
        "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1",
        "gpt-5", "gpt-5-mini", "gemini-2.5-pro", "gemini-2.5-flash", "qwen3-coder-plus",
    ]

    struct Row: Identifiable, Sendable {
        let model: String
        let actual: Double
        let repriced: Double
        let tokens: Int
        var id: String { model }
        var delta: Double { repriced - actual }
    }

    /// Re-prices every event's tokens on `target`. Tokens are assumed unchanged, which is a
    /// simplification: a different model would use a different number of tokens.
    static func reprice(_ sessions: [SessionSummary], on target: String) -> [Row] {
        var acc: [String: (Double, Double, Int)] = [:]
        for s in sessions {
            for e in s.events {
                var v = acc[e.model] ?? (0, 0, 0)
                v.0 += e.cost
                v.1 += Pricing.cost(model: target, tokens: e.tokens)
                v.2 += e.tokens.total
                acc[e.model] = v
            }
        }
        return acc.map { Row(model: $0.key, actual: $0.value.0, repriced: $0.value.1, tokens: $0.value.2) }
            .filter { $0.tokens > 0 }
            .sorted { $0.actual > $1.actual }
    }

    // MARK: Sessions that probably didn't need Opus

    struct Candidate: Identifiable, Sendable {
        let session: SessionSummary
        let cheaper: Double
        let reason: String
        var id: String { session.id }
        var savings: Double { session.cost - cheaper }
    }

    /// Expensive Opus sessions with a light workload: little output and few tool calls per prompt.
    /// A heuristic; it can't judge whether the task needed the stronger model.
    static func overpowered(_ sessions: [SessionSummary], minCost: Double = 1,
                            alternative: String = "claude-sonnet-5-5") -> [Candidate] {
        sessions.compactMap { s in
            guard s.cost >= minCost, s.primaryModel.lowercased().contains("opus") else { return nil }
            let prompts = Double(max(s.userMessages, 1))
            let outPerPrompt = Double(s.tokens.output) / prompts
            let toolsPerPrompt = Double(s.toolCalls) / prompts
            var reasons: [String] = []
            if outPerPrompt < 1_500 { reasons.append("\(Fmt.tokens(Int(outPerPrompt))) output tokens per prompt") }
            if toolsPerPrompt < 2 { reasons.append(String(format: "%.1f tool calls per prompt", toolsPerPrompt)) }
            if s.userMessages <= 3 && s.toolCalls <= 5 { reasons.append("short Q&A session") }
            guard reasons.count >= 2 else { return nil }
            let cheaper = s.events.reduce(0) { $0 + Pricing.cost(model: $1.model.lowercased().contains("opus") ? alternative : $1.model, tokens: $1.tokens) }
            guard cheaper < s.cost else { return nil }
            return Candidate(session: s, cheaper: cheaper, reason: reasons.joined(separator: " · "))
        }
        .sorted { $0.savings > $1.savings }
    }
}
