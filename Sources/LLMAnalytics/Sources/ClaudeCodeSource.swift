import Foundation

/// ~/.claude/projects/<encoded-cwd>/<session>.jsonl, plus subagent runs in
/// <session>/subagents/agent-*.jsonl which are folded into their parent session.
/// Assistant messages are written once per content block with the same message id and
/// repeated usage, so usage is de-duplicated by message id.
struct ClaudeCodeSource: UsageSource {
    let editor = Editor.claudeCode

    var roots: [String] {
        var r = [AppPaths.expand(".claude/projects")]
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            r.append((env as NSString).appendingPathComponent("projects"))
        }
        r.append(AppPaths.expand(".config/claude/projects"))
        return r.filter(FS.exists)
    }
    var watchRoots: [String] { roots }

    func discover() -> [SourceFile] {
        roots.flatMap { FS.find($0) { $0.hasSuffix(".jsonl") } }
    }

    func parse(_ file: SourceFile) -> [SessionSummary] { parse(file, previous: nil).sessions }

    func parse(_ file: SourceFile, previous: ParseState?) -> (sessions: [SessionSummary], state: ParseState?) {
        IncrementalJSONL.parse(file, previous: previous, as: Accumulator.self)
    }

    /// For ".../<session-id>/subagents/agent-x.jsonl" returns "<session-id>".
    static func parentSessionID(of path: String) -> String? {
        let parts = path.split(separator: "/")
        guard let i = parts.lastIndex(of: "subagents"), i > 0 else { return nil }
        return String(parts[i - 1])
    }

    static func tokens(_ u: [String: Any]) -> TokenUsage {
        let totalWrite = u.int("cache_creation_input_tokens")
        let w1h = min(totalWrite, u.obj("cache_creation")?.int("ephemeral_1h_input_tokens") ?? 0)
        return TokenUsage(input: u.int("input_tokens"), output: u.int("output_tokens"),
                          cacheRead: u.int("cache_read_input_tokens"), cacheWrite: totalWrite - w1h,
                          reasoning: u.obj("output_tokens_details")?.int("thinking_tokens") ?? 0,
                          cacheWrite1h: w1h)
    }

    struct Accumulator: LineAccumulator {
        var sessionID: String?
        var cwd = ""
        var title: String?
        var firstPrompt: String?
        var start: Date?, end: Date?
        var userCount = 0
        var assistantIDs = Set<String>()
        var usageByMessage: [String: UsageEvent] = [:]
        var order: [String] = []
        var tools: [String: Int] = [:]
        var toolIDs = Set<String>()
        var userTimes: [Date] = []

        private static let interesting = ["\"assistant\"", "\"user\"", "custom-title", "\"summary\""].map { Data($0.utf8) }
        static func prefilter(_ line: Data) -> Bool { interesting.contains { line.range(of: $0) != nil } }

        mutating func consume(_ obj: [String: Any]) {
            let type = obj.str("type")
            if type == "custom-title", let t = obj.str("customTitle") { title = t; return }
            if type == "summary", let t = obj.str("summary"), title == nil { title = t; return }
            guard type == "user" || type == "assistant" else { return }
            let ts = Dates.parse(obj["timestamp"])
            if let ts { start = min(start ?? ts, ts); end = max(end ?? ts, ts) }
            if sessionID == nil { sessionID = obj.str("sessionId") }
            if cwd.isEmpty, let c = obj.str("cwd") { cwd = c }
            guard let msg = obj.obj("message") else { return }

            if type == "user" {
                if obj["isMeta"] as? Bool == true { return }
                if let text = ClaudeCodeSource.userText(msg["content"]), !Str.looksInjected(text) {
                    userCount += 1
                    if let ts { userTimes.append(ts) }
                    if firstPrompt == nil { firstPrompt = text }
                }
                return
            }

            let model = msg.str("model") ?? "unknown"
            guard model != "<synthetic>" else { return }
            let mid = msg.str("id") ?? obj.str("uuid") ?? UUID().uuidString
            assistantIDs.insert(mid)
            for case let block as [String: Any] in msg.arr("content") ?? [] where block.str("type") == "tool_use" {
                let id = block.str("id") ?? UUID().uuidString
                if toolIDs.insert(id).inserted, let name = block.str("name") {
                    tools[ClaudeCodeSource.toolLabel(name), default: 0] += 1
                }
            }
            if let u = msg.obj("usage") {
                let t = ClaudeCodeSource.tokens(u)
                if usageByMessage[mid] == nil { order.append(mid) }
                // Streamed blocks repeat the usage; keep the most complete one.
                if let prev = usageByMessage[mid], prev.tokens.output >= t.output { return }
                usageByMessage[mid] = UsageEvent(timestamp: ts ?? usageByMessage[mid]?.timestamp ?? Date(),
                                                 model: model, tokens: t, reportedCost: nil)
            }
        }

        func build(file: SourceFile) -> [SessionSummary] {
            guard let s = start, let e = end, userCount + assistantIDs.count > 0 else { return [] }
            let events = order.compactMap { usageByMessage[$0] }
            if let parent = ClaudeCodeSource.parentSessionID(of: file.path) {
                // Subagent prompts come from the parent agent, not the human: no user turns.
                var sub = SessionSummary(nativeID: parent, editor: .claudeCode, sourcePath: file.path,
                                         title: "Subagent run", project: cwd, start: s, end: e,
                                         userMessages: 0, assistantMessages: assistantIDs.count,
                                         tools: tools, events: events, userTimes: [])
                sub.isPartial = true
                return [sub]
            }
            return [SessionSummary(
                nativeID: sessionID ?? ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension,
                editor: .claudeCode, sourcePath: file.path,
                title: title ?? Str.clean(firstPrompt ?? "", max: 90), project: cwd,
                start: s, end: e, userMessages: userCount, assistantMessages: assistantIDs.count,
                tools: tools, events: events, userTimes: userTimes)]
        }
    }

    static func toolLabel(_ name: String) -> String {
        if name.hasPrefix("mcp__") {
            let parts = name.split(separator: "_", omittingEmptySubsequences: true)
            return parts.count >= 2 ? "mcp:\(parts[1])" : name
        }
        return name
    }

    static func userText(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        guard let arr = content as? [[String: Any]] else { return nil }
        if arr.contains(where: { $0.str("type") == "tool_result" }) { return nil }
        let text = arr.compactMap { $0.str("type") == "text" ? $0.str("text") : nil }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        var out: [TranscriptMessage] = []
        FS.eachJSONLine(session.sourcePath, prefilter: { $0.containsASCII("\"message\"") }) { obj in
            let type = obj.str("type")
            guard type == "user" || type == "assistant", let msg = obj.obj("message") else { return }
            let ts = Dates.parse(obj["timestamp"])
            if type == "user" {
                if obj["isMeta"] as? Bool == true { return }
                if let s = msg["content"] as? String {
                    if !Str.looksInjected(s) { out.append(.init(role: .user, text: s, timestamp: ts)) }
                    return
                }
                for case let b as [String: Any] in msg.arr("content") ?? [] {
                    switch b.str("type") {
                    case "text":
                        if let t = b.str("text"), !Str.looksInjected(t) { out.append(.init(role: .user, text: t, timestamp: ts)) }
                    case "tool_result":
                        let text: String
                        if let s = b["content"] as? String { text = s }
                        else { text = (b["content"] as? [[String: Any]] ?? []).compactMap { $0.str("text") }.joined(separator: "\n") }
                        out.append(.init(role: .tool, text: text, timestamp: ts, toolName: "result"))
                    default: break
                    }
                }
                return
            }
            let model = msg.str("model")
            for case let b as [String: Any] in msg.arr("content") ?? [] {
                switch b.str("type") {
                case "text":
                    if let t = b.str("text"), !t.isEmpty { out.append(.init(role: .assistant, text: t, timestamp: ts, model: model)) }
                case "thinking":
                    if let t = b.str("thinking"), !t.isEmpty { out.append(.init(role: .system, text: t, timestamp: ts, model: model, toolName: "thinking")) }
                case "tool_use":
                    let input = (b["input"]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    out.append(.init(role: .tool, text: "```json\n\(input)\n```", timestamp: ts, model: model, toolName: b.str("name")))
                default: break
                }
            }
        }
        return out
    }
}
