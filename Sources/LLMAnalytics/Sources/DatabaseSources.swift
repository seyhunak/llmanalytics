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

    func parse(_ file: SourceFile) -> [SessionSummary] { parse(file, previous: nil).sessions }

    /// Rows are kept in the state and only rows with a newer `time_updated` are fetched, so a
    /// new message costs one small query instead of re-reading the whole database.
    struct State: ParseState {
        struct Meta: Sendable { var title: String; var directory: String; var model: String?; var created: Date; var updated: Date }
        struct Message: Sendable { var session: String; var role: String; var time: Date; var event: UsageEvent? }
        var sessions: [String: Meta] = [:]
        var messages: [String: Message] = [:]
        var tools: [String: (session: String, tool: String)] = [:]
        var sessionCursor = "0", messageCursor = "0", partCursor = "0"
    }

    func parse(_ file: SourceFile, previous: ParseState?) -> (sessions: [SessionSummary], state: ParseState?) {
        guard let db = SQLiteDB(path: file.path), db.hasTable("session"), db.hasTable("message") else { return ([], nil) }
        var st = (previous as? State) ?? State()
        func date(_ v: String?) -> Date? { Dates.parse(NSNumber(value: Double(v ?? "0") ?? 0)) }

        for r in db.rows("SELECT id, title, directory, model, time_created, time_updated, time_archived FROM session WHERE time_updated > ? ORDER BY time_updated", [st.sessionCursor]) {
            guard let id = r[0] else { continue }
            st.sessionCursor = r[5] ?? st.sessionCursor
            if r[6] != nil { st.sessions[id] = nil; continue }
            let created = date(r[4]) ?? file.mtime
            st.sessions[id] = .init(title: r[1] ?? "", directory: r[2] ?? "", model: r[3], created: created, updated: date(r[5]) ?? created)
        }
        for r in db.rows("SELECT id, session_id, time_created, time_updated, data FROM message WHERE time_updated > ? ORDER BY time_updated", [st.messageCursor]) {
            guard let id = r[0], let sid = r[1], let d = parseJSONObject(r[4]) else { continue }
            st.messageCursor = r[3] ?? st.messageCursor
            let ts = date(r[2]) ?? file.mtime
            let role = d.str("role") ?? "assistant"
            var event: UsageEvent?
            if role == "assistant" {
                let t = d.obj("tokens") ?? [:]
                let tokens = TokenUsage(input: t.int("input"), output: t.int("output") + t.int("reasoning"),
                                        cacheRead: t.obj("cache")?.int("read") ?? 0,
                                        cacheWrite: t.obj("cache")?.int("write") ?? 0, reasoning: t.int("reasoning"))
                let cost = d.dbl("cost") ?? 0
                if !tokens.isZero || cost > 0 {
                    event = UsageEvent(timestamp: ts, model: d.str("modelID") ?? "unknown", tokens: tokens, reportedCost: cost > 0 ? cost : nil)
                }
            }
            st.messages[id] = .init(session: sid, role: role, time: ts, event: event)
        }
        if db.hasTable("part") {
            for r in db.rows("SELECT id, session_id, time_updated, json_extract(data,'$.tool') FROM part WHERE time_updated > ? AND json_extract(data,'$.type')='tool' ORDER BY time_updated", [st.partCursor]) {
                guard let id = r[0], let sid = r[1], let tool = r[3] else { continue }
                st.partCursor = r[2] ?? st.partCursor
                st.tools[id] = (sid, tool)
            }
        }

        var out: [String: SessionSummary] = [:]
        for (id, m) in st.sessions {
            out[id] = SessionSummary(nativeID: id, editor: editor, sourcePath: file.path, title: m.title,
                                     project: m.directory, start: m.created, end: m.updated, fallbackModel: m.model)
        }
        for m in st.messages.values.sorted(by: { $0.time < $1.time }) {
            guard out[m.session] != nil else { continue }
            out[m.session]!.start = min(out[m.session]!.start, m.time)
            out[m.session]!.end = max(out[m.session]!.end, m.time)
            if m.role == "user" { out[m.session]!.userMessages += 1; out[m.session]!.userTimes.append(m.time) }
            else { out[m.session]!.assistantMessages += 1 }
            if let e = m.event { out[m.session]!.events.append(e) }
        }
        for t in st.tools.values where out[t.session] != nil { out[t.session]!.tools[t.tool, default: 0] += 1 }
        let sessions: [SessionSummary] = out.values.compactMap { s in
            guard s.messageCount > 0 else { return nil }
            var s = s; s.finalize(); return s
        }
        return (sessions, st)
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

/// ~/.gemini/tmp/<project-hash>/chats/session-*.json. Qwen Code is a Gemini CLI fork and keeps
/// the same layout under ~/.qwen/tmp, so it reuses this reader.
struct GeminiSource: UsageSource {
    var editor = Editor.gemini
    var root: String = AppPaths.expand(".gemini/tmp")
    var defaultModel = "gemini-2.5-pro"
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
            case "gemini", "qwen", "model", "assistant":
                assistants += 1
                for case let t as [String: Any] in m.arr("toolCalls") ?? [] { tools[t.str("name") ?? "tool", default: 0] += 1 }
                if let tk = m.obj("tokens") {
                    let cached = tk.int("cached")
                    let t = TokenUsage(input: max(0, tk.int("input") - cached), output: tk.int("output") + tk.int("thoughts"),
                                       cacheRead: cached, reasoning: tk.int("thoughts"))
                    events.append(UsageEvent(timestamp: ts, model: m.str("model") ?? defaultModel, tokens: t, reportedCost: nil))
                }
            default: break
            }
        }
        guard users + assistants > 0 else { return [] }
        return [SessionSummary(nativeID: d.str("sessionId") ?? file.path, editor: editor, sourcePath: file.path,
                               title: Str.clean(firstPrompt ?? "", max: 90), project: d.str("projectHash").map { "\(editor.rawValue):\($0.prefix(8))" } ?? "",
                               start: start ?? file.mtime, end: end ?? file.mtime, userMessages: users,
                               assistantMessages: assistants, tools: tools, events: events, userTimes: userTimes,
                               fallbackModel: editor == .gemini ? "gemini" : defaultModel)]
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
            case "gemini", "qwen", "model", "assistant":
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
