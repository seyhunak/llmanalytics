import SwiftUI
import Charts

enum Fmt {
    static func tokens(_ n: Int) -> String { compact(Double(n)) }
    static func compact(_ v: Double) -> String {
        let a = abs(v)
        switch a {
        case 1_000_000_000...: return String(format: "%.2fB", v / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", v / 1_000_000)
        case 10_000...: return String(format: "%.0fK", v / 1_000)
        case 1_000...: return String(format: "%.1fK", v / 1_000)
        default: return String(format: "%.0f", v)
        }
    }
    static func cost(_ v: Double) -> String {
        if v == 0 { return "$0" }
        if v < 0.01 { return "<$0.01" }
        if v >= 1000 { return String(format: "$%.0f", v) }
        return String(format: "$%.2f", v)
    }
    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func duration(_ t: TimeInterval) -> String {
        if t < 60 { return "\(Int(t))s" }
        if t < 3600 { return "\(Int(t / 60))m" }
        return String(format: "%.1fh", t / 3600)
    }
    static func number(_ v: Double, digits: Int = 1) -> String { String(format: "%.\(digits)f", v) }
    static func relative(_ d: Date) -> String { d.formatted(.relative(presentation: .named)) }
    static func hour(_ h: Int) -> String {
        var c = DateComponents(); c.hour = h
        return Calendar.current.date(from: c)?.formatted(.dateTime.hour()) ?? "\(h):00"
    }
    static func model(_ m: String) -> String {
        m.replacingOccurrences(of: "claude-", with: "").replacingOccurrences(of: "anthropic/", with: "")
    }
}

struct Card<Content: View>: View {
    let title: String?
    var subtitle: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder let content: Content

    init(_ title: String? = nil, subtitle: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if title != nil || trailing != nil {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let title { Text(title).font(.headline) }
                        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    trailing
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct KPITile: View {
    let title: String
    let value: String
    var detail: String? = nil
    var symbol: String
    var tint: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .labelStyle(TintedLabel(tint: tint))
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.5)))
    }
}

struct TintedLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) { configuration.icon.foregroundStyle(tint); configuration.title }
    }
}

struct EditorBadge: View {
    let editor: Editor
    var compact = false
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: editor.symbol).font(.caption2.weight(.bold))
            if !compact { Text(editor.displayName).font(.caption.weight(.medium)) }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .foregroundStyle(editor.color)
        .background(Capsule().fill(editor.color.opacity(0.14)))
        .help(editor.displayName)
    }
}

struct EmptyState: View {
    let title: String
    let message: String
    var symbol = "tray"
    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(message))
            .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// Horizontal bar list: label · bar · value.
struct BarList: View {
    struct Row: Identifiable { let id = UUID(); let label: String; let value: Double; let display: String; var color: Color = .accentColor; var badge: Editor? = nil }
    let rows: [Row]
    var limit = 8

    var body: some View {
        let shown = Array(rows.prefix(limit))
        let mx = shown.map(\.value).max() ?? 1
        VStack(spacing: 8) {
            ForEach(shown) { r in
                HStack(spacing: 10) {
                    if let b = r.badge { Image(systemName: b.symbol).foregroundStyle(b.color).frame(width: 16) }
                    Text(r.label).font(.callout).lineLimit(1).truncationMode(.middle)
                        .frame(width: 150, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(r.color.gradient)
                            .frame(width: max(2, g.size.width * (mx > 0 ? r.value / mx : 0)))
                    }
                    .frame(height: 10)
                    Text(r.display).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
            }
            if shown.isEmpty { Text("No data").foregroundStyle(.secondary).font(.callout) }
        }
    }
}

/// GitHub-style contribution grid for the last 53 weeks.
struct ActivityHeatmap: View {
    let counts: [Date: Int]
    var tint: Color = .accentColor
    private let cal = Calendar.current

    var body: some View {
        let today = cal.startOfDay(for: Date())
        let weekdayOffset = (cal.component(.weekday, from: today) + 5) % 7 // Monday = 0
        let start = cal.date(byAdding: .day, value: -(52 * 7 + weekdayOffset), to: today)!
        let mx = max(counts.values.max() ?? 1, 1)
        let gap: CGFloat = 3
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                let cell = max(8, min(15, (geo.size.width - 52 * gap) / 53))
                HStack(alignment: .top, spacing: gap) {
                    ForEach(0..<53, id: \.self) { w in
                        VStack(spacing: gap) {
                            ForEach(0..<7, id: \.self) { d in
                                let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                                let c = counts[day] ?? 0
                                RoundedRectangle(cornerRadius: 2.5)
                                    .fill(day > today ? Color.clear : color(c, mx))
                                    .frame(width: cell, height: cell)
                                    .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(c) prompts")
                            }
                        }
                    }
                }
            }
            .frame(height: 7 * 15 + 6 * gap)
            HStack(spacing: 4) {
                Text("Less").font(.caption2).foregroundStyle(.secondary)
                ForEach([0, 1, 3, 6, 10], id: \.self) { v in
                    RoundedRectangle(cornerRadius: 2.5).fill(color(v, 10)).frame(width: 11, height: 11)
                }
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func color(_ c: Int, _ mx: Int) -> Color {
        if c == 0 { return Color.secondary.opacity(0.12) }
        let f = min(1, 0.25 + 0.75 * sqrt(Double(c) / Double(mx)))
        return tint.opacity(f)
    }
}

/// Weekday × hour grid.
struct HourHeatmap: View {
    let cells: [HourCell]
    var tint: Color = .accentColor
    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    var body: some View {
        let mx = max(cells.map(\.count).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 3) {
            ForEach(0..<7, id: \.self) { d in
                HStack(spacing: 3) {
                    Text(days[d]).font(.caption2).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let c = cells.first { $0.weekday == d && $0.hour == h }?.count ?? 0
                        RoundedRectangle(cornerRadius: 2)
                            .fill(c == 0 ? Color.secondary.opacity(0.1) : tint.opacity(0.2 + 0.8 * Double(c) / Double(mx)))
                            .frame(maxWidth: .infinity).frame(height: 14)
                            .help("\(days[d]) \(Fmt.hour(h)): \(c) prompts")
                    }
                }
            }
            HStack(spacing: 3) {
                Spacer().frame(width: 28)
                ForEach(0..<24, id: \.self) { h in
                    Text(h % 6 == 0 ? Fmt.hour(h) : "").font(.system(size: 8)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).fixedSize()
                }
            }
        }
    }
}

struct QuotaBar: View {
    let window: QuotaWindow
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(window.label).font(compact ? .caption : .callout)
                Spacer()
                if let f = window.usedFraction {
                    Text(Fmt.percent(f)).font((compact ? Font.caption : .callout).monospacedDigit().weight(.semibold))
                        .foregroundStyle(color(f))
                } else if let t = window.usedText { Text(t).font(.caption).foregroundStyle(.secondary) }
            }
            if let f = window.usedFraction {
                MeterBar(fraction: f, color: color(f))
            }
            HStack {
                if let t = window.usedText, window.usedFraction != nil { Text(t) }
                Spacer()
                if let r = window.resetsAt { Text("Resets \(Fmt.relative(r))") }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func color(_ f: Double) -> Color { f >= 0.9 ? .red : f >= 0.7 ? .orange : .green }
}

extension View {
    func pagePadding() -> some View { self.padding(20).frame(maxWidth: .infinity, alignment: .topLeading) }
}

/// Global range + editor filter shown in every page's toolbar.
struct FilterToolbar: ToolbarContent {
    @Bindable var store: DataStore
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("All editors") { store.filter.editors = [] }
                Divider()
                ForEach(Editor.allCases) { e in
                    Toggle(isOn: Binding(
                        get: { store.filter.editors.contains(e) },
                        set: { on in if on { store.filter.editors.insert(e) } else { store.filter.editors.remove(e) } })) {
                        Label(e.displayName, systemImage: e.symbol)
                    }
                    .disabled(!store.detectedEditors.contains(e) && !store.filter.editors.contains(e))
                }
            } label: {
                Label(store.filter.editors.isEmpty ? "All editors" : "\(store.filter.editors.count) editor(s)",
                      systemImage: "line.3.horizontal.decrease.circle")
            }
            Picker("Range", selection: $store.filter.range) {
                ForEach(DateRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            .frame(width: 120)
            Button { Task { await store.refresh() } } label: {
                if store.isLoading { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
            }
            .help("Re-scan all local history")
        }
    }
}

/// Dashed horizontal budget line for cost charts; draws nothing when `limit` is 0. Being a mark
/// (not an overlay) it widens the y-axis so the line stays visible while spend is below it.
struct BudgetRule: ChartContent {
    let limit: Double
    let label: String
    var body: some ChartContent {
        if limit > 0 {
            RuleMark(y: .value("Budget", limit))
                .foregroundStyle(Color.red.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .annotation(position: .top, alignment: .trailing) {
                    Text("\(label) \(Fmt.cost(limit))").font(.caption2.weight(.medium)).foregroundStyle(.red)
                }
        }
    }
}

extension Editor {
    /// Editors with data, in a stable order: chart color scales use this so legends stay short.
    @MainActor static var shown: [Editor] {
        let found = DataStore.shared.detectedEditors
        let list = allCases.filter { found.contains($0) }
        return list.isEmpty ? allCases : list
    }
}

/// Thin rounded progress bar that keeps its color when the window is inactive
/// (a tinted ProgressView turns grey in background windows).
struct MeterBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.18))
                Capsule().fill(color.gradient).frame(width: max(height, g.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue(Text(Fmt.percent(fraction)))
    }
}
