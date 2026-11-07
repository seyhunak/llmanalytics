import Foundation

// Readers for the less common tools. Formats marked "verified" were checked against real local
// data; the others follow each project's documented/open-source storage layout and are covered by
// fixture tests only.

// MARK: - Continue (verified)

/// ~/.continue/sessions/<id>.json for chats, ~/.continue/dev_data for token counts.
/// Continue logs tokens separately from chats (and mostly for autocomplete), so token events are
/// attached to the chat that was open at the time, and the rest go into one usage row per day.
/// Everything is read as one unit because events have to be matched across files.
struct ContinueSource: UsageSource {
    let editor = Editor.continueDev
    var root = AppPaths.expand(".continue")
    var sessionsDir: String { root + "/sessions" }
    var devData: String { root + "/dev_data" }
    var watchRoots: [String] { [sessionsDir, devData].filter(FS.exists) }

    private var tokenFiles: [String] {
        [devData + "/devdata.sqlite", devData + "/devdata.sqlite-wal",
         devData + "/0.2.0/tokensGenerated.jsonl", devData + "/0.1.0/tokensGenerated.jsonl"]
    }

    func discover() -> [SourceFile] {
        var files = FS.find(sessionsDir, maxDepth: 1) { $0.hasSuffix(".json") }
        files += tokenFiles.compactMap(FS.stat)
        guard let mtime = files.map(\.mtime).max() else { return [] }
        let size = files.reduce(Int64(files.count)) { $0 + $1.size }
        return [SourceFile(path: sessionsDir, mtime: mtime, size: size)]
    }

    struct TokenRow: Hashable {
        let ts: Date; let model: String; let prompt: Int; let generated: Int; var provider = ""
        /// Models served on this machine cost nothing, even if a cloud model shares the name.
        var isLocal: Bool { ["ollama", "lmstudio", "llamacpp", "llama.cpp", "llamafile", "msty"].contains(provider.lowercased()) }
    }

    func tokenRows() -> [TokenRow] {
        var seen = Set<String>()
        var out: [TokenRow] = []
        func add(_ r: TokenRow) {
            let key = "\(Int(r.ts.timeIntervalSince1970))|\(r.model)|\(r.prompt)|\(r.generated)"
            if seen.insert(key).inserted { out.append(r) }
        }
        if let db = SQLiteDB(path: devData + "/devdata.sqlite"), db.hasTable("tokens_generated") {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            for r in db.rows("SELECT model, tokens_prompt, tokens_generated, timestamp, provider FROM tokens_generated") {
                guard let ts = r[3].flatMap({ f.date(from: String($0.prefix(19))) }) else { continue }
                add(TokenRow(ts: ts, model: r[0] ?? "unknown", prompt: Int(r[1] ?? "") ?? 0, generated: Int(r[2] ?? "") ?? 0,
                             provider: r[4] ?? ""))
            }
        }
        for path in [devData + "/0.2.0/tokensGenerated.jsonl", devData + "/0.1.0/tokensGenerated.jsonl"] where FS.exists(path) {
            FS.eachJSONLine(path) { o in
                guard let ts = Dates.parse(o["timestamp"]) else { return }
                add(TokenRow(ts: ts, model: o.str("model") ?? "unknown",
                             prompt: o.int("promptTokens"), generated: o.int("generatedTokens"), provider: o.str("provider") ?? ""))
            }
        }
        return out.sorted { $0.ts < $1.ts }
    }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        var created: [String: Date] = [:]
        for case let m as [String: Any] in FS.readJSON(sessionsDir + "/sessions.json") as? [Any] ?? [] {
            // dateCreated is epoch milliseconds stored as a string.
            let raw: Any? = m.str("dateCreated").flatMap(Double.init).map { NSNumber(value: $0) } ?? m["dateCreated"]
            if let id = m.str("sessionId"), let d = Dates.parse(raw) {
                created[id] = d
            }
        }
        var chats: [SessionSummary] = []
        for f in FS.find(sessionsDir, maxDepth: 1, match: { $0.hasSuffix(".json") && $0 != "sessions.json" }) {
            guard let d = FS.readJSON(f.path) as? [String: Any],
                  let history = d.arr("history") as? [[String: Any]], !history.isEmpty else { continue }
            let id = d.str("sessionId") ?? (f.path as NSString).lastPathComponent
            var users = 0, assistants = 0
            var tools: [String: Int] = [:]
            var firstPrompt: String?
            for h in history {
                guard let m = h.obj("message") else { continue }
                switch m.str("role") {
                case "user":
                    let t = Self.text(m["content"])
                    if Str.looksInjected(t) { continue }
                    users += 1; if firstPrompt == nil { firstPrompt = t }
                case "assistant":
                    assistants += 1
                    for case let c as [String: Any] in m.arr("toolCalls") ?? [] {
                        tools[c.obj("function")?.str("name") ?? "tool", default: 0] += 1
                    }
                default: break
                }
            }
            guard users + assistants > 0 else { continue }
            let start = created[id] ?? f.mtime
            var title = d.str("title") ?? ""
            if title.isEmpty || title == "New Session" { title = firstPrompt ?? "" }
            chats.append(SessionSummary(nativeID: id, editor: editor, sourcePath: f.path, title: Str.clean(title, max: 90),
                                        project: Self.folder(d.str("workspaceDirectory")), start: start, end: max(start, f.mtime),
                                        userMessages: users, assistantMessages: assistants, tools: tools,
                                        userTimes: users > 0 ? [start] : [], fallbackModel: "continue"))
        }
        // Attach token events to the chat open at the time; leftovers go into one row per day.
        var daily: [Date: SessionSummary] = [:]
        let cal = Calendar.current
        for r in tokenRows() {
            let e = UsageEvent(timestamp: r.ts, model: r.model, tokens: TokenUsage(input: r.prompt, output: r.generated),
                               reportedCost: r.isLocal ? 0 : nil)
            if let i = chats.firstIndex(where: { r.ts >= $0.start && r.ts <= $0.end.addingTimeInterval(300) }) {
                chats[i].events.append(e); chats[i].finalize(); continue
            }
            let day = cal.startOfDay(for: r.ts)
            var s = daily[day] ?? SessionSummary(
                nativeID: "usage-\(Int(day.timeIntervalSince1970))", editor: editor, sourcePath: file.path,
                title: "Model usage (autocomplete & edits)", project: "", start: r.ts, end: r.ts)
            s.start = min(s.start, r.ts); s.end = max(s.end, r.ts)
            s.assistantMessages += 1
            s.events.append(e)
            daily[day] = s
        }
        return chats + daily.values.map { var s = $0; s.finalize(); return s }
    }

    static func text(_ any: Any?) -> String {
        if let s = any as? String { return s }
        return (any as? [[String: Any]] ?? []).compactMap { $0.str("text") }.joined(separator: "\n")
    }

    static func folder(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "" }
        if s.hasPrefix("file://"), let u = URL(string: s) { return u.path }
        return s
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        guard let d = FS.readJSON(session.sourcePath) as? [String: Any] else { return [] }
        var out: [TranscriptMessage] = []
        for h in d.arr("history") as? [[String: Any]] ?? [] {
            guard let m = h.obj("message") else { continue }
            switch m.str("role") {
            case "user": out.append(.init(role: .user, text: Self.text(m["content"]), timestamp: nil))
            case "assistant":
                let t = Self.text(m["content"])
                if !t.isEmpty { out.append(.init(role: .assistant, text: t, timestamp: nil)) }
                for case let c as [String: Any] in m.arr("toolCalls") ?? [] {
                    out.append(.init(role: .tool, text: c.obj("function")?.str("arguments") ?? "", timestamp: nil,
                                     toolName: c.obj("function")?.str("name")))
                }
            default: break
            }
        }
        return out
    }
}

// MARK: - Cline, Roo Code, Kilo Code (fixture-tested)

/// VS Code-family globalStorage/<extension>/tasks/<id>/ui_messages.json, plus ~/.cline/data/tasks.
/// The three extensions share Cline's task format; `api_req_started` rows carry tokens and cost.
struct ClineSource: UsageSource {
    let editor = Editor.cline
    var roots: [String] = ClineSource.defaultRoots()

    static let extensionIDs = ["saoudrizwan.claude-dev", "rooveterinaryinc.roo-cline", "kilocode.kilo-code"]

    static func defaultRoots() -> [String] {
        let apps = ["Code", "Code - Insiders", "Cursor", "Windsurf", "VSCodium", "Kiro"]
        var out = [AppPaths.expand(".cline/data/tasks")]
        for app in apps {
            for ext in extensionIDs {
                out.append(AppPaths.expand("Library/Application Support/\(app)/User/globalStorage/\(ext)/tasks"))
            }
        }
        return out
    }

    var watchRoots: [String] { roots.filter(FS.exists) }
    func discover() -> [SourceFile] {
        watchRoots.flatMap { FS.find($0, maxDepth: 2) { $0 == "ui_messages.json" } }
    }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        guard let msgs = FS.readJSON(file.path) as? [[String: Any]], !msgs.isEmpty else { return [] }
        let dir = (file.path as NSString).deletingLastPathComponent
        let models = Self.modelTimeline(dir)
        var users = 0, assistants = 0
        var tools: [String: Int] = [:]
        var events: [UsageEvent] = []
        var userTimes: [Date] = []
        var title = "", project = ""
        var start: Date?, end: Date?
        for m in msgs {
            let ts = Dates.parse(m["ts"]) ?? file.mtime
            start = min(start ?? ts, ts); end = max(end ?? ts, ts)
            let kind = m.str("say") ?? m.str("ask") ?? ""
            switch kind {
            case "task", "user_feedback":
                users += 1; userTimes.append(ts)
                if title.isEmpty { title = m.str("text") ?? "" }
            case "api_req_started":
                guard let info = parseJSONObject(m.str("text")) else { continue }
                assistants += 1
                if project.isEmpty, let req = info.str("request") { project = Self.cwd(in: req) ?? "" }
                let t = TokenUsage(input: info.int("tokensIn"), output: info.int("tokensOut"),
                                   cacheRead: info.int("cacheReads"), cacheWrite: info.int("cacheWrites"))
                guard !t.isZero || info.dbl("cost") != nil else { continue }
                let model = models.last(where: { $0.0 <= ts })?.1 ?? models.first?.1 ?? "claude-sonnet-4"
                events.append(UsageEvent(timestamp: ts, model: model, tokens: t, reportedCost: info.dbl("cost")))
            case "tool":
                let name = parseJSONObject(m.str("text"))?.str("tool") ?? "tool"
                tools[name, default: 0] += 1
            case "command": tools["execute_command", default: 0] += 1
            case "use_mcp_server": tools["mcp", default: 0] += 1
            default: break
            }
        }
        guard users + assistants > 0 else { return [] }
        let id = (dir as NSString).lastPathComponent
        return [SessionSummary(nativeID: id, editor: editor, sourcePath: file.path, title: Str.clean(title, max: 90),
                               project: project, start: start ?? file.mtime, end: end ?? file.mtime,
                               userMessages: users, assistantMessages: assistants, tools: tools, events: events,
                               userTimes: userTimes, fallbackModel: models.last?.1 ?? "claude-sonnet-4")]
    }

    /// task_metadata.json → [(time, model)] so each request is priced on the model active then.
    static func modelTimeline(_ dir: String) -> [(Date, String)] {
        guard let meta = FS.readJSON(dir + "/task_metadata.json") as? [String: Any] else { return [] }
        return (meta.arr("model_usage") as? [[String: Any]] ?? []).compactMap { u in
            guard let id = u.str("model_id") else { return nil }
            return (Dates.parse(u["ts"]) ?? .distantPast, id)
        }.sorted { $0.0 < $1.0 }
    }

    static func cwd(in text: String) -> String? {
        for marker in ["Current Working Directory (", "Current Workspace Directory ("] {
            guard let r = text.range(of: marker), let close = text[r.upperBound...].firstIndex(of: ")") else { continue }
            return String(text[r.upperBound..<close])
        }
        return nil
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        guard let msgs = FS.readJSON(session.sourcePath) as? [[String: Any]] else { return [] }
        var out: [TranscriptMessage] = []
        for m in msgs {
            let ts = Dates.parse(m["ts"])
            switch m.str("say") ?? m.str("ask") ?? "" {
            case "task", "user_feedback": out.append(.init(role: .user, text: m.str("text") ?? "", timestamp: ts))
            case "text", "completion_result":
                if let t = m.str("text"), !t.isEmpty { out.append(.init(role: .assistant, text: t, timestamp: ts)) }
            case "tool":
                let info = parseJSONObject(m.str("text"))
                out.append(.init(role: .tool, text: info?.str("path") ?? "", timestamp: ts, toolName: info?.str("tool") ?? "tool"))
            case "command": out.append(.init(role: .tool, text: m.str("text") ?? "", timestamp: ts, toolName: "execute_command"))
            default: break
            }
        }
        return out
    }
}

// MARK: - Aider (fixture-tested)

/// `.aider.chat.history.md` in each project root. Aider writes one "# aider chat started at"
/// header per run and a "> Tokens: … Cost: …" line after each response.
struct AiderSource: UsageSource {
    let editor = Editor.aider
    var searchRoots: [String] = ["Projects", "Developer", "code", "src", "dev", "work", "repos", "git", "Documents/GitHub", "Sites"]
        .map(AppPaths.expand) + [AppPaths.home.path]
    /// Scanning project folders is the expensive part, so the file list is reused for a while.
    var rescanInterval: TimeInterval = 600

    // Watching whole project trees would fire on every code edit; the 60 s timer picks up changes.
    var watchRoots: [String] { [] }

    nonisolated(unsafe) private static var cached: (at: Date, roots: [String], paths: [String])?
    private static let lock = NSLock()

    func discover() -> [SourceFile] {
        Self.lock.lock()
        let hit = Self.cached
        Self.lock.unlock()
        let paths: [String]
        if let hit, hit.roots == searchRoots, Date().timeIntervalSince(hit.at) < rescanInterval {
            paths = hit.paths
        } else {
            paths = Self.scan(searchRoots)
            Self.lock.lock(); Self.cached = (Date(), searchRoots, paths); Self.lock.unlock()
        }
        return paths.compactMap(FS.stat)
    }

    static let skipDirs: Set<String> = ["node_modules", "Library", "DerivedData", "Pods", "build", "dist", "target",
                                        "vendor", "venv", "Applications", "Movies", "Music", "Pictures"]

    static func scan(_ roots: [String]) -> [String] {
        var out = Set<String>()
        for root in roots where FS.exists(root) {
            let isHome = root == AppPaths.home.path
            let direct = (root as NSString).appendingPathComponent(".aider.chat.history.md")
            if FS.exists(direct) { out.insert(direct) }
            if isHome { continue }
            guard let en = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsPackageDescendants]) else { continue }
            for case let u as URL in en {
                let name = u.lastPathComponent
                if name == ".aider.chat.history.md" { out.insert(u.path); continue }
                let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                if en.level >= 4 || name.hasPrefix(".") || skipDirs.contains(name) { en.skipDescendants() }
            }
        }
        return out.sorted()
    }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        guard let text = try? String(contentsOfFile: file.path, encoding: .utf8) else { return [] }
        return Self.parse(text: text, file: file)
    }

    nonisolated(unsafe) private static let headerDate: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    struct Run {
        var start: Date
        var model = "unknown"
        var prompts = 0
        var responses = 0
        var title = ""
        var tools: [String: Int] = [:]
        var events: [UsageEvent] = []
        var lastWasPrompt = false
    }

    static func parse(text: String, file: SourceFile) -> [SessionSummary] {
        var runs: [Run] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("# aider chat started at ") {
                let d = headerDate.date(from: String(line.dropFirst("# aider chat started at ".count)).trimmingCharacters(in: .whitespaces))
                runs.append(Run(start: d ?? file.mtime)); continue
            }
            guard !runs.isEmpty else { continue }
            let i = runs.count - 1
            if line.hasPrefix("#### ") {
                if !runs[i].lastWasPrompt {
                    runs[i].prompts += 1
                    if runs[i].title.isEmpty { runs[i].title = String(line.dropFirst(5)) }
                }
                runs[i].lastWasPrompt = true
                continue
            }
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { runs[i].lastWasPrompt = false }
            guard line.hasPrefix("> ") else { continue }
            let body = String(line.dropFirst(2))
            if body.hasPrefix("Main model: ") || body.hasPrefix("Model: ") {
                let rest = body.hasPrefix("Main model: ") ? body.dropFirst(12) : body.dropFirst(7)
                runs[i].model = String(rest.split(separator: " ").first ?? "unknown")
            } else if body.hasPrefix("Tokens: ") {
                runs[i].responses += 1
                let (t, cost) = tokensLine(body)
                runs[i].events.append(UsageEvent(timestamp: runs[i].start, model: runs[i].model, tokens: t, reportedCost: cost))
            } else if body.hasPrefix("Applied edit to ") {
                runs[i].tools["edit", default: 0] += 1
            } else if body.hasPrefix("Commit ") {
                runs[i].tools["commit", default: 0] += 1
            } else if body.hasPrefix("Run shell command") || body.hasPrefix("Running ") {
                runs[i].tools["shell", default: 0] += 1
            }
        }
        let project = (file.path as NSString).deletingLastPathComponent
        var out: [SessionSummary] = []
        for (n, r) in runs.enumerated() where r.prompts > 0 {
            let next = n + 1 < runs.count ? runs[n + 1].start : file.mtime
            // Without per-turn timestamps, assume a run lasts until the next one, capped at 3 hours.
            let end = max(r.start, min(next, r.start.addingTimeInterval(3 * 3600)))
            out.append(SessionSummary(nativeID: "\(file.path)#\(Int(r.start.timeIntervalSince1970))", editor: .aider,
                                      sourcePath: file.path, title: Str.clean(r.title, max: 90), project: project,
                                      start: r.start, end: end, userMessages: r.prompts,
                                      assistantMessages: max(r.responses, r.prompts), tools: r.tools, events: r.events,
                                      userTimes: Array(repeating: r.start, count: r.prompts), fallbackModel: r.model))
        }
        return out
    }

    /// "Tokens: 12k sent, 3.4k cache write, 1.2k cache hit, 300 received. Cost: $0.01 message, $0.05 session."
    static func tokensLine(_ s: String) -> (TokenUsage, Double?) {
        var t = TokenUsage()
        let counts = s.dropFirst("Tokens: ".count).components(separatedBy: ". ").first ?? ""
        for seg in counts.split(separator: ",") {
            let words = seg.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard words.count == 2 else { continue }
            let n = number(String(words[0]))
            switch words[1] {
            case "sent": t.input += n
            case "received": t.output += n
            case "cache write": t.cacheWrite += n
            case "cache hit": t.cacheRead += n
            default: break
            }
        }
        // Aider's "sent" includes cached tokens; keep only the uncached part as input.
        t.input = max(0, t.input - t.cacheRead - t.cacheWrite)
        var cost: Double?
        if let r = s.range(of: "Cost: $") {
            let num = s[r.upperBound...].prefix { $0.isNumber || $0 == "." }
            cost = Double(num)
        }
        return (t, cost)
    }

    static func number(_ s: String) -> Int {
        let lower = s.lowercased()
        let mult: Double = lower.hasSuffix("k") ? 1_000 : lower.hasSuffix("m") ? 1_000_000 : 1
        let digits = mult == 1 ? lower : String(lower.dropLast())
        return Int((Double(digits.replacingOccurrences(of: ",", with: "")) ?? 0) * mult)
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        guard let text = try? String(contentsOfFile: session.sourcePath, encoding: .utf8) else { return [] }
        let stamp = session.nativeID.split(separator: "#").last.flatMap { Double($0) }
        var inRun = false
        var out: [TranscriptMessage] = []
        var buffer: [String] = []
        func flush() {
            let t = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.init(role: .assistant, text: t, timestamp: nil)) }
            buffer = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("# aider chat started at ") {
                if inRun { break }
                let d = Self.headerDate.date(from: String(line.dropFirst(24)).trimmingCharacters(in: .whitespaces))
                inRun = d.map { Double(Int($0.timeIntervalSince1970)) } == stamp
                continue
            }
            guard inRun else { continue }
            if line.hasPrefix("#### ") {
                flush()
                if let last = out.last, last.role == .user {
                    out[out.count - 1] = .init(role: .user, text: last.text + "\n" + line.dropFirst(5), timestamp: nil)
                } else { out.append(.init(role: .user, text: String(line.dropFirst(5)), timestamp: nil)) }
            } else if line.hasPrefix("> Applied edit to ") {
                flush(); out.append(.init(role: .tool, text: String(line.dropFirst(18)), timestamp: nil, toolName: "edit"))
            } else if !line.hasPrefix(">") {
                buffer.append(line)
            }
        }
        flush()
        return out
    }
}

// MARK: - Kiro (layout verified, turns fixture-tested)

/// Kiro IDE: ~/.kiro/sessions/<workspace-hash>/sess_*/{session.json,messages.jsonl}.
/// Kiro CLI: ~/.kiro/sessions/cli/<id>.json (+ .jsonl). The CLI folder can hold tens of thousands
/// of empty session shells, so only files that look like they hold turns are read.
struct KiroSource: UsageSource {
    let editor = Editor.kiro
    var root = AppPaths.expand(".kiro/sessions")
    var watchRoots: [String] { FS.exists(root) ? [root] : [] }

    nonisolated(unsafe) private static var cliCache: (at: Date, root: String, paths: [String])?
    private static let lock = NSLock()

    func discover() -> [SourceFile] {
        guard FS.exists(root) else { return [] }
        var out: [SourceFile] = []
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        for d in dirs where d != "cli" {
            out += FS.find(root + "/" + d, maxDepth: 2) { $0 == "messages.jsonl" }
        }
        return out + cliFiles()
    }

    /// CLI sessions with content: a non-empty .jsonl, or a .json bigger than an empty shell (~1 KB).
    /// The full listing is refreshed every 5 minutes; known candidates are re-checked every time.
    private func cliFiles() -> [SourceFile] {
        let cli = root + "/cli"
        guard FS.exists(cli) else { return [] }
        Self.lock.lock(); let hit = Self.cliCache; Self.lock.unlock()
        if let hit, hit.root == root, Date().timeIntervalSince(hit.at) < 300 {
            return hit.paths.compactMap(FS.stat)
        }
        var keep: [SourceFile] = []
        let all = FS.find(cli, maxDepth: 1) { $0.hasSuffix(".json") || $0.hasSuffix(".jsonl") }
        let bySize = Dictionary(all.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        for f in all where f.path.hasSuffix(".json") {
            let jsonl = String(f.path.dropLast(5)) + ".jsonl"
            if f.size > 1500 || (bySize[jsonl] ?? 0) > 0 { keep.append(f) }
        }
        Self.lock.lock(); Self.cliCache = (Date(), root, keep.map(\.path)); Self.lock.unlock()
        return keep
    }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        file.path.hasSuffix("messages.jsonl") ? parseIDE(file) : parseCLI(file)
    }

    private func parseIDE(_ file: SourceFile) -> [SessionSummary] {
        let dir = (file.path as NSString).deletingLastPathComponent
        let meta = FS.readJSON(dir + "/session.json") as? [String: Any] ?? [:]
        var c = Counter()
        FS.eachJSONLine(file.path) { c.add($0) }
        guard c.users > 0 else { return [] }   // tool-only sessions are Kiro's own startup checks
        var title = meta.str("title") ?? ""
        if title.isEmpty || title == "New Session" { title = c.firstPrompt ?? "" }
        let start = Dates.parse(meta["createdAt"]) ?? c.start ?? file.mtime
        return [SessionSummary(nativeID: meta.str("id") ?? (dir as NSString).lastPathComponent, editor: editor,
                               sourcePath: file.path, title: Str.clean(title, max: 90),
                               project: (meta.arr("workspacePaths")?.first as? String) ?? "",
                               start: start, end: max(start, Dates.parse(meta["lastModifiedAt"]) ?? c.end ?? file.mtime),
                               userMessages: c.users, assistantMessages: c.assistants, tools: c.tools,
                               events: c.events, userTimes: c.userTimes, fallbackModel: c.model ?? "kiro")]
    }

    private func parseCLI(_ file: SourceFile) -> [SessionSummary] {
        guard let d = FS.readJSON(file.path) as? [String: Any] else { return [] }
        var c = Counter()
        let jsonl = String(file.path.dropLast(5)) + ".jsonl"
        if FS.exists(jsonl) { FS.eachJSONLine(jsonl) { c.add($0) } }
        // Per-turn metadata carries the token counts when Kiro records them.
        let state = d.obj("session_state")
        let turns = state?.obj("conversation_metadata")?.arr("user_turn_metadatas") as? [[String: Any]] ?? []
        let model = (state?.obj("rts_model_state")?.obj("model_info")?.str("model_id")) ?? c.model ?? "kiro"
        for t in turns {
            let ts = Dates.parse(t["request_start_timestamp_ms"] ?? t["timestamp"]) ?? file.mtime
            let tokens = TokenUsage(input: Self.findInt(t, ["input_token", "inputToken", "prompt_token"]),
                                    output: Self.findInt(t, ["output_token", "outputToken", "completion_token"]))
            if !tokens.isZero { c.events.append(UsageEvent(timestamp: ts, model: model, tokens: tokens, reportedCost: nil)) }
        }
        let users = max(c.users, turns.count)
        guard users > 0 else { return [] }
        let start = Dates.parse(d["created_at"]) ?? c.start ?? file.mtime
        let title = d.str("title") ?? c.firstPrompt ?? ""
        return [SessionSummary(nativeID: d.str("session_id") ?? file.path, editor: editor, sourcePath: file.path,
                               title: Str.clean(title, max: 90), project: d.str("cwd") ?? "",
                               start: start, end: max(start, Dates.parse(d["updated_at"]) ?? file.mtime),
                               userMessages: users, assistantMessages: max(c.assistants, c.events.count), tools: c.tools,
                               events: c.events, userTimes: c.userTimes.isEmpty ? [start] : c.userTimes, fallbackModel: model)]
    }

    /// Sums integer fields whose key contains one of `needles` (searched one level deep).
    static func findInt(_ d: [String: Any], _ needles: [String]) -> Int {
        var total = 0
        for (k, v) in d {
            if let n = v as? NSNumber, needles.contains(where: { k.localizedCaseInsensitiveContains($0) }) { total += n.intValue }
            else if let sub = v as? [String: Any] { total += findInt(sub, needles) }
        }
        return total
    }

    /// Tolerant line classifier: Kiro's event names vary between versions.
    struct Counter {
        var users = 0, assistants = 0
        var tools: [String: Int] = [:]
        var events: [UsageEvent] = []
        var userTimes: [Date] = []
        var firstPrompt: String?
        var model: String?
        var start: Date?, end: Date?

        mutating func add(_ o: [String: Any]) {
            let p = o.obj("payload") ?? o
            let ts = Dates.parse(o["timestamp"] ?? p["timestamp"])
            if let ts { start = min(start ?? ts, ts); end = max(end ?? ts, ts) }
            let kind = (p.str("role") ?? p.str("type") ?? o.str("type") ?? "").lowercased()
            if let m = p.str("model") ?? p.str("modelId") { model = m }
            if kind.contains("tool_call") || kind.contains("tooluse") || kind == "tool_use" {
                tools[p.str("toolName") ?? p.str("name") ?? "tool", default: 0] += 1
            } else if kind.contains("user") || kind == "prompt" || kind == "human" {
                let text = Self.text(p)
                guard !Str.looksInjected(text) || text.isEmpty else { return }
                users += 1
                if let ts { userTimes.append(ts) }
                if firstPrompt == nil, !text.isEmpty { firstPrompt = text }
            } else if kind.contains("assistant") || kind.contains("agent") || kind.contains("response") {
                assistants += 1
                let t = TokenUsage(input: KiroSource.findInt(p, ["input_token", "inputToken"]),
                                   output: KiroSource.findInt(p, ["output_token", "outputToken"]))
                if !t.isZero, let ts { events.append(UsageEvent(timestamp: ts, model: model ?? "kiro", tokens: t, reportedCost: nil)) }
            }
        }

        static func text(_ p: [String: Any]) -> String {
            if let s = p.str("content") ?? p.str("text") ?? p.str("prompt") { return s }
            return (p.arr("content") as? [[String: Any]] ?? []).compactMap { $0.str("text") }.joined(separator: "\n")
        }
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        var path = session.sourcePath
        if path.hasSuffix(".json") { path = String(path.dropLast(5)) + ".jsonl" }
        var out: [TranscriptMessage] = []
        FS.eachJSONLine(path) { o in
            let p = o.obj("payload") ?? o
            let ts = Dates.parse(o["timestamp"] ?? p["timestamp"])
            let kind = (p.str("role") ?? p.str("type") ?? o.str("type") ?? "").lowercased()
            if kind.contains("tool_call") || kind == "tool_use" {
                out.append(.init(role: .tool, text: "", timestamp: ts, toolName: p.str("toolName") ?? p.str("name")))
            } else if kind.contains("tool") {
                return
            } else if kind.contains("user") || kind == "prompt" {
                out.append(.init(role: .user, text: Counter.text(p), timestamp: ts))
            } else if kind.contains("assistant") || kind.contains("agent") || kind.contains("response") {
                let t = Counter.text(p)
                if !t.isEmpty { out.append(.init(role: .assistant, text: t, timestamp: ts)) }
            }
        }
        return out
    }
}

// MARK: - Factory Droid (fixture-tested)

/// ~/.factory/sessions/**/<id>.jsonl (messages) with <id>.settings.json (model and token totals).
struct FactorySource: UsageSource {
    let editor = Editor.factory
    var root = AppPaths.expand(".factory/sessions")
    var watchRoots: [String] { FS.exists(root) ? [root] : [] }
    func discover() -> [SourceFile] {
        guard FS.exists(root) else { return [] }
        return FS.find(root, maxDepth: 2) { $0.hasSuffix(".jsonl") }
    }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        var users = 0, assistants = 0
        var tools: [String: Int] = [:]
        var userTimes: [Date] = []
        var title = "", project = ""
        var start: Date?, end: Date?
        var id = ((file.path as NSString).lastPathComponent as NSString).deletingPathExtension
        FS.eachJSONLine(file.path) { o in
            let ts = Dates.parse(o["timestamp"])
            if let ts { start = min(start ?? ts, ts); end = max(end ?? ts, ts) }
            if o.str("type") == "session_start" {
                if let i = o.str("id") { id = i }
                if let t = o.str("title") { title = t }
                if let c = o.str("cwd") { project = c }
                return
            }
            guard let m = o.obj("message") else { return }
            let parts = m.arr("content") as? [[String: Any]] ?? []
            switch m.str("role") {
            case "user":
                // Tool results come back as user messages; only text from the person counts.
                let text = (m["content"] as? String) ?? parts.filter { $0.str("type") == "text" }.compactMap { $0.str("text") }.joined(separator: "\n")
                guard !text.isEmpty, !Str.looksInjected(text) else { return }
                users += 1
                if let ts { userTimes.append(ts) }
                if title.isEmpty { title = text }
            case "assistant":
                assistants += 1
                for p in parts where p.str("type") == "tool_use" { tools[p.str("name") ?? "tool", default: 0] += 1 }
            default: break
            }
        }
        guard users + assistants > 0 else { return [] }
        let settings = FS.readJSON(String(file.path.dropLast(6)) + ".settings.json") as? [String: Any] ?? [:]
        let model = settings.str("model") ?? "claude-sonnet-4"
        var events: [UsageEvent] = []
        if let u = settings.obj("tokenUsage") {
            let t = TokenUsage(input: u.int("inputTokens"), output: u.int("outputTokens") + u.int("thinkingTokens"),
                               cacheRead: u.int("cacheReadTokens"), cacheWrite: u.int("cacheCreationTokens"),
                               reasoning: u.int("thinkingTokens"))
            if !t.isZero { events.append(UsageEvent(timestamp: end ?? file.mtime, model: model, tokens: t, reportedCost: nil)) }
        }
        return [SessionSummary(nativeID: id, editor: editor, sourcePath: file.path, title: Str.clean(title, max: 90),
                               project: project, start: start ?? file.mtime, end: end ?? file.mtime,
                               userMessages: users, assistantMessages: assistants, tools: tools, events: events,
                               userTimes: userTimes, fallbackModel: model)]
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        var out: [TranscriptMessage] = []
        FS.eachJSONLine(session.sourcePath) { o in
            guard let m = o.obj("message") else { return }
            let ts = Dates.parse(o["timestamp"])
            let parts = m.arr("content") as? [[String: Any]] ?? []
            let role: TranscriptRole = m.str("role") == "user" ? .user : .assistant
            if let s = m["content"] as? String { out.append(.init(role: role, text: s, timestamp: ts)); return }
            for p in parts {
                switch p.str("type") {
                case "text": if let t = p.str("text"), !t.isEmpty { out.append(.init(role: role, text: t, timestamp: ts)) }
                case "tool_use": out.append(.init(role: .tool, text: "", timestamp: ts, toolName: p.str("name")))
                default: break
                }
            }
        }
        return out
    }
}
