import SwiftUI

/// Subscription price vs what this month's usage would cost on the API.
struct PlanValueCard: View {
    @State private var store = DataStore.shared
    @State private var subs = SubscriptionService.shared

    var body: some View {
        let rows = PlanValue.rows(sessions: store.sessions, providers: subs.providers, manual: subs.manualPlans)
        Card("Plan value", subtitle: "This month: plan price vs the same usage at API list prices (projected to month end)") {
            if rows.isEmpty {
                Text("No paid plans detected. Add a manual plan on the Subscriptions page and link it to an editor to compare it with your API-equivalent usage.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow {
                        Text("Plan"); Text("Price").gridColumnAlignment(.trailing); Text("API so far").gridColumnAlignment(.trailing)
                        Text("Projected").gridColumnAlignment(.trailing); Text("Value")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(rows) { r in
                        GridRow {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    ForEach(r.editors) { Image(systemName: $0.symbol).foregroundStyle($0.color).font(.caption) }
                                    Text(r.name).font(.callout.weight(.medium))
                                }
                                Text(r.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(Fmt.cost(r.monthlyPrice)).monospacedDigit()
                            Text(Fmt.cost(r.apiSpendToDate)).monospacedDigit()
                            Text(Fmt.cost(r.projected)).monospacedDigit()
                            verdict(r)
                        }
                    }
                }
                Text("Above 1× the plan is cheaper than paying per token; below 1× you'd spend less on the API.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func verdict(_ r: PlanValueRow) -> some View {
        if r.editors.isEmpty {
            Text("—").foregroundStyle(.secondary)
        } else {
            let good = r.multiple >= 1
            HStack(spacing: 6) {
                Text(String(format: "%.1f×", r.multiple)).font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(good ? .green : .orange)
                Text(good ? "pays for itself" : "API would be \(Fmt.cost(r.monthlyPrice - r.projected)) cheaper")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Re-price the filtered usage as if it had all run on another model.
struct WhatIfCard: View {
    let sessions: [SessionSummary]
    @AppStorage("whatIfTarget") private var target = "claude-sonnet-5-5"

    var body: some View {
        let rows = WhatIf.reprice(sessions, on: target)
        let actual = rows.reduce(0) { $0 + $1.actual }
        let repriced = rows.reduce(0) { $0 + $1.repriced }
        Card("What if", subtitle: "Your token usage in this range, priced on another model",
             trailing: AnyView(Picker("", selection: $target) {
                 ForEach(WhatIf.targets, id: \.self) { Text(Fmt.model($0)).tag($0) }
             }.frame(width: 200))) {
            if rows.isEmpty { EmptyState(title: "No token usage", message: "Nothing to re-price in this range.", symbol: "arrow.left.arrow.right") }
            else {
                HStack(spacing: 24) {
                    figure("Actual", Fmt.cost(actual), .primary)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    figure("On \(Fmt.model(target))", Fmt.cost(repriced), .primary)
                    let d = repriced - actual
                    figure(d <= 0 ? "You'd save" : "You'd pay more", Fmt.cost(abs(d)) + (actual > 0 ? "  (\(Fmt.percent(abs(d) / actual)))" : ""),
                           d <= 0 ? .green : .orange)
                }
                Divider()
                ForEach(rows.prefix(8)) { r in
                    HStack {
                        Text(Fmt.model(r.model)).font(.callout).lineLimit(1)
                        Spacer()
                        Text(Fmt.tokens(r.tokens)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                        Text(Fmt.cost(r.actual)).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
                        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                        Text(Fmt.cost(r.repriced)).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
                            .foregroundStyle(r.delta < 0 ? .green : r.delta > 0 ? .orange : .primary)
                    }
                }
                Text("Assumes the same token counts; a different model would use more or fewer. Reported costs (OpenCode) are compared as recorded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func figure(_ t: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(c)
        }
    }
}

/// Expensive Opus sessions whose shape suggests a cheaper model would have done.
struct OverpoweredCard: View {
    let sessions: [SessionSummary]
    @State private var nav = Navigation.shared

    var body: some View {
        let list = WhatIf.overpowered(sessions)
        if !list.isEmpty {
            let total = list.reduce(0) { $0 + $1.savings }
            Card("Sessions that may not have needed Opus",
                 subtitle: "\(list.count) light sessions over $1 · \(Fmt.cost(total)) less on Sonnet 5.5") {
                VStack(spacing: 0) {
                    ForEach(list.prefix(8)) { c in
                        Button { nav.inspectedSessionID = c.session.id } label: {
                            HStack(spacing: 10) {
                                EditorBadge(editor: c.session.editor, compact: true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.session.title).font(.callout).lineLimit(1)
                                    Text(c.reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(Fmt.cost(c.session.cost)).font(.callout.monospacedDigit())
                                    Text("−\(Fmt.cost(c.savings)) on Sonnet").font(.caption.monospacedDigit()).foregroundStyle(.green)
                                }
                            }
                            .padding(.vertical, 7).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if c.id != list.prefix(8).last?.id { Divider() }
                    }
                }
                Text("Heuristic: little output and few tool calls per prompt. It can't tell whether a task needed the stronger model.")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
    }
}
