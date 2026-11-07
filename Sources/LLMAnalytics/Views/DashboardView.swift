import SwiftUI
import Charts

struct DashboardView: View {
    @State private var store = DataStore.shared
    @State private var nav = Navigation.shared
    @State private var metric: DailyMetric = .tokens

    enum DailyMetric: String, CaseIterable { case tokens = "Tokens", cost = "Cost", messages = "Prompts" }

    var body: some View {
        let a = store.analytics
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if store.sessions.isEmpty && !store.isLoading {
                    EmptyState(title: "No AI coding history found",
                               message: "Use Claude Code, Codex, Cursor, Copilot, Gemini CLI or OpenCode and sessions show up here automatically.",
                               symbol: "sparkles")
                }
                kpis(a)
                Card("Activity", subtitle: "Prompts per day over the last year") {
                    ActivityHeatmap(counts: a.heatmap)
                    HStack(spacing: 24) {
                        stat("Current streak", "\(a.currentStreak) days")
                        stat("Longest streak", "\(a.longestStreak) days")
                        if let m = a.mostActiveDay { stat("Busiest day", "\(m.date.formatted(date: .abbreviated, time: .omitted)) · \(m.count)") }
                        if let p = a.peakHour { stat("Peak hour", Fmt.hour(p)) }
                    }
                }
                Card("Daily usage", trailing: AnyView(
                    Picker("", selection: $metric) { ForEach(DailyMetric.allCases, id: \.self) { Text($0.rawValue) } }
                        .pickerStyle(.segmented).frame(width: 220))) {
                    dailyChart(a).frame(height: 200)
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Editor breakdown", subtitle: "Share of sessions") { editorDonut(a) }
                    Card("Token economy", subtitle: "Where your tokens go") { tokenEconomy(a) }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Peak hours", subtitle: "When you prompt, by weekday") { HourHeatmap(cells: a.hours) }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("Top models") {
                        BarList(rows: a.byModel.map {
                            .init(label: Fmt.model($0.model), value: Double($0.responses), display: Fmt.compact(Double($0.responses)),
                                  color: $0.editors.first?.color ?? .accentColor)
                        })
                    }
                    Card("Top tools") {
                        BarList(rows: a.byTool.map { .init(label: $0.name, value: Double($0.count), display: Fmt.compact(Double($0.count)), color: .teal) })
                    }
                }
                Card("Recent sessions", trailing: AnyView(Button("View all") { nav.page = .sessions }.buttonStyle(.link))) {
                    SessionRows(sessions: Array(a.sessions.prefix(6)))
                }
            }
            .pagePadding()
        }
    }

    private func stat(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private func kpis(_ a: Analytics) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            KPITile(title: "Sessions", value: "\(a.sessions.count)", detail: "avg \(Fmt.number(a.avgSessionMinutes, digits: 0)) min", symbol: "bubble.left.and.bubble.right", tint: .blue)
            KPITile(title: "Messages", value: Fmt.compact(Double(a.messages)), detail: "\(Fmt.compact(Double(a.userMessages))) prompts", symbol: "text.bubble", tint: .purple)
            KPITile(title: "Tokens", value: Fmt.tokens(a.totalTokens.total), detail: "\(Fmt.tokens(a.totalTokens.output)) output", symbol: "number", tint: .orange)
            KPITile(title: "Est. cost", value: Fmt.cost(a.totalCost), detail: "at API list prices", symbol: "dollarsign.circle", tint: .green)
            KPITile(title: "Active days", value: "\(a.activeDays)", detail: store.filter.range.rawValue, symbol: "calendar", tint: .pink)
            KPITile(title: "Streak", value: "\(a.currentStreak)d", detail: "longest \(a.longestStreak)d", symbol: "flame", tint: .red)
            KPITile(title: "Tool calls", value: Fmt.compact(Double(a.toolCalls)), detail: "\(a.byTool.count) distinct tools", symbol: "wrench.and.screwdriver", tint: .teal)
            KPITile(title: "Cache hit rate", value: Fmt.percent(a.cacheHitRate), detail: "of input tokens", symbol: "bolt", tint: .yellow)
        }
    }

    @ViewBuilder private func dailyChart(_ a: Analytics) -> some View {
        if a.daily.isEmpty { EmptyState(title: "No activity", message: "Nothing in this range.", symbol: "chart.bar") }
        else {
            Chart(a.daily) { p in
                BarMark(x: .value("Day", p.date, unit: .day),
                        y: .value(metric.rawValue, metric == .tokens ? Double(p.tokens) : metric == .cost ? p.cost : Double(p.messages)))
                    .foregroundStyle(by: .value("Editor", p.editor.displayName))
            }
            .chartForegroundStyleScale(domain: Editor.allCases.map(\.displayName), range: Editor.allCases.map(\.color))
            .chartYAxis { AxisMarks { v in
                AxisGridLine(); AxisValueLabel {
                    if let d = v.as(Double.self) { Text(metric == .cost ? Fmt.cost(d) : Fmt.compact(d)) }
                }
            } }
        }
    }

    @ViewBuilder private func editorDonut(_ a: Analytics) -> some View {
        if a.byEditor.isEmpty { EmptyState(title: "No editors", message: "", symbol: "app.dashed") }
        else {
            HStack(spacing: 20) {
                Chart(a.byEditor) { e in
                    SectorMark(angle: .value("Sessions", e.sessions), innerRadius: .ratio(0.62), angularInset: 1.5)
                        .foregroundStyle(e.editor.color).cornerRadius(3)
                }
                .frame(width: 140, height: 140)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(a.byEditor) { e in
                        HStack {
                            Circle().fill(e.editor.color).frame(width: 8, height: 8)
                            Text(e.editor.displayName).font(.callout)
                            Spacer()
                            Text("\(e.sessions)").font(.callout.monospacedDigit())
                            Text(Fmt.tokens(e.tokens.total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    private func tokenEconomy(_ a: Analytics) -> some View {
        let t = a.totalTokens
        let parts: [(String, Int, Color)] = [("Cache read", t.cacheRead, .yellow), ("Cache write", t.cacheWrite, .orange),
                                             ("Input", t.input, .blue), ("Output", t.output, .green)]
        let total = max(t.total, 1)
        return VStack(alignment: .leading, spacing: 12) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2.gradient).frame(width: max(0, g.size.width * Double(p.1) / Double(total) - 2))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .frame(height: 14)
            ForEach(parts, id: \.0) { p in
                HStack {
                    Circle().fill(p.2).frame(width: 8, height: 8)
                    Text(p.0).font(.callout)
                    Spacer()
                    Text(Fmt.tokens(p.1)).font(.callout.monospacedDigit())
                    Text(Fmt.percent(Double(p.1) / Double(total))).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                }
            }
            Divider()
            HStack {
                Text("Output per 1K input").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(t.allInput > 0 ? Fmt.number(Double(t.output) / Double(t.allInput) * 1000, digits: 1) : "—").font(.caption.monospacedDigit())
            }
            HStack {
                Text("Reasoning tokens").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.tokens(t.reasoning)).font(.caption.monospacedDigit())
            }
        }
    }
}

/// Compact clickable list used on several pages.
struct SessionRows: View {
    let sessions: [SessionSummary]
    @State private var nav = Navigation.shared
    var body: some View {
        VStack(spacing: 0) {
            ForEach(sessions) { s in
                Button { nav.inspectedSessionID = s.id } label: {
                    HStack(spacing: 10) {
                        EditorBadge(editor: s.editor, compact: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.title).lineLimit(1).font(.callout)
                            Text("\(s.projectName) · \(Fmt.model(s.primaryModel))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Fmt.cost(s.cost)).font(.callout.monospacedDigit())
                            Text(Fmt.relative(s.end)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 7).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if s.id != sessions.last?.id { Divider() }
            }
            if sessions.isEmpty { Text("No sessions").foregroundStyle(.secondary).font(.callout) }
        }
    }
}
