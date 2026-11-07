import Foundation

/// SQLite files are written through a WAL, so the main file's mtime lags. Combine both.
private func statWithWAL(_ path: String) -> SourceFile? {
    guard let main = FS.stat(path) else { return nil }
    guard let wal = FS.stat(path + "-wal") else { return main }
    return SourceFile(path: path, mtime: max(main.mtime, wal.mtime), size: main.size + wal.size)
}

// MARK: - OpenCode

/// ~/.local/share/opencode/opencode.db — records exact per-message tokens and cost.
struct OpenCodeSource: UsageSource {
    let editor = Editor.opencode
    var dbPath: String {
        let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? AppPaths.expand(".local/share")
        return (xdg as NSString).appendingPathComponent("opencode/opencode.db")
    }
    var watchRoots: [String] { FS.exists(dbPath) ? [(dbPath as NSString).deletingLastPathComponent] : [] }
    func discover() -> [SourceFile] { statWithWAL(dbPath).map { [$0] } ?? [] }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        guard let db = SQLiteDB(path: file.path), db.hasTable("session"), db.hasTable("message") else { return [] }
        var sessions: [String: SessionSummary] = [:]
        for r in db.rows("SELECT id, title, directory, model, time_created, time_updated FROM session WHERE time_archived IS NULL") {
            guard let id = r[0] else { continue }
            let start = Dates.parse(NSNumber(value: Double(r[4] ?? "0") ?? 0)) ?? file.mtime
            let end = Dates.parse(NSNumber(value: Double(r[5] ?? "0") ?? 0)) ?? start
            sessions[id] = SessionSummary(nativeID: id, editor: editor, sourcePath: file.path,
                                          title: r[1] ?? "", project: r[2] ?? "", start: start, end: end,
                                          fallbackModel: r[3])
        }
        for r in db.rows("SELECT session_id, time_created, data FROM message ORDER BY time_created") {
            guard let sid = r[0], var s = sessions[sid], let d = parseJSONObject(r[2]) else { continue }
            let ts = Dates.parse(NSNumber(value: Double(r[1] ?? "0") ?? 0)) ?? s.start
            s.start = min(s.start, ts); s.end = max(s.end, ts)
            if d.str("role") == "user" {
                s.userMessages += 1; s.userTimes.append(ts)
            } else if d.str("role") == "assistant" {
                s.assistantMessages += 1
                let t = d.obj("tokens") ?? [:]
                let tokens = TokenUsage(input: t.int("input"), output: t.int("output") + t.int("reasoning"),
                                        cacheRead: t.obj("cache")?.int("read") ?? 0,
                                        cacheWrite: t.obj("cache")?.int("write") ?? 0, reasoning: t.int("reasoning"))
                let cost = d.dbl("cost") ?? 0
                if !tokens.isZero || cost > 0 {
                    s.events.append(UsageEvent(timestamp: ts, model: d.str("modelID") ?? s.fallbackModel ?? "unknown",
                                               tokens: tokens, reportedCost: cost > 0 ? cost : nil))
                }
            }
            sessions[sid] = s
        }
        if db.hasTable("part") {
            for r in db.rows("SELECT session_id, json_extract(data,'$.tool') FROM part WHERE json_extract(data,'$.type')='tool'") {
                guard let sid = r[0], let tool = r[1], sessions[sid] != nil else { continue }
                sessions[sid]!.tools[tool, default: 0] += 1
            }
        }
        return sessions.values.compactMap { s in
            guard s.messageCount > 0 else { return nil }
            var s = s; s.finalize(); return s
        }
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        guard let db = SQLiteDB(path: session.sourcePath), db.hasTable("part") else { return [] }
        var out: [TranscriptMessage] = []
        let roles = Dictionary(uniqueKeysWithValues: db.rows("SELECT id, json_extract(data,'$.role') FROM message WHERE session_id=?", [session.nativeID])
            .compactMap { r in r[0].map { ($0, r[1] ?? "assistant") } })
        for r in db.rows("SELECT message_id, time_created, data FROM part WHERE session_id=? ORDER BY time_created, id", [session.nativeID]) {
            guard let d = parseJSONObject(r[2]) else { continue }
            let ts = Dates.parse(NSNumber(value: Double(r[1] ?? "0") ?? 0))
            let role: TranscriptRole = roles[r[0] ?? ""] == "user" ? .user : .assistant
            switch d.str("type") {
            case "text":
                if let t = d.str("text"), !t.isEmpty, d["synthetic"] as? Bool != true { out.append(.init(role: role, text: t, timestamp: ts)) }
            case "reasoning":
                if let t = d.str("text"), !t.isEmpty { out.append(.init(role: .system, text: t, timestamp: ts, toolName: "reasoning")) }
            case "tool":
                let input = d.obj("state")?["input"].flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted]) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                out.append(.init(role: .tool, text: "```json\n\(input)\n```", timestamp: ts, toolName: d.str("tool")))
            default: break
            }
        }
        return out
    }
}

// MARK: - Cursor

/// Cursor keeps composer/chat history in globalStorage/state.vscdb (cursorDiskKV table).
struct CursorSource: UsageSource {
    let editor = Editor.cursor
    static var globalDB: String { AppPaths.expand("Library/Application Support/Cursor/User/globalStorage/state.vscdb") }
    var watchRoots: [String] { FS.exists(Self.globalDB) ? [(Self.globalDB as NSString).deletingLastPathComponent] : [] }
    func discover() -> [SourceFile] { statWithWAL(Self.globalDB).map { [$0] } ?? [] }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        guard let db = SQLiteDB(path: file.path), db.hasTable("cursorDiskKV") else { return [] }
        // Bubbles carry token counts; group them by composer id.
        var bubbles: [String: [[String: Any]]] = [:]
        for r in db.rows("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'bubbleId:%'") {
            guard let key = r[0], let d = parseJSONObject(r[1]) else { continue }
            let parts = key.split(separator: ":")
            guard parts.count >= 3 else { continue }
            bubbles[String(parts[1]), default: []].append(d)
        }
        var out: [SessionSummary] = []
        for r in db.rows("SELECT key, value FROM cursorDiskKV WHERE key LIKE 'composerData:%'") {
            guard let d = parseJSONObject(r[1]) else { continue }
            let cid = d.str("composerId") ?? String((r[0] ?? "").dropFirst("composerData:".count))
            var list = bubbles[cid] ?? []
            if list.isEmpty, let conv = d.arr("conversation") as? [[String: Any]] { list = conv }
            guard !list.isEmpty else { continue }
            let created = Dates.parse(d["createdAt"]) ?? file.mtime
            let updated = Dates.parse(d["lastUpdatedAt"]) ?? created
            var users = 0, assistants = 0
            var tools: [String: Int] = [:]
            var events: [UsageEvent] = []
            var userTimes: [Date] = []
            var firstPrompt: String?
            let model = d.obj("modelConfig")?.str("modelName") ?? "cursor"
            for b in list {
                let ts = Dates.parse(b["createdAt"]) ?? Dates.parse(b.obj("timingInfo")?["clientStartTime"]) ?? created
                if b.int("type") == 1 {
                    users += 1; userTimes.append(ts)
                    if firstPrompt == nil { firstPrompt = b.str("text") }
                } else {
                    assistants += 1
                    if let name = b.obj("toolFormerData")?.str("name") { tools[name, default: 0] += 1 }
                    let tc = b.obj("tokenCount") ?? [:]
                    let t = TokenUsage(input: tc.int("inputTokens"), output: tc.int("outputTokens"))
                    if !t.isZero {
                        let m = b.obj("modelInfo")?.str("modelName") ?? model
                        events.append(UsageEvent(timestamp: ts, model: m, tokens: t, reportedCost: nil))
                    }
                }
            }
            out.append(SessionSummary(nativeID: cid, editor: editor, sourcePath: file.path,
                                      title: d.str("name") ?? Str.clean(firstPrompt ?? "", max: 90),
                                      project: "", start: created, end: max(updated, created),
                                      userMessages: users, assistantMessages: assistants, tools: tools,
                                      events: events, userTimes: userTimes, fallbackModel: model))
        }
        return out
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        guard let db = SQLiteDB(path: session.sourcePath) else { return [] }
        let order = parseJSONObject(db.rows("SELECT value FROM cursorDiskKV WHERE key=?", ["composerData:\(session.nativeID)"]).first?[0] ?? nil)?
            .arr("fullConversationHeadersOnly") as? [[String: Any]] ?? []
        var byID: [String: [String: Any]] = [:]
        for r in db.rows("SELECT key, value FROM cursorDiskKV WHERE key LIKE ?", ["bubbleId:\(session.nativeID):%"]) {
            if let k = r[0], let d = parseJSONObject(r[1]) { byID[String(k.split(separator: ":").last ?? "")] = d }
        }
        let ids = order.compactMap { $0.str("bubbleId") }
        let list = ids.isEmpty ? Array(byID.values) : ids.compactMap { byID[$0] }
        return list.compactMap { b in
            let text = b.str("text") ?? ""
            if let tool = b.obj("toolFormerData")?.str("name") {
                return .init(role: .tool, text: b.obj("toolFormerData")?.str("rawArgs") ?? "", timestamp: nil, toolName: tool)
            }
            guard !text.isEmpty else { return nil }
            return .init(role: b.int("type") == 1 ? .user : .assistant, text: text, timestamp: Dates.parse(b["createdAt"]))
        }
    }
}

// MARK: - Gemini CLI

/// ~/.gemini/tmp/<project-hash>/chats/session-*.json
struct GeminiSource: UsageSource {
    let editor = Editor.gemini
    var root: String { AppPaths.expand(".gemini/tmp") }
    var watchRoots: [String] { FS.exists(root) ? [root] : [] }
    func discover() -> [SourceFile] {
        guard FS.exists(root) else { return [] }
        return FS.find(root, maxDepth: 3) { $0.hasPrefix("session-") && $0.hasSuffix(".json") }
    }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        guard let d = FS.readJSON(file.path) as? [String: Any],
              let messages = d.arr("messages") as? [[String: Any]], !messages.isEmpty else { return [] }
        var users = 0, assistants = 0
        var tools: [String: Int] = [:]
        var events: [UsageEvent] = []
        var userTimes: [Date] = []
        var firstPrompt: String?
        var start = Dates.parse(d["startTime"]), end = Dates.parse(d["lastUpdated"])
        for m in messages {
            let ts = Dates.parse(m["timestamp"]) ?? start ?? file.mtime
            start = min(start ?? ts, ts); end = max(end ?? ts, ts)
            switch m.str("type") {
            case "user":
                users += 1; userTimes.append(ts)
                if firstPrompt == nil { firstPrompt = Self.text(m["content"]) }
            case "gemini":
                assistants += 1
                for case let t as [String: Any] in m.arr("toolCalls") ?? [] { tools[t.str("name") ?? "tool", default: 0] += 1 }
                if let tk = m.obj("tokens") {
                    let cached = tk.int("cached")
                    let t = TokenUsage(input: max(0, tk.int("input") - cached), output: tk.int("output") + tk.int("thoughts"),
                                       cacheRead: cached, reasoning: tk.int("thoughts"))
                    events.append(UsageEvent(timestamp: ts, model: m.str("model") ?? "gemini-2.5-pro", tokens: t, reportedCost: nil))
                }
            default: break
            }
        }
        guard users + assistants > 0 else { return [] }
        return [SessionSummary(nativeID: d.str("sessionId") ?? file.path, editor: editor, sourcePath: file.path,
                               title: Str.clean(firstPrompt ?? "", max: 90), project: d.str("projectHash").map { "gemini:\($0.prefix(8))" } ?? "",
                               start: start ?? file.mtime, end: end ?? file.mtime, userMessages: users,
                               assistantMessages: assistants, tools: tools, events: events, userTimes: userTimes,
                               fallbackModel: "gemini")]
    }

    static func text(_ any: Any?) -> String {
        if let s = any as? String { return s }
        return (any as? [[String: Any]] ?? []).compactMap { $0.str("text") }.joined(separator: "\n")
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        guard let d = FS.readJSON(session.sourcePath) as? [String: Any] else { return [] }
        var out: [TranscriptMessage] = []
        for m in d.arr("messages") as? [[String: Any]] ?? [] {
            let ts = Dates.parse(m["timestamp"])
            switch m.str("type") {
            case "user": out.append(.init(role: .user, text: Self.text(m["content"]), timestamp: ts))
            case "gemini":
                let t = Self.text(m["content"])
                if !t.isEmpty { out.append(.init(role: .assistant, text: t, timestamp: ts, model: m.str("model"))) }
                for case let c as [String: Any] in m.arr("toolCalls") ?? [] {
                    out.append(.init(role: .tool, text: "", timestamp: ts, toolName: c.str("name")))
                }
            default: break
            }
        }
        return out
    }
}
