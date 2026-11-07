import SwiftUI
import AppKit

struct SessionsView: View {
    @State private var store = DataStore.shared
    @State private var nav = Navigation.shared
    @State private var sort = [KeyPathComparator(\SessionSummary.end, order: .reverse)]
    @State private var selection: SessionSummary.ID?
    @State private var modelFilter: String = ""

    var body: some View {
        let rows = filtered.sorted(using: sort)
        VStack(spacing: 0) {
            HStack {
                Text("\(rows.count) sessions").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("Model", selection: $modelFilter) {
                    Text("All models").tag("")
                    ForEach(store.analytics.byModel.prefix(30)) { Text(Fmt.model($0.model)).tag($0.model) }
                }
                .frame(width: 220)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Table(rows, selection: $selection, sortOrder: $sort) {
                TableColumn("Session", value: \.title) { s in
                    HStack(spacing: 8) {
                        EditorBadge(editor: s.editor, compact: true)
                        Text(s.title).lineLimit(1)
                    }
                }
                .width(min: 220, ideal: 360)
                TableColumn("Project", value: \.project) { s in Text(s.projectName).lineLimit(1).help(s.project) }
                    .width(min: 80, ideal: 130)
                TableColumn("Model", value: \.fallbackModelSortKey) { s in Text(Fmt.model(s.primaryModel)).lineLimit(1) }
                    .width(min: 80, ideal: 130)
                TableColumn("Msgs", value: \.messageCount) { s in Text("\(s.messageCount)").monospacedDigit() }
                    .width(50)
                TableColumn("Tokens", value: \.tokenTotal) { s in Text(Fmt.tokens(s.tokens.total)).monospacedDigit() }
                    .width(64)
                TableColumn("Cost", value: \.cost) { s in Text(Fmt.cost(s.cost)).monospacedDigit() }
                    .width(64)
                TableColumn("Last active", value: \.end) { s in Text(s.end.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 140)
            }
            .onChange(of: selection) { _, id in if let id { nav.inspectedSessionID = id } }
            .contextMenu(forSelectionType: SessionSummary.ID.self) { ids in
                if let id = ids.first, let s = store.session(id: id) {
                    Button("Open transcript") { nav.inspectedSessionID = id }
                    Button("Reveal source file in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.sourcePath)]) }
                    if !s.project.isEmpty, FS.exists(s.project) {
                        Button("Open project folder") { NSWorkspace.shared.open(URL(fileURLWithPath: s.project)) }
                    }
                    Button("Copy session ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s.nativeID, forType: .string) }
                }
            } primaryAction: { ids in nav.inspectedSessionID = ids.first }
        }
        .searchable(text: $nav.sessionSearch, placement: .toolbar, prompt: "Search title, project, model")
    }

    private var filtered: [SessionSummary] {
        let q = nav.sessionSearch.lowercased().trimmingCharacters(in: .whitespaces)
        return store.analytics.sessions.filter { s in
            (modelFilter.isEmpty || s.models[modelFilter] != nil) &&
            (q.isEmpty || s.title.lowercased().contains(q) || s.project.lowercased().contains(q)
             || s.primaryModel.lowercased().contains(q) || s.editor.displayName.lowercased().contains(q)
             || s.nativeID.lowercased().contains(q))
        }
    }
}

extension SessionSummary {
    var tokenTotal: Int { tokens.total }
    var fallbackModelSortKey: String { primaryModel }
}

// MARK: - Transcript

struct TranscriptView: View {
    let session: SessionSummary
    @State private var messages: [TranscriptMessage]?
    @State private var showTools = true
    @State private var showThinking = false
    @State private var search = ""
    @State private var nav = Navigation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let messages {
                let shown = messages.filter { m in
                    (showTools || m.role != .tool) && (showThinking || m.role != .system)
                        && (search.isEmpty || m.text.localizedCaseInsensitiveContains(search))
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(shown) { MessageBubble(message: $0) }
                        if shown.isEmpty { EmptyState(title: "Nothing to show", message: "This session has no readable messages.", symbol: "text.bubble") }
                    }
                    .padding(16)
                }
            } else {
                ProgressView("Loading conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: session.id) {
            messages = nil
            messages = await DataStore.shared.transcript(for: session)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                EditorBadge(editor: session.editor)
                Spacer()
                Button { nav.inspectedSessionID = nil } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
            }
            Text(session.title).font(.title3.weight(.semibold)).lineLimit(3).textSelection(.enabled)
            Text(session.project.isEmpty ? "No project" : session.project).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            HStack(spacing: 14) {
                metric("Messages", "\(session.messageCount)")
                metric("Tokens", Fmt.tokens(session.tokens.total))
                metric("Cost", Fmt.cost(session.cost))
                metric("Tools", "\(session.toolCalls)")
                metric("Duration", Fmt.duration(session.duration))
            }
            HStack {
                Text(session.models.keys.sorted().map(Fmt.model).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            HStack {
                TextField("Find in conversation", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Tools", isOn: $showTools).toggleStyle(.checkbox)
                Toggle("Thinking", isOn: $showThinking).toggleStyle(.checkbox)
            }
            .font(.caption)
        }
        .padding(16)
    }

    private func metric(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }
}

struct MessageBubble: View {
    let message: TranscriptMessage
    @State private var expanded = false
    private let limit = 6000

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(label).font(.caption.weight(.semibold)).foregroundStyle(tint)
                if let m = message.model, message.role == .assistant { Text(Fmt.model(m)).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
                if let t = message.timestamp { Text(t.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary) }
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) } label: {
                    Image(systemName: "doc.on.doc")
                }.buttonStyle(.plain).foregroundStyle(.tertiary).help("Copy")
            }
            let text = expanded || message.text.count <= limit ? message.text : String(message.text.prefix(limit))
            if message.role == .tool && !expanded && message.text.count > 600 {
                RichText(text: String(message.text.prefix(600)) + (message.text.hasPrefix("```") ? "\n```" : ""))
                Button("Show full output (\(message.text.count) chars)") { expanded = true }.buttonStyle(.link).font(.caption)
            } else {
                RichText(text: text)
                if !expanded && message.text.count > limit {
                    Button("Show more (\(message.text.count - limit) more chars)") { expanded = true }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(background))
        .opacity(message.role == .system ? 0.8 : 1)
    }

    private var label: String {
        switch message.role {
        case .user: "You"
        case .assistant: "Assistant"
        case .tool: message.toolName ?? "Tool"
        case .system: (message.toolName ?? "thinking").capitalized
        }
    }
    private var icon: String {
        switch message.role { case .user: "person.fill"; case .assistant: "sparkles"; case .tool: "wrench.and.screwdriver"; case .system: "brain" }
    }
    private var tint: Color {
        switch message.role { case .user: .blue; case .assistant: .purple; case .tool: .teal; case .system: .gray }
    }
    private var background: Color {
        switch message.role {
        case .user: .blue.opacity(0.08)
        case .assistant: Color.secondary.opacity(0.07)
        case .tool: .teal.opacity(0.06)
        case .system: Color.secondary.opacity(0.05)
        }
    }
}

/// Markdown-ish text: fenced code blocks get syntax highlighting, prose gets inline markdown.
struct RichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(text).enumerated()), id: \.offset) { _, seg in
                switch seg {
                case .prose(let s):
                    Text(Self.markdown(s)).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                case .code(let lang, let code):
                    CodeBlock(language: lang, code: code)
                }
            }
        }
    }

    enum Segment { case prose(String), code(String, String) }

    static func segments(_ text: String) -> [Segment] {
        var out: [Segment] = []
        var prose: [Substring] = [], code: [Substring] = []
        var inCode = false, lang = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode {
                    out.append(.code(lang, code.joined(separator: "\n"))); code = []; inCode = false
                } else {
                    if !prose.isEmpty { out.append(.prose(prose.joined(separator: "\n"))); prose = [] }
                    lang = line.trimmingCharacters(in: .whitespaces).dropFirst(3).trimmingCharacters(in: .whitespaces)
                    inCode = true
                }
            } else if inCode { code.append(line) } else { prose.append(line) }
        }
        if inCode { out.append(.code(lang, code.joined(separator: "\n"))) }
        let rest = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { out.append(.prose(rest)) }
        return out
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(s)
    }
}

struct CodeBlock: View {
    let language: String
    let code: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.caption2)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08))
            ScrollView(.horizontal) {
                Text(SyntaxHighlighter.highlight(code, language: language))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Small regex highlighter covering the languages that show up in coding chats.
enum SyntaxHighlighter {
    private static let keywords: Set<String> = [
        "func", "let", "var", "if", "else", "for", "while", "return", "import", "struct", "class", "enum", "case",
        "switch", "guard", "in", "self", "true", "false", "nil", "null", "none", "None", "True", "False", "def",
        "from", "as", "const", "function", "async", "await", "export", "default", "new", "try", "catch", "throw",
        "throws", "public", "private", "static", "interface", "type", "extends", "implements", "package", "fn",
        "pub", "impl", "mut", "use", "mod", "match", "where", "protocol", "extension", "do", "then", "fi", "echo",
        "elif", "with", "yield", "lambda", "and", "or", "not", "is", "undefined", "this", "super", "init", "void",
        "int", "string", "bool", "go", "defer", "chan", "select", "break", "continue", "SELECT", "FROM", "WHERE",
    ]
    nonisolated(unsafe) private static let rules: [(NSRegularExpression, Color)] = [
        (try! NSRegularExpression(pattern: #"\b\d+(\.\d+)?\b"#), .orange),
        (try! NSRegularExpression(pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#), .teal),
        (try! NSRegularExpression(pattern: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#), .red),
        (try! NSRegularExpression(pattern: #"(//|#(?!!)|--)[^\n]*"#), .gray),
        (try! NSRegularExpression(pattern: #"/\*[\s\S]*?\*/"#), .gray),
    ]
    nonisolated(unsafe) private static let word = try! NSRegularExpression(pattern: #"\b[A-Za-z_]+\b"#)

    static func highlight(_ code: String, language: String) -> AttributedString {
        let capped = code.count > 20_000 ? String(code.prefix(20_000)) + "\n…" : code
        let ns = capped as NSString
        let full = NSRange(location: 0, length: ns.length)
        let attr = NSMutableAttributedString(string: capped)
        let lang = language.lowercased()
        if ["", "text", "txt", "log", "output"].contains(lang) && !capped.contains("{") { return AttributedString(capped) }
        for m in word.matches(in: capped, range: full) where keywords.contains(ns.substring(with: m.range)) {
            attr.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: m.range)
        }
        for (re, color) in rules {
            if lang == "json" && color == .teal { continue }
            for m in re.matches(in: capped, range: full) {
                attr.addAttribute(.foregroundColor, value: NSColor(color), range: m.range)
            }
        }
        return (try? AttributedString(attr, including: \.appKit)) ?? AttributedString(capped)
    }
}
