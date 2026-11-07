import Foundation

/// Synthetic but realistic usage for README screenshots (`--snapshot <dir> --demo`), so no real
/// project names, prompts or paths end up in public images. Deterministic: same output every run.
enum DemoData {
    static var enabled: Bool { CommandLine.arguments.contains("--demo") }

    /// Small seeded generator (SplitMix64) so screenshots are reproducible.
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func double() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
        mutating func pick<T>(_ a: [T]) -> T { a[int(0...(a.count - 1))] }
        mutating func weighted<T>(_ a: [(T, Double)]) -> T {
            var x = double() * a.reduce(0) { $0 + $1.1 }
            for (v, w) in a { x -= w; if x <= 0 { return v } }
            return a.last!.0
        }
    }

    static let projects = ["~/code/acme-web", "~/code/payments-api", "~/code/ios-client", "~/code/data-pipeline",
                           "~/code/design-system", "~/code/infra", "~/code/docs-site", "~/code/ml-experiments"]

    static let titles = [
        "Add rate limiting to the payments API", "Fix flaky checkout e2e test", "Migrate auth to passkeys",
        "Refactor the order service into modules", "Why is the dashboard query slow?", "Write tests for the invoice parser",
        "Add dark mode to the settings screen", "Upgrade to React 19 and fix type errors", "Set up GitHub Actions caching",
        "Explain this Terraform plan", "Add pagination to /v1/customers", "Port the CSV importer to streaming",
        "Debug the memory leak in the worker", "Add OpenTelemetry tracing", "Review this PR for race conditions",
        "Generate SwiftUI previews for onboarding", "Tune the Postgres indexes", "Draft the v2 API changelog",
        "Implement retry with exponential backoff", "Convert the build to Bun", "Add feature flags for the beta",
        "Fix accessibility labels on the paywall", "Split the monolith config", "Add an LRU cache to the pricing lookup",
    ]

    struct Profile { let models: [(String, Double)]; let tools: [String]; let weight: Double; let tokenScale: Double }

    static let profiles: [Editor: Profile] = [
        .claudeCode: Profile(models: [("claude-opus-5-5", 0.55), ("claude-sonnet-5-5", 0.35), ("claude-haiku-5-5", 0.10)],
                             tools: ["Read", "Edit", "Bash", "Grep", "Write", "TodoWrite", "Glob", "WebFetch"], weight: 0.34, tokenScale: 1.0),
        .codex: Profile(models: [("gpt-5", 0.7), ("gpt-5-mini", 0.3)],
                        tools: ["shell", "apply_patch", "read_file", "update_plan"], weight: 0.20, tokenScale: 0.8),
        .cursor: Profile(models: [("claude-sonnet-5-5", 0.6), ("gpt-5", 0.4)],
                         tools: ["edit_file", "read_file", "codebase_search", "run_terminal_cmd"], weight: 0.15, tokenScale: 0.6),
        .copilotVSCode: Profile(models: [("gpt-5-mini", 0.6), ("claude-sonnet-5-5", 0.4)],
                                tools: ["editFiles", "readFile", "runInTerminal", "search"], weight: 0.10, tokenScale: 0.3),
        .gemini: Profile(models: [("gemini-2.5-pro", 0.7), ("gemini-2.5-flash", 0.3)],
                         tools: ["read_file", "replace", "run_shell_command", "glob"], weight: 0.08, tokenScale: 0.7),
        .opencode: Profile(models: [("claude-sonnet-5-5", 0.7), ("gpt-5", 0.3)],
                           tools: ["bash", "read", "edit", "write", "todowrite"], weight: 0.07, tokenScale: 0.7),
        .cline: Profile(models: [("claude-sonnet-4-5", 1.0)],
                        tools: ["readFile", "editedExistingFile", "execute_command"], weight: 0.06, tokenScale: 0.6),
    ]

    static func sessions(now: Date = Date()) -> [SessionSummary] {
        var rng = RNG(state: 42)
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let home = "/Users/dev"   // never the real home folder: these images are public
        let editors = profiles.map { ($0.key, $0.value.weight) }.sorted { $0.0.rawValue < $1.0.rawValue }
        var out: [SessionSummary] = []
        var n = 0
        for dayBack in stride(from: 120, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -dayBack, to: today)!
            let weekday = cal.component(.weekday, from: day)
            let weekend = weekday == 1 || weekday == 7
            // Busier recently, quieter on weekends; the last 9 days are an unbroken streak.
            let activity = (dayBack < 9 ? 1.0 : weekend ? 0.25 : 0.75) * (dayBack < 45 ? 1.0 : 0.6)
            guard dayBack < 9 || rng.double() < activity else { continue }
            let count = dayBack == 0 ? 3 : rng.int(weekend ? 1...2 : 2...6)
            for i in 0..<count {
                n += 1
                let live = dayBack == 0 && i == count - 1
                let editor = live ? Editor.claudeCode : rng.weighted(editors)
                let p = profiles[editor]!
                let model = live ? "claude-opus-5-5" : rng.weighted(p.models)
                // Prompting peaks mid-morning and mid-afternoon, with some late evenings.
                var hour = rng.weighted([(9, 1.0), (10, 2.0), (11, 1.8), (13, 1.0), (14, 1.6), (15, 2.0), (16, 1.5), (17, 0.8), (21, 0.6), (22, 0.4)])
                var start = cal.date(bySettingHour: hour, minute: rng.int(0...59), second: 0, of: day)!
                if dayBack == 0 {
                    // Today: two finished sessions and one running right now.
                    let minsAgo = i == count - 1 ? 35 : 60 * (count - i) + rng.int(10...50)
                    start = now.addingTimeInterval(TimeInterval(-minsAgo * 60))
                    hour = cal.component(.hour, from: start)
                }
                // Some Opus runs are quick questions over a big pasted context: the app flags these.
                let light = editor == .claudeCode && model.contains("opus") && rng.double() < 0.25 && dayBack > 0
                let prompts = light ? rng.int(1...2) : max(1, Int(Double(rng.int(2...24)) * (editor == .copilotVSCode ? 0.5 : 1)))
                let responses = light ? prompts : prompts + rng.int(prompts...(prompts * 3))
                var minutes = Double(prompts) * Double(rng.int(2...6))
                if dayBack == 0 && i == count - 1 { minutes = 33 }
                let end = start.addingTimeInterval(minutes * 60)
                var events: [UsageEvent] = []
                var context = Double(rng.int(8_000...20_000))
                for r in 0..<responses {
                    let t = start.addingTimeInterval(minutes * 60 * Double(r) / Double(max(responses, 1)))
                    context += Double(rng.int(4_000...22_000))
                    let fresh = Int(Double(rng.int(800...6_000)) * p.tokenScale)
                    let cacheRead = Int(context * p.tokenScale)
                    let write = r == 0 ? Int(context * 0.6) : rng.int(0...4_000)
                    let output = Int(Double(rng.int(400...4_200)) * p.tokenScale)
                    let tokens = light
                        ? TokenUsage(input: rng.int(120_000...260_000), output: rng.int(300...1_100), cacheRead: rng.int(0...40_000))
                        : editor == .claudeCode
                        ? TokenUsage(input: fresh, output: output, cacheRead: cacheRead, cacheWrite: write)
                        : TokenUsage(input: fresh, output: output, cacheRead: cacheRead / 2)
                    events.append(UsageEvent(timestamp: t, model: model, tokens: tokens, reportedCost: nil))
                }
                var tools: [String: Int] = [:]
                for _ in 0..<(light ? rng.int(0...1) : responses * rng.int(1...3)) { tools[rng.pick(p.tools), default: 0] += 1 }
                let userTimes = (0..<prompts).map { start.addingTimeInterval(minutes * 60 * Double($0) / Double(prompts)) }
                let project = rng.pick(projects).replacingOccurrences(of: "~", with: home)
                out.append(SessionSummary(nativeID: "demo-\(n)", editor: editor, sourcePath: "demo",
                                          title: live ? featured : rng.pick(titles),
                                          project: project, start: start, end: min(end, now), userMessages: prompts,
                                          assistantMessages: responses, tools: tools, events: events, userTimes: userTimes,
                                          fallbackModel: model))
            }
        }
        return out.sorted { $0.end > $1.end }
    }

    static func providers(now: Date = Date()) -> [ProviderUsage] {
        [
            ProviderUsage(provider: "Claude Code", symbol: "sparkle", plan: "Max", status: .ok, windows: [
                QuotaWindow(label: "5-hour session", usedFraction: 0.42, resetsAt: now.addingTimeInterval(2.4 * 3600)),
                QuotaWindow(label: "Weekly (all models)", usedFraction: 0.61, resetsAt: now.addingTimeInterval(3.2 * 86_400)),
                QuotaWindow(label: "Weekly (Opus)", usedFraction: 0.78, resetsAt: now.addingTimeInterval(3.2 * 86_400)),
            ], updatedAt: now, supportsLive: true),
            ProviderUsage(provider: "Codex", symbol: "terminal", plan: "Plus", status: .ok, windows: [
                QuotaWindow(label: "5-hour", usedFraction: 0.23, resetsAt: now.addingTimeInterval(4 * 3600)),
                QuotaWindow(label: "Weekly", usedFraction: 0.47, resetsAt: now.addingTimeInterval(5 * 86_400)),
            ], updatedAt: now),
            ProviderUsage(provider: "GitHub Copilot", symbol: "airplane", plan: "Pro", status: .ok, windows: [
                QuotaWindow(label: "Premium requests", usedFraction: 0.64, usedText: "192 / 300 requests",
                            resetsAt: now.addingTimeInterval(12 * 86_400)),
            ], updatedAt: now, supportsLive: true),
            ProviderUsage(provider: "Cursor", symbol: "cursorarrow.rays", plan: "Pro", status: .ok, windows: [
                QuotaWindow(label: "Included usage", usedFraction: 0.35, usedText: "$7.00 of $20.00",
                            resetsAt: now.addingTimeInterval(18 * 86_400)),
            ], updatedAt: now, supportsLive: true),
        ]
    }

    static let manualPlans = [
        ManualPlan(name: "Devin Core", monthlyPrice: 20, renewalDay: 3, quotaLabel: "ACUs", quotaUsed: 6.5, quotaTotal: 9),
        ManualPlan(name: "Gemini Code Assist", monthlyPrice: 22.99, renewalDay: 14, editor: .gemini),
    ]

    /// The session running "now"; the screenshot transcript opens it.
    static let featured = "Add rate limiting to the payments API"

    static func transcript(for s: SessionSummary) -> [TranscriptMessage] {
        let t0 = s.start
        func at(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
        return [
            .init(role: .user, text: "Add rate limiting to the payments API. Requests from one API key should be capped at 100 per minute, and the limit must hold across all instances.", timestamp: at(0)),
            .init(role: .assistant, text: "I'll look at how requests reach the handlers first, then add a Redis-backed sliding-window limiter as middleware.", timestamp: at(0.3), model: s.primaryModel),
            .init(role: .tool, text: "src/server/middleware/index.ts", timestamp: at(0.5), toolName: "Read"),
            .init(role: .tool, text: "rg \"app.use\\(\" src/server", timestamp: at(0.7), toolName: "Grep"),
            .init(role: .assistant, text: """
            Middleware is registered in `src/server/middleware/index.ts`. Here's the limiter, using a sorted set per key so it stays accurate across instances:

            ```ts
            import type { Request, Response, NextFunction } from "express";
            import { redis } from "../redis";

            const WINDOW_MS = 60_000;
            const LIMIT = 100;

            export async function rateLimit(req: Request, res: Response, next: NextFunction) {
              const key = `rl:${req.header("x-api-key") ?? req.ip}`;
              const now = Date.now();
              const [, , count] = await redis
                .multi()
                .zremrangebyscore(key, 0, now - WINDOW_MS)
                .zadd(key, now, `${now}-${Math.random()}`)
                .zcard(key)
                .pexpire(key, WINDOW_MS)
                .exec();

              res.setHeader("X-RateLimit-Limit", LIMIT);
              res.setHeader("X-RateLimit-Remaining", Math.max(0, LIMIT - Number(count)));
              if (Number(count) > LIMIT) return res.status(429).json({ error: "rate_limited" });
              next();
            }
            ```
            """, timestamp: at(2), model: s.primaryModel),
            .init(role: .tool, text: "src/server/middleware/rateLimit.ts", timestamp: at(2.2), toolName: "Write"),
            .init(role: .tool, text: "pnpm test -- rateLimit", timestamp: at(3), toolName: "Bash"),
            .init(role: .assistant, text: "All 14 tests pass, including a new one that fires 101 requests and expects the last to get a **429**. The limiter is registered before the auth middleware, so rejected calls never touch the database.", timestamp: at(4), model: s.primaryModel),
            .init(role: .user, text: "Nice. Can you make the limit configurable per plan?", timestamp: at(6)),
            .init(role: .assistant, text: "Sure. I'll read it from `plan.limits.requestsPerMinute` and fall back to 100 when it isn't set.", timestamp: at(6.4), model: s.primaryModel),
        ]
    }
}
