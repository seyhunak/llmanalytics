import Foundation

/// ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl  (CODEX_HOME respected)
struct CodexSource: UsageSource {
    let editor = Editor.codex

    static var home: String {
        ProcessInfo.processInfo.environment["CODEX_HOME"] ?? AppPaths.expand(".codex")
    }
    var roots: [String] {
        [(Self.home as NSString).appendingPathComponent("sessions"),
         (Self.home as NSString).appendingPathComponent("archived_sessions")].filter(FS.exists)
    }
    var watchRoots: [String] { roots }

    func discover() -> [SourceFile] {
        roots.flatMap { FS.find($0) { $0.hasSuffix(".jsonl") } }
    }

    func parse(_ file: SourceFile) -> [SessionSummary] { parse(file, previous: nil).sessions }

    func parse(_ file: SourceFile, previous: ParseState?) -> (sessions: [SessionSummary], state: ParseState?) {
        IncrementalJSONL.parse(file, previous: previous, as: Accumulator.self)
    }

    struct Accumulator: LineAccumulator {
        var id: String?
        var cwd = ""
        var model = "gpt-5"
        var firstPrompt: String?
        var start: Date?, end: Date?
        var userTimes: [Date] = []       // from event_msg user_message (older format)
        var itemUserTimes: [Date] = []   // from item_completed UserMessage (newer format)
        var assistant = 0, respAssistant = 0
        var tools: [String: Int] = [:]
        var events: [UsageEvent] = []
        var lastTotal = -1

        static func prefilter(_ line: Data) -> Bool { true }

        mutating func consume(_ obj: [String: Any]) {
            let ts = Dates.parse(obj["timestamp"])
            if let ts { start = min(start ?? ts, ts); end = max(end ?? ts, ts) }
            let payload = obj.obj("payload") ?? [:]
            switch obj.str("type") {
            case "session_meta":
                id = payload.str("id") ?? payload.str("session_id")
                cwd = payload.str("cwd") ?? cwd
            case "turn_context":
                if let m = payload.str("model") { model = m }
                if cwd.isEmpty, let c = payload.str("cwd") { cwd = c }
            case "event_msg":
                switch payload.str("type") {
                case "user_message":
                    if let m = payload.str("message"), !Str.looksInjected(m) {
                        userTimes.append(ts ?? Date())
                        if firstPrompt == nil { firstPrompt = m }
                    }
                case "item_completed":
                    if let item = payload.obj("item"), item.str("type") == "UserMessage" {
                        let text = (item.arr("content") as? [[String: Any]] ?? []).compactMap { $0.str("text") }.joined(separator: "\n")
                        if !Str.looksInjected(text) {
                            itemUserTimes.append(ts ?? Date())
                            if firstPrompt == nil { firstPrompt = text }
                        }
                    }
                case "agent_message":
                    assistant += 1
                case "token_count":
                    guard let info = payload.obj("info"), let last = info.obj("last_token_usage") else { return }
                    let total = info.obj("total_token_usage")?.int("total_tokens") ?? -2
                    if total == lastTotal { return } // Codex repeats the same snapshot
                    lastTotal = total
                    let input = last.int("input_tokens"), cached = last.int("cached_input_tokens")
                    let t = TokenUsage(input: max(0, input - cached), output: last.int("output_tokens"),
                                       cacheRead: cached, cacheWrite: last.int("cache_write_input_tokens"),
                                       reasoning: last.int("reasoning_output_tokens"))
                    if !t.isZero { events.append(UsageEvent(timestamp: ts ?? Date(), model: model, tokens: t, reportedCost: nil)) }
                default: break
                }
            case "response_item":
                switch payload.str("type") {
                case "function_call", "custom_tool_call":
                    tools[payload.str("name") ?? "tool", default: 0] += 1
                case "local_shell_call":
                    tools["shell", default: 0] += 1
                case "web_search_call":
                    tools["web_search", default: 0] += 1
                case "message" where payload.str("role") == "assistant":
                    respAssistant += 1
                default: break
                }
            default: break
            }
        }

        func build(file: SourceFile) -> [SessionSummary] {
            let times = userTimes.count >= itemUserTimes.count ? userTimes : itemUserTimes
            guard let s = start, let e = end, times.count + events.count > 0 else { return [] }
            return [SessionSummary(
                nativeID: id ?? (file.path as NSString).lastPathComponent, editor: .codex, sourcePath: file.path,
                title: Str.clean(firstPrompt ?? "", max: 90), project: cwd, start: s, end: e,
                userMessages: times.count, assistantMessages: assistant > 0 ? assistant : respAssistant,
                tools: tools, events: events, userTimes: times, fallbackModel: model)]
        }
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        var out: [TranscriptMessage] = []
        var model: String?
        FS.eachJSONLine(session.sourcePath) { obj in
            let ts = Dates.parse(obj["timestamp"])
            let p = obj.obj("payload") ?? [:]
            if obj.str("type") == "turn_context" { model = p.str("model"); return }
            guard obj.str("type") == "response_item" else { return }
            switch p.str("type") {
            case "message":
                let role = p.str("role")
                guard role == "user" || role == "assistant" else { return }
                let text = (p.arr("content") as? [[String: Any]] ?? []).compactMap { $0.str("text") }.joined(separator: "\n")
                if role == "user", Str.looksInjected(text) { return }
                if !text.isEmpty { out.append(.init(role: role == "user" ? .user : .assistant, text: text, timestamp: ts, model: model)) }
            case "reasoning":
                let s = (p.arr("summary") as? [[String: Any]] ?? []).compactMap { $0.str("text") }.joined(separator: "\n")
                if !s.isEmpty { out.append(.init(role: .system, text: s, timestamp: ts, model: model, toolName: "reasoning")) }
            case "function_call", "custom_tool_call":
                let args = p.str("arguments") ?? p.str("input") ?? ""
                out.append(.init(role: .tool, text: "```\n\(args)\n```", timestamp: ts, model: model, toolName: p.str("name")))
            case "function_call_output", "custom_tool_call_output":
                let o = (p["output"] as? String) ?? ((p["output"] as? [String: Any])?.str("content") ?? "")
                out.append(.init(role: .tool, text: o, timestamp: ts, toolName: "output"))
            default: break
            }
        }
        return out
    }

    // MARK: Rate limits for the Subscriptions page

    struct RateLimitSnapshot {
        var plan: String?
        var primary: (used: Double, windowMinutes: Int, resetsAt: Date?)?
        var secondary: (used: Double, windowMinutes: Int, resetsAt: Date?)?
        var creditsBalance: String?
        var observedAt: Date
    }

    /// Newest `rate_limits` object written by Codex itself — no network needed.
    func latestRateLimits() -> RateLimitSnapshot? {
        let files = discover().sorted { $0.mtime > $1.mtime }.prefix(40)
        var latestPlan: String?
        for f in files {
            var snap: RateLimitSnapshot?
            FS.eachJSONLine(f.path, prefilter: { $0.containsASCII("rate_limits") }) { obj in
                guard let rl = obj.obj("payload")?.obj("rate_limits") else { return }
                func window(_ k: String) -> (Double, Int, Date?)? {
                    guard let w = rl.obj(k) else { return nil }
                    return (w.dbl("used_percent") ?? 0, w.int("window_minutes"), Dates.parse(w["resets_at"]))
                }
                guard rl.obj("primary") != nil || rl.obj("secondary") != nil else {
                    if latestPlan == nil { latestPlan = rl.str("plan_type") }
                    return
                }
                let credits = rl.obj("credits")
                var balance: String?
                if credits?["unlimited"] as? Bool == true { balance = "Unlimited" }
                else if let b = credits?["balance"], !(b is NSNull) { balance = "\(b)" }
                snap = RateLimitSnapshot(plan: rl.str("plan_type"), primary: window("primary"),
                                         secondary: window("secondary"), creditsBalance: balance,
                                         observedAt: Dates.parse(obj["timestamp"]) ?? f.mtime)
            }
            if var snap { if snap.plan == nil { snap.plan = latestPlan }; return snap }
        }
        return nil
    }
}
