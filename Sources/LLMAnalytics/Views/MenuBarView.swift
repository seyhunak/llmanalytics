import SwiftUI
import Charts

/// The tray popover: today's live numbers, sessions running right now, quotas.
struct MenuBarView: View {
    @State private var store = DataStore.shared
    @State private var subs = SubscriptionService.shared
    @AppStorage("budget.day") private var dayBudget = 0.0
    @AppStorage("budget.week") private var weekBudget = 0.0
    @AppStorage("budget.month") private var monthBudget = 0.0
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let l = store.live
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Today").font(.headline)
                Spacer()
                if store.isLoading { ProgressView().controlSize(.mini) }
                else {
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("Live").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            HStack(spacing: 8) {
                tile("Cost", Fmt.cost(l.todayCost))
                tile("Tokens", Fmt.tokens(l.todayTokens.total))
                tile("Prompts", "\(l.todayMessages)")
                tile("Sessions", "\(l.todaySessions)")
            }
            HStack {
                Text("Last hour \(Fmt.cost(l.burnRatePerHour))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("This month \(Fmt.cost(l.monthCost))").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(l.budgets([.day: dayBudget, .week: weekBudget, .month: monthBudget].filter { $0.value > 0 })) { b in
                let tint: Color = b.fraction >= 1 ? .red : b.fraction >= 0.8 ? .orange : .green
                HStack(spacing: 8) {
                    Text(b.period.title).font(.caption).frame(width: 52, alignment: .leading)
                    ProgressView(value: min(b.fraction, 1)).tint(tint).controlSize(.small)
                    Text("\(Fmt.cost(b.spent)) / \(Fmt.cost(b.limit))").font(.caption2.monospacedDigit())
                        .foregroundStyle(b.fraction >= 0.8 ? tint : .secondary).frame(width: 96, alignment: .trailing)
                }
            }
            Chart(l.last7Days, id: \.date) { d in
                BarMark(x: .value("Day", d.date, unit: .day), y: .value("Cost", d.cost))
                    .foregroundStyle(Calendar.current.isDateInToday(d.date) ? Color.accentColor.gradient : Color.secondary.opacity(0.5).gradient)
                    .cornerRadius(2)
            }
            .chartYAxis(.hidden)
            .chartXAxis { AxisMarks(values: .stride(by: .day)) { _ in AxisValueLabel(format: .dateTime.weekday(.narrow)) } }
            .frame(height: 54)

            if !l.todayByEditor.isEmpty {
                VStack(spacing: 4) {
                    ForEach(l.todayByEditor, id: \.editor) { e in
                        HStack {
                            Image(systemName: e.editor.symbol).foregroundStyle(e.editor.color).frame(width: 14)
                            Text(e.editor.displayName).font(.caption)
                            Spacer()
                            Text(Fmt.tokens(e.tokens)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(Fmt.cost(e.cost)).font(.caption.monospacedDigit()).frame(width: 52, alignment: .trailing)
                        }
                    }
                }
            }

            Divider()
            Text("Active now").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if l.activeSessions.isEmpty {
                Text("No sessions in the last 15 minutes").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(l.activeSessions.prefix(4)) { s in
                    Button { open(session: s) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Date().timeIntervalSince(s.end) < 120 ? Color.green : .orange).frame(width: 6, height: 6)
                            Image(systemName: s.editor.symbol).foregroundStyle(s.editor.color).font(.caption)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.title).font(.caption).lineLimit(1)
                                Text("\(s.projectName) · \(Fmt.model(s.primaryModel))").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(Fmt.tokens(s.tokens.total)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            let quotas = subs.providers.filter { !$0.windows.isEmpty }
            if !quotas.isEmpty {
                Divider()
                Text("Limits").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(quotas) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.provider + (p.plan.map { " · \($0)" } ?? "")).font(.caption.weight(.medium))
                        ForEach(p.windows.prefix(2)) { QuotaBar(window: $0, compact: true) }
                    }
                }
            }

            Divider()
            HStack {
                Button { openMain() } label: { Label("Open Dashboard", systemImage: "macwindow") }
                Spacer()
                Button { Task { await store.refresh(); await subs.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                SettingsLink { Image(systemName: "gearshape") }.help("Settings")
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("Quit")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 330)
    }

    private func tile(_ t: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    private func openMain() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private func open(session: SessionSummary) {
        Navigation.shared.page = .sessions
        Navigation.shared.inspectedSessionID = session.id
        openMain()
    }
}

/// Text in the menu bar next to the icon.
struct MenuBarLabel: View {
    @State private var store = DataStore.shared
    @AppStorage("menuBarMetric") private var metric = "cost"

    var body: some View {
        let l = store.live
        HStack(spacing: 3) {
            Image(systemName: l.activeSessions.contains { Date().timeIntervalSince($0.end) < 120 } ? "chart.bar.fill" : "chart.bar")
            switch metric {
            case "cost": Text(Fmt.cost(l.todayCost))
            case "tokens": Text(Fmt.tokens(l.todayTokens.total))
            default: EmptyView()
            }
        }
    }
}
