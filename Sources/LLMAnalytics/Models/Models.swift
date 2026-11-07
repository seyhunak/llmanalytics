import Foundation
import SwiftUI

/// Every AI coding tool the app knows how to read local history from.
enum Editor: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case claudeCode
    case codex
    case cursor
    case copilotCLI
    case copilotVSCode
    case gemini
    case opencode

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .copilotCLI: "Copilot CLI"
        case .copilotVSCode: "Copilot (VS Code)"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        }
    }

    var symbol: String {
        switch self {
        case .claudeCode: "sparkle"
        case .codex: "terminal"
        case .cursor: "cursorarrow.rays"
        case .copilotCLI: "airplane"
        case .copilotVSCode: "chevron.left.forwardslash.chevron.right"
        case .gemini: "diamond"
        case .opencode: "curlybraces"
        }
    }

    var color: Color {
        switch self {
        case .claudeCode: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.20, green: 0.62, blue: 0.52)
        case .cursor: Color(red: 0.36, green: 0.42, blue: 0.95)
        case .copilotCLI: Color(red: 0.55, green: 0.36, blue: 0.85)
        case .copilotVSCode: Color(red: 0.16, green: 0.55, blue: 0.86)
        case .gemini: Color(red: 0.85, green: 0.65, blue: 0.13)
        case .opencode: Color(red: 0.55, green: 0.55, blue: 0.60)
        }
    }
}

struct TokenUsage: Hashable, Codable, Sendable {
    var input: Int = 0        // non-cached input
    var output: Int = 0       // includes reasoning where the vendor bills it that way
    var cacheRead: Int = 0
    var cacheWrite: Int = 0   // short-lived (5-minute) cache writes, or the vendor's only kind
    var reasoning: Int = 0    // informational subset of output
    var cacheWrite1h: Int = 0 // Anthropic 1-hour cache writes (billed at 2x input)

    /// All cache writes regardless of TTL — what the UI shows as "Cache write".
    var allCacheWrite: Int { cacheWrite + cacheWrite1h }
    var total: Int { input + output + cacheRead + allCacheWrite }
    var allInput: Int { input + cacheRead + allCacheWrite }
    var isZero: Bool { total == 0 }

    static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
        TokenUsage(input: a.input + b.input, output: a.output + b.output,
                   cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite,
                   reasoning: a.reasoning + b.reasoning, cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h)
    }
    static func += (a: inout TokenUsage, b: TokenUsage) { a = a + b }
}

/// One billable model response.
struct UsageEvent: Hashable, Codable, Sendable {
    let timestamp: Date
    let model: String
    let tokens: TokenUsage
    /// Cost reported by the tool itself (OpenCode), otherwise nil and we estimate.
    let reportedCost: Double?

    var cost: Double { reportedCost ?? Pricing.cost(model: model, tokens: tokens) }
}

struct SessionSummary: Identifiable, Hashable, Codable, Sendable {
    let id: String               // "<editor>:<native id>"
    let nativeID: String
    let editor: Editor
    let sourcePath: String
    var title: String
    var project: String          // absolute path or a label
    var start: Date
    var end: Date
    var userMessages: Int
    var assistantMessages: Int
    var tools: [String: Int]
    var events: [UsageEvent]
    var userTimes: [Date]
    /// Fallback model when a tool records no per-message usage (e.g. Copilot).
    var fallbackModel: String?
    /// A fragment (e.g. a Claude Code subagent run) that should be folded into the session with the same id.
    var isPartial = false

    // Derived, filled by `finalize()`
    private(set) var tokens = TokenUsage()
    private(set) var cost: Double = 0
    private(set) var models: [String: Int] = [:]   // model -> responses

    init(nativeID: String, editor: Editor, sourcePath: String, title: String, project: String,
         start: Date, end: Date, userMessages: Int = 0, assistantMessages: Int = 0,
         tools: [String: Int] = [:], events: [UsageEvent] = [], userTimes: [Date] = [],
         fallbackModel: String? = nil) {
        self.id = "\(editor.rawValue):\(nativeID)"
        self.nativeID = nativeID
        self.editor = editor
        self.sourcePath = sourcePath
        self.title = title
        self.project = project
        self.start = start
        self.end = end
        self.userMessages = userMessages
        self.assistantMessages = assistantMessages
        self.tools = tools
        self.events = events
        self.userTimes = userTimes
        self.fallbackModel = fallbackModel
        finalize()
    }

    mutating func finalize() {
        var t = TokenUsage(); var c = 0.0; var m: [String: Int] = [:]
        for e in events { t += e.tokens; c += e.cost; m[e.model, default: 0] += 1 }
        if m.isEmpty, let f = fallbackModel { m[f] = max(assistantMessages, 1) }
        tokens = t; cost = c; models = m
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = "Untitled session" }
    }

    /// Combines a session with a fragment of it (subagent runs). The non-partial side wins for
    /// identity fields; usage, tools and time span are summed.
    static func merged(_ a: SessionSummary, _ b: SessionSummary) -> SessionSummary {
        let pickB = a.isPartial && !b.isPartial
        var base = pickB ? b : a
        let other = pickB ? a : b
        base.start = min(base.start, other.start)
        base.end = max(base.end, other.end)
        base.userMessages += other.userMessages
        base.assistantMessages += other.assistantMessages
        base.userTimes = (base.userTimes + other.userTimes).sorted()
        base.events = (base.events + other.events).sorted { $0.timestamp < $1.timestamp }
        for (k, v) in other.tools { base.tools[k, default: 0] += v }
        if base.project.isEmpty { base.project = other.project }
        base.isPartial = a.isPartial && b.isPartial
        base.finalize()
        return base
    }

    var messageCount: Int { userMessages + assistantMessages }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var primaryModel: String { models.max { $0.value < $1.value }?.key ?? fallbackModel ?? "unknown" }
    var toolCalls: Int { tools.values.reduce(0, +) }
    var projectName: String { Self.projectName(project) }

    static func projectName(_ path: String) -> String {
        if path.isEmpty { return "Unknown" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home || path == "/" { return "~ (home)" }
        return (path as NSString).lastPathComponent
    }
}

enum TranscriptRole: String, Sendable { case user, assistant, tool, system }

struct TranscriptMessage: Identifiable, Sendable {
    let id = UUID()
    let role: TranscriptRole
    let text: String
    let timestamp: Date?
    var model: String? = nil
    var toolName: String? = nil
}

/// A file (or database) on disk that a source reads; mtime/size drive incremental reloads.
struct SourceFile: Hashable, Codable, Sendable {
    let path: String
    let mtime: Date
    let size: Int64
}
