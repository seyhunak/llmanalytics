import SwiftUI
import Charts

struct AnalysisView: View {
    @State private var store = DataStore.shared
    @State private var toolQuery = ""
    @State private var tokenView: TokenView = .byModel

    enum TokenView: String, CaseIterable { case byModel = "By model", byEditor = "By editor" }

    var body: some View {
        let a = store.analytics
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card("Tool frequency heatmap", subtitle: "Tool calls per editor",
                     trailing: AnyView(TextField("Filter tools", text: $toolQuery).textFieldStyle(.roundedBorder).frame(width: 180))) {
                    toolHeatmap(a)
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Model distribution", subtitle: "Responses per model") {
                        if a.byModel.isEmpty { EmptyState(title: "No models", message: "", symbol: "cpu") }
                        else {
                            Chart(a.byModel.prefix(12)) { m in
                                SectorMark(angle: .value("Responses", m.responses), innerRadius: .ratio(0.55), angularInset: 1)
                                    .foregroundStyle(by: .value("Model", Fmt.model(m.model)))
                            }
                            .frame(height: 220)
                        }
                    }
                    Card("Token breakdown", trailing: AnyView(
                        Picker("", selection: $tokenView) { ForEach(TokenView.allCases, id: \.self) { Text($0.rawValue) } }
                            .pickerStyle(.segmented).frame(width: 180))) {
                        tokenBreakdown(a).frame(height: 220)
                    }
                }
                Card("Model details") {
                    Table(a.byModel) {
                        TableColumn("Model") { (m: ModelStat) in Text(Fmt.model(m.model)) }
                        TableColumn("Editors") { (m: ModelStat) in
                            HStack(spacing: 3) { ForEach(Array(m.editors).sorted { $0.rawValue < $1.rawValue }) { EditorBadge(editor: $0, compact: true) } }
                        }
                        TableColumn("Responses") { (m: ModelStat) in Text("\(m.responses)").monospacedDigit() }
                        TableColumn("Input") { (m: ModelStat) in Text(Fmt.tokens(m.tokens.input)).monospacedDigit() }
                        TableColumn("Output") { (m: ModelStat) in Text(Fmt.tokens(m.tokens.output)).monospacedDigit() }
                        TableColumn("Cache read") { (m: ModelStat) in Text(Fmt.tokens(m.tokens.cacheRead)).monospacedDigit() }
                        TableColumn("Cache write") { (m: ModelStat) in Text(Fmt.tokens(m.tokens.cacheWrite)).monospacedDigit() }
                        TableColumn("Cost") { (m: ModelStat) in Text(Fmt.cost(m.cost)).monospacedDigit() }
                    }
                    .frame(minHeight: 220)
                }
                Card("Session size distribution", subtitle: "How many messages your sessions run to") {
                    let buckets = sizeBuckets(a.sessions)
                    Chart(buckets, id: \.0) { b in
                        BarMark(x: .value("Messages", b.0), y: .value("Sessions", b.1)).foregroundStyle(.indigo.gradient)
                    }
                    .frame(height: 160)
                }
            }
            .pagePadding()
        }
    }

    @ViewBuilder private func toolHeatmap(_ a: Analytics) -> some View {
        let editors = a.byEditor.map(\.editor)
        let tools = a.byTool.filter { toolQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(toolQuery) }.prefix(25)
        let mx = Double(tools.first?.count ?? 1)
        if tools.isEmpty || editors.isEmpty { EmptyState(title: "No tool calls", message: "", symbol: "wrench") }
        else {
            Grid(alignment: .leading, horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    ForEach(editors) { e in Image(systemName: e.symbol).foregroundStyle(e.color).frame(maxWidth: .infinity).help(e.displayName) }
                    Text("Total").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(Array(tools), id: \.name) { t in
                    GridRow {
                        Text(t.name).font(.caption).lineLimit(1).frame(width: 170, alignment: .leading)
                        ForEach(editors) { e in
                            let c = a.toolByEditor[t.name]?[e] ?? 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(c == 0 ? Color.secondary.opacity(0.08) : e.color.opacity(0.2 + 0.8 * sqrt(Double(c) / mx)))
                                .frame(height: 18).frame(maxWidth: .infinity)
                                .overlay(Text(c == 0 ? "" : Fmt.compact(Double(c))).font(.system(size: 9).monospacedDigit()))
                                .help("\(t.name) in \(e.displayName): \(c)")
                        }
                        Text(Fmt.compact(Double(t.count))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func tokenBreakdown(_ a: Analytics) -> some View {
        let rows: [(String, String, Int)] = tokenView == .byModel
            ? a.byModel.prefix(8).flatMap { m in kinds(m.tokens).map { (Fmt.model(m.model), $0.0, $0.1) } }
            : a.byEditor.flatMap { e in kinds(e.tokens).map { (e.editor.displayName, $0.0, $0.1) } }
        Chart(rows, id: \.0.hashValue) { r in
            BarMark(x: .value("Tokens", r.2), y: .value("Name", r.0))
                .foregroundStyle(by: .value("Kind", r.1))
        }
        .chartForegroundStyleScale(domain: ["Input", "Output", "Cache read", "Cache write"], range: [Color.blue, .green, .yellow, .orange])
        .chartXAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Int.self) { Text(Fmt.tokens(d)) } } } }
    }

    private func kinds(_ t: TokenUsage) -> [(String, Int)] {
        [("Input", t.input), ("Output", t.output), ("Cache read", t.cacheRead), ("Cache write", t.cacheWrite)]
    }

    private func sizeBuckets(_ s: [SessionSummary]) -> [(String, Int)] {
        let edges = [(1, 2, "1–2"), (3, 5, "3–5"), (6, 10, "6–10"), (11, 25, "11–25"), (26, 50, "26–50"), (51, 100, "51–100"), (101, Int.max, "100+")]
        return edges.map { lo, hi, label in (label, s.filter { $0.messageCount >= lo && $0.messageCount <= hi }.count) }
    }
}

// MARK: - Compare

struct CompareView: View {
    @State private var store = DataStore.shared

    var body: some View {
        let stats = store.analytics.byEditor
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if stats.isEmpty {
                    EmptyState(title: "Nothing to compare", message: "Use at least one supported editor in this date range.", symbol: "rectangle.split.2x1")
                } else {
                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(stats) { EditorColumn(stat: $0, best: best(stats)) }
                        }
                    }
                    Card("Sessions per day") {
                        Chart(store.analytics.daily) { p in
                            LineMark(x: .value("Day", p.date, unit: .day), y: .value("Sessions", p.sessions))
                                .foregroundStyle(by: .value("Editor", p.editor.displayName))
                                .interpolationMethod(.monotone)
                            PointMark(x: .value("Day", p.date, unit: .day), y: .value("Sessions", p.sessions))
                                .foregroundStyle(by: .value("Editor", p.editor.displayName)).symbolSize(14)
                        }
                        .chartForegroundStyleScale(domain: Editor.allCases.map(\.displayName), range: Editor.allCases.map(\.color))
                        .frame(height: 200)
                    }
                    Card("Efficiency", subtitle: "Output tokens per 1K input · cache hit rate · tokens per message") {
                        Chart {
                            ForEach(stats) { s in
                                BarMark(x: .value("Editor", s.editor.displayName), y: .value("Cache hit", s.cacheHitRate * 100))
                                    .foregroundStyle(s.editor.color.gradient)
                                    .annotation(position: .top) { Text(Fmt.percent(s.cacheHitRate)).font(.caption2) }
                            }
                        }
                        .chartYAxisLabel("Cache hit %")
                        .frame(height: 160)
                    }
                }
            }
            .pagePadding()
        }
    }

    private func best(_ s: [EditorStat]) -> [String: Editor] {
        var b: [String: Editor] = [:]
        if let x = s.max(by: { $0.cacheHitRate < $1.cacheHitRate }) { b["cache"] = x.editor }
        if let x = s.filter({ $0.cost > 0 }).min(by: { $0.avgCost < $1.avgCost }) { b["cost"] = x.editor }
        return b
    }
}

struct EditorColumn: View {
    let stat: EditorStat
    let best: [String: Editor]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: stat.editor.symbol).font(.title3).foregroundStyle(stat.editor.color)
                Text(stat.editor.displayName).font(.headline)
            }
            Divider()
            row("Sessions", "\(stat.sessions)")
            row("Active days", "\(stat.activeDays.count)")
            row("Messages", Fmt.compact(Double(stat.messages)))
            row("Avg msgs / session", Fmt.number(stat.avgMessages))
            row("Avg duration", "\(Fmt.number(stat.avgDurationMin, digits: 0)) min")
            row("Tokens", Fmt.tokens(stat.tokens.total))
            row("Avg tokens / session", Fmt.compact(stat.avgTokens))
            row("Tokens / message", Fmt.compact(stat.tokensPerMessage))
            row("Output : input", Fmt.number(stat.outputInputRatio * 1000, digits: 1) + " / 1K")
            row("Cache hit rate", Fmt.percent(stat.cacheHitRate), star: best["cache"] == stat.editor)
            row("Tool calls / session", Fmt.number(stat.toolsPerSession))
            row("Est. cost", Fmt.cost(stat.cost))
            row("Cost / session", Fmt.cost(stat.avgCost), star: best["cost"] == stat.editor)
            Divider()
            Text("Top models").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(stat.models.sorted { $0.value > $1.value }.prefix(3), id: \.key) { m in
                Text(Fmt.model(m.key)).font(.caption).lineLimit(1)
            }
        }
        .padding(16)
        .frame(width: 240, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(stat.editor.color.opacity(0.35)))
    }

    private func row(_ k: String, _ v: String, star: Bool = false) -> some View {
        HStack {
            Text(k).font(.callout).foregroundStyle(.secondary)
            Spacer()
            if star { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).help("Best in comparison") }
            Text(v).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}
