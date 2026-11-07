import Foundation

/// ~/.claude/projects/<encoded-cwd>/<session>.jsonl (plus subagent transcripts).
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

    private static let interesting = ["\"assistant\"", "\"user\"", "custom-title", "\"summary\""]

    func parse(_ file: SourceFile) -> [SessionSummary] {
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

        FS.eachJSONLine(file.path, prefilter: { line in
            Self.interesting.contains { line.containsASCII($0) }
        }) { obj in
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
                if let text = Self.userText(msg["content"]), !Str.looksInjected(text) {
                    userCount += 1
                    if let ts { userTimes.append(ts) }
                    if firstPrompt == nil { firstPrompt = text }
                }
                return
            }

            // assistant
            let model = msg.str("model") ?? "unknown"
            let mid = msg.str("id") ?? obj.str("uuid") ?? UUID().uuidString
            if model != "<synthetic>" { assistantIDs.insert(mid) }
            for case let block as [String: Any] in msg.arr("content") ?? [] where block.str("type") == "tool_use" {
                let id = block.str("id") ?? UUID().uuidString
                if toolIDs.insert(id).inserted, let name = block.str("name") {
                    tools[Self.toolLabel(name), default: 0] += 1
                }
            }
            if let u = msg.obj("usage"), model != "<synthetic>" {
                let t = TokenUsage(input: u.int("input_tokens"), output: u.int("output_tokens"),
                                   cacheRead: u.int("cache_read_input_tokens"),
                                   cacheWrite: u.int("cache_creation_input_tokens"),
                                   reasoning: u.obj("output_tokens_details")?.int("thinking_tokens") ?? 0)
                if usageByMessage[mid] == nil { order.append(mid) }
                // Keep the largest output seen for this id (streamed blocks may update it).
                if let prev = usageByMessage[mid], prev.tokens.output >= t.output { return }
                usageByMessage[mid] = UsageEvent(timestamp: ts ?? usageByMessage[mid]?.timestamp ?? file.mtime,
                                                 model: model, tokens: t, reportedCost: nil)
            }
        }

        guard let s = start, let e = end, userCount + assistantIDs.count > 0 else { return [] }
        let id = sessionID.map { file.path.contains("/subagents/") ? "\($0)/\((file.path as NSString).lastPathComponent)" : $0 }
            ?? (file.path as NSString).lastPathComponent
        return [SessionSummary(
            nativeID: id, editor: editor, sourcePath: file.path,
            title: title ?? Str.clean(firstPrompt ?? "", max: 90), project: cwd,
            start: s, end: e, userMessages: userCount, assistantMessages: assistantIDs.count,
            tools: tools, events: order.compactMap { usageByMessage[$0] }, userTimes: userTimes)]
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
