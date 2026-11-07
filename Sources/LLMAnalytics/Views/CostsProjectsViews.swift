import SwiftUI
import Charts

struct CostsView: View {
    @State private var store = DataStore.shared
    @State private var subs = SubscriptionService.shared

    var body: some View {
        let a = store.analytics
        let days = max(1, Double(a.daily.map(\.date).uniqueCount))
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    KPITile(title: "Estimated spend", value: Fmt.cost(a.totalCost), detail: store.filter.range.rawValue, symbol: "dollarsign.circle", tint: .green)
                    KPITile(title: "Per active day", value: Fmt.cost(a.totalCost / days), detail: "\(Int(days)) days with usage", symbol: "calendar", tint: .blue)
                    KPITile(title: "Per session", value: Fmt.cost(a.sessions.isEmpty ? 0 : a.totalCost / Double(a.sessions.count)), detail: "\(a.sessions.count) sessions", symbol: "bubble.left", tint: .purple)
                    KPITile(title: "Subscriptions", value: Fmt.cost(subs.monthlySubscriptionTotal), detail: "per month (manual plans)", symbol: "creditcard", tint: .orange)
                }
                Text("Costs are estimated from token counts at public API list prices. Subscription plans (Claude Max, ChatGPT, Copilot) are flat-rate, so this shows what the same usage would cost on the API. OpenCode costs are taken from OpenCode's own records.")
                    .font(.caption).foregroundStyle(.secondary)

                Card("Spend by month") {
                    if a.byMonth.isEmpty { EmptyState(title: "No spend", message: "No token usage in this range.", symbol: "chart.bar") }
                    else {
                        Chart(a.byMonth) { m in
                            BarMark(x: .value("Month", m.month, unit: .month), y: .value("Cost", m.cost))
                                .foregroundStyle(by: .value("Editor", m.editor.displayName))
                        }
                        .chartForegroundStyleScale(domain: Editor.allCases.map(\.displayName), range: Editor.allCases.map(\.color))
                        .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.cost(d)) } } } }
                        .frame(height: 200)
                    }
                }
                Card("Daily spend") {
                    Chart(a.daily) { p in
                        AreaMark(x: .value("Day", p.date, unit: .day), y: .value("Cost", p.cost))
                            .foregroundStyle(by: .value("Editor", p.editor.displayName))
                    }
                    .chartForegroundStyleScale(domain: Editor.allCases.map(\.displayName), range: Editor.allCases.map(\.color))
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.cost(d)) } } } }
                    .frame(height: 160)
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("By model") {
                        BarList(rows: a.byModel.filter { $0.cost > 0 }.map {
                            .init(label: Fmt.model($0.model), value: $0.cost, display: Fmt.cost($0.cost), color: $0.editors.first?.color ?? .green)
                        }, limit: 10)
                    }
                    Card("By editor") {
                        BarList(rows: a.byEditor.map { .init(label: $0.editor.displayName, value: $0.cost, display: Fmt.cost($0.cost), color: $0.editor.color, badge: $0.editor) })
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    Card("By project") {
                        BarList(rows: a.byProject.sorted { $0.cost > $1.cost }.map { .init(label: $0.name, value: $0.cost, display: Fmt.cost($0.cost), color: .indigo) }, limit: 10)
                    }
                    Card("Model price table", subtitle: "USD per 1M tokens — override in pricing.json") {
                        PriceTable(models: a.byModel.map(\.model))
                    }
                }
                Card("Most expensive sessions") {
                    SessionRows(sessions: Array(a.sessions.sorted { $0.cost > $1.cost }.prefix(10)))
                }
            }
            .pagePadding()
        }
    }
}

struct PriceTable: View {
    let models: [String]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                Text("Model"); Text("Input"); Text("Output"); Text("Cache R"); Text("Cache W")
            }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(models.prefix(10), id: \.self) { m in
                GridRow {
                    Text(Fmt.model(m)).lineLimit(1)
                    if let p = Pricing.price(for: m) {
                        Text(String(format: "$%.2f", p.input)); Text(String(format: "$%.2f", p.output))
                        Text(String(format: "$%.2f", p.cacheRead)); Text(String(format: "$%.2f", p.cacheWrite))
                    } else {
                        Text("unpriced").foregroundStyle(.tertiary).gridCellColumns(4)
                    }
                }.font(.caption.monospacedDigit())
            }
        }
    }
}

extension Array where Element: Hashable {
    var uniqueCount: Int { Set(self).count }
}

// MARK: - Projects

struct ProjectsView: View {
    @State private var store = DataStore.shared
    @State private var nav = Navigation.shared
    @State private var sort = [KeyPathComparator(\ProjectStat.lastActive, order: .reverse)]

    var body: some View {
        let projects = store.analytics.byProject.sorted(using: sort)
        HSplitView {
            Table(projects, selection: Binding(get: { nav.selectedProject }, set: { nav.selectedProject = $0 }), sortOrder: $sort) {
                TableColumn("Project", value: \.name) { p in
                    HStack {
                        Image(systemName: "folder.fill").foregroundStyle(.secondary)
                        Text(p.name).lineLimit(1).help(p.path)
                    }
                }.width(min: 140, ideal: 200)
                TableColumn("Editors") { (p: ProjectStat) in
                    HStack(spacing: 3) { ForEach(p.editors.keys.sorted { $0.rawValue < $1.rawValue }) { EditorBadge(editor: $0, compact: true) } }
                }.width(min: 60, ideal: 90)
                TableColumn("Sessions", value: \.sessions) { Text("\($0.sessions)").monospacedDigit() }.width(60)
                TableColumn("Messages", value: \.messages) { Text("\($0.messages)").monospacedDigit() }.width(70)
                TableColumn("Tokens", value: \.tokenTotal) { Text(Fmt.tokens($0.tokens.total)).monospacedDigit() }.width(64)
                TableColumn("Cost", value: \.cost) { Text(Fmt.cost($0.cost)).monospacedDigit() }.width(64)
                TableColumn("Last active", value: \.lastActive) { Text(Fmt.relative($0.lastActive)).foregroundStyle(.secondary) }.width(min: 90, ideal: 110)
            }
            .frame(minWidth: 520)
            Group {
                if let id = nav.selectedProject, let p = projects.first(where: { $0.id == id }) {
                    ProjectDetail(project: p)
                } else {
                    EmptyState(title: "Select a project", message: "Pick a project to drill into its sessions, models and tools.", symbol: "folder")
                }
            }
            .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension ProjectStat { var tokenTotal: Int { tokens.total } }

struct ProjectDetail: View {
    let project: ProjectStat
    @State private var store = DataStore.shared

    var body: some View {
        let sessions = store.analytics.sessions.filter { $0.project == project.path }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name).font(.title2.weight(.semibold))
                    Text(project.path.isEmpty ? "No working directory recorded" : project.path)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("Active \(project.firstActive.formatted(date: .abbreviated, time: .omitted)) – \(project.lastActive.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                    KPITile(title: "Sessions", value: "\(project.sessions)", symbol: "bubble.left", tint: .blue)
                    KPITile(title: "Est. cost", value: Fmt.cost(project.cost), symbol: "dollarsign.circle", tint: .green)
                    KPITile(title: "Tokens", value: Fmt.tokens(project.tokens.total), symbol: "number", tint: .orange)
                    KPITile(title: "Tool calls", value: Fmt.compact(Double(project.toolCalls)), symbol: "wrench", tint: .teal)
                }
                Card("Editors") {
                    BarList(rows: project.editors.sorted { $0.value > $1.value }.map { .init(label: $0.key.displayName, value: Double($0.value), display: "\($0.value)", color: $0.key.color, badge: $0.key) })
                }
                Card("Models") {
                    BarList(rows: project.models.sorted { $0.value > $1.value }.map { .init(label: Fmt.model($0.key), value: Double($0.value), display: "\($0.value)", color: .purple) })
                }
                Card("Tools") {
                    BarList(rows: project.tools.sorted { $0.value > $1.value }.map { .init(label: $0.key, value: Double($0.value), display: "\($0.value)", color: .teal) })
                }
                Card("Sessions") { SessionRows(sessions: Array(sessions.prefix(30))) }
            }
            .padding(16)
        }
    }
}
