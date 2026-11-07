import Foundation

/// GitHub Copilot CLI: ~/.copilot/session-state/<id>/events.jsonl
/// The CLI records premium requests, not tokens, so token totals stay at zero.
struct CopilotCLISource: UsageSource {
    let editor = Editor.copilotCLI
    var root: String { AppPaths.expand(".copilot/session-state") }
    var watchRoots: [String] { FS.exists(root) ? [root] : [] }

    func discover() -> [SourceFile] {
        guard FS.exists(root) else { return [] }
        return FS.find(root, maxDepth: 2) { $0 == "events.jsonl" }
    }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        var id = ((file.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        var cwd = "", model: String?
        var firstPrompt: String?
        var start: Date?, end: Date?
        var users = 0, assistants = 0
        var tools: [String: Int] = [:]
        var userTimes: [Date] = []
        var modelCounts: [String: Int] = [:]

        FS.eachJSONLine(file.path) { obj in
            let ts = Dates.parse(obj["timestamp"])
            if let ts { start = min(start ?? ts, ts); end = max(end ?? ts, ts) }
            let d = obj.obj("data") ?? [:]
            switch obj.str("type") {
            case "session.start":
                id = d.str("sessionId") ?? id
                cwd = d.obj("context")?.str("cwd") ?? cwd
                if let st = Dates.parse(d["startTime"]) { start = min(start ?? st, st) }
            case "session.model_change": model = d.str("newModel") ?? model
            case "user.message":
                users += 1; if let ts { userTimes.append(ts) }
                if firstPrompt == nil { firstPrompt = d.str("content") }
            case "assistant.message": assistants += 1
            case "tool.execution_start":
                if let n = d.str("toolName"), n != "report_intent" { tools[n, default: 0] += 1 }
            case "tool.execution_complete":
                if let m = d.str("model") { modelCounts[m, default: 0] += 1 }
            default: break
            }
        }
        guard let s = start, let e = end, users + assistants > 0 else { return [] }
        let primary = modelCounts.max { $0.value < $1.value }?.key ?? model ?? "copilot"
        return [SessionSummary(nativeID: id, editor: editor, sourcePath: file.path,
                               title: Str.clean(firstPrompt ?? "", max: 90), project: cwd, start: s, end: e,
                               userMessages: users, assistantMessages: assistants, tools: tools,
                               userTimes: userTimes, fallbackModel: primary)]
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        var out: [TranscriptMessage] = []
        FS.eachJSONLine(session.sourcePath) { obj in
            let ts = Dates.parse(obj["timestamp"]); let d = obj.obj("data") ?? [:]
            switch obj.str("type") {
            case "user.message": out.append(.init(role: .user, text: d.str("content") ?? "", timestamp: ts))
            case "assistant.message":
                if let c = d.str("content"), !c.isEmpty { out.append(.init(role: .assistant, text: c, timestamp: ts)) }
                for case let t as [String: Any] in d.arr("toolRequests") ?? [] where t.str("name") != "report_intent" {
                    let args = (t["arguments"]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted]) }
                        .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                    out.append(.init(role: .tool, text: "```json\n\(args)\n```", timestamp: ts, toolName: t.str("name")))
                }
            default: break
            }
        }
        return out
    }
}

/// VS Code Copilot Chat: ~/Library/Application Support/Code*/User/workspaceStorage/<hash>/chatSessions/*.json(l)
/// .json files are full snapshots; .jsonl files are an initial snapshot plus set/append patches.
struct CopilotVSCodeSource: UsageSource {
    let editor = Editor.copilotVSCode

    var storageRoots: [String] {
        ["Code", "Code - Insiders", "VSCodium"].map {
            AppPaths.expand("Library/Application Support/\($0)/User/workspaceStorage")
        }.filter(FS.exists)
    }
    var watchRoots: [String] { storageRoots }

    func discover() -> [SourceFile] {
        storageRoots.flatMap { root in
            FS.find(root, maxDepth: 3) { $0.hasSuffix(".json") || $0.hasSuffix(".jsonl") }
                .filter { $0.path.contains("/chatSessions/") }
        }
    }

    /// Rebuild the session object.
    static func load(_ path: String) -> [String: Any]? {
        if path.hasSuffix(".json") { return FS.readJSON(path) as? [String: Any] }
        var root: Any = [String: Any]()
        FS.eachJSONLine(path) { patch in
            switch patch.int("kind") {
            case 0: root = patch["v"] ?? root
            case 1: if let k = patch.arr("k") { root = setValue(root, path: k[...], value: patch["v"] ?? NSNull(), append: false, index: nil) }
            case 2: if let k = patch.arr("k") { root = setValue(root, path: k[...], value: patch["v"] ?? [], append: true, index: patch["i"] as? Int) }
            default: break
            }
        }
        return root as? [String: Any]
    }

    private static func setValue(_ node: Any, path: ArraySlice<Any>, value: Any, append: Bool, index: Int?) -> Any {
        guard let head = path.first else {
            guard append else { return value }
            var arr = node as? [Any] ?? []
            let items = value as? [Any] ?? [value]
            if let i = index, i >= 0, i <= arr.count { arr = Array(arr[..<i]) }
            arr.append(contentsOf: items)
            return arr
        }
        let rest = path.dropFirst()
        if let key = head as? String {
            var dict = node as? [String: Any] ?? [:]
            dict[key] = setValue(dict[key] ?? (append && rest.isEmpty ? [Any]() : [String: Any]()), path: rest, value: value, append: append, index: index)
            return dict
        }
        if let i = head as? Int {
            var arr = node as? [Any] ?? []
            while arr.count <= i { arr.append([String: Any]()) }
            arr[i] = setValue(arr[i], path: rest, value: value, append: append, index: index)
            return arr
        }
        return node
    }

    static func workspaceFolder(for chatPath: String) -> String {
        let wsDir = ((chatPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        guard let ws = FS.readJSON((wsDir as NSString).appendingPathComponent("workspace.json")) as? [String: Any],
              let folder = ws.str("folder") ?? ws.str("workspace"),
              let url = URL(string: folder) else { return "" }
        return url.path
    }

    func parse(_ file: SourceFile) -> [SessionSummary] {
        guard let s = Self.load(file.path) else { return [] }
        let requests = s.arr("requests") as? [[String: Any]] ?? []
        guard !requests.isEmpty else { return [] }
        var tools: [String: Int] = [:]
        var events: [UsageEvent] = []
        var userTimes: [Date] = []
        var start = Dates.parse(s["creationDate"]), end = Dates.parse(s["lastMessageDate"])
        var model = "copilot"
        for r in requests {
            let ts = Dates.parse(r["timestamp"]) ?? start ?? file.mtime
            userTimes.append(ts)
            start = min(start ?? ts, ts); end = max(end ?? ts, ts)
            if let m = r.str("modelId") { model = m.components(separatedBy: "/").last ?? m }
            for case let part as [String: Any] in r.arr("response") ?? [] {
                if let tool = part.str("toolId") { tools[tool.replacingOccurrences(of: "copilot_", with: ""), default: 0] += 1 }
            }
            let out = r.int("completionTokens")
            let input = r.obj("result")?.obj("metadata")?.int("promptTokens") ?? 0
            if out + input > 0 {
                events.append(UsageEvent(timestamp: ts, model: model, tokens: TokenUsage(input: input, output: out), reportedCost: nil))
            }
        }
        let firstText = requests.first?.obj("message")?.str("text") ?? ""
        let title = s.str("customTitle") ?? Str.clean(firstText, max: 90)
        return [SessionSummary(nativeID: s.str("sessionId") ?? file.path, editor: editor, sourcePath: file.path,
                               title: title, project: Self.workspaceFolder(for: file.path),
                               start: start ?? file.mtime, end: end ?? file.mtime,
                               userMessages: requests.count, assistantMessages: requests.count,
                               tools: tools, events: events, userTimes: userTimes, fallbackModel: model)]
    }

    func transcript(for session: SessionSummary) -> [TranscriptMessage] {
        guard let s = Self.load(session.sourcePath) else { return [] }
        var out: [TranscriptMessage] = []
        for r in s.arr("requests") as? [[String: Any]] ?? [] {
            let ts = Dates.parse(r["timestamp"])
            out.append(.init(role: .user, text: r.obj("message")?.str("text") ?? "", timestamp: ts))
            var text = ""
            for case let part as [String: Any] in r.arr("response") ?? [] {
                if let v = part["value"] as? String { text += v }
                else if let tool = part.str("toolId") {
                    if !text.isEmpty { out.append(.init(role: .assistant, text: text, timestamp: ts, model: r.str("modelId"))); text = "" }
                    let msg = (part.obj("invocationMessage")?.str("value")) ?? (part["invocationMessage"] as? String) ?? ""
                    out.append(.init(role: .tool, text: msg, timestamp: ts, toolName: tool))
                }
            }
            if !text.isEmpty { out.append(.init(role: .assistant, text: text, timestamp: ts, model: r.str("modelId"))) }
        }
        return out
    }
}
