import SwiftUI

enum Page: String, CaseIterable, Identifiable, Hashable {
    case dashboard = "Dashboard", sessions = "Sessions", costs = "Costs", projects = "Projects"
    case analysis = "Deep Analysis", compare = "Compare", subscriptions = "Subscriptions"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .dashboard: "square.grid.2x2"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .costs: "dollarsign.circle"
        case .projects: "folder"
        case .analysis: "chart.xyaxis.line"
        case .compare: "rectangle.split.2x1"
        case .subscriptions: "gauge.with.dots.needle.67percent"
        }
    }
}

@MainActor
@Observable
final class Navigation {
    static let shared = Navigation()
    var page: Page = .dashboard
    var inspectedSessionID: String?
    var selectedProject: String?
    var sessionSearch = ""
}

struct RootView: View {
    @State private var store = DataStore.shared
    @State private var nav = Navigation.shared

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.page }, set: { if let p = $0 { nav.page = p } })) {
                Section("Overview") {
                    ForEach([Page.dashboard, .sessions, .costs, .projects]) { p in
                        Label(p.rawValue, systemImage: p.symbol).tag(p)
                    }
                }
                Section("Insights") {
                    ForEach([Page.analysis, .compare, .subscriptions]) { p in
                        Label(p.rawValue, systemImage: p.symbol).tag(p)
                    }
                }
                Section("Sources") {
                    ForEach(Editor.allCases) { e in
                        let n = store.sessions.lazy.filter { $0.editor == e }.count
                        HStack {
                            Image(systemName: e.symbol).foregroundStyle(e.color).frame(width: 16)
                            Text(e.displayName).foregroundStyle(n > 0 ? .primary : .tertiary)
                            Spacer()
                            Text(n > 0 ? "\(n)" : "—").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { StatusFooter(store: store) }
        } detail: {
            Group {
                switch nav.page {
                case .dashboard: DashboardView()
                case .sessions: SessionsView()
                case .costs: CostsView()
                case .projects: ProjectsView()
                case .analysis: AnalysisView()
                case .compare: CompareView()
                case .subscriptions: SubscriptionsView()
                }
            }
            .navigationTitle(nav.page.rawValue)
            .toolbar { FilterToolbar(store: store) }
            .inspector(isPresented: Binding(get: { nav.inspectedSessionID != nil },
                                            set: { if !$0 { nav.inspectedSessionID = nil } })) {
                if let id = nav.inspectedSessionID, let s = store.session(id: id) {
                    TranscriptView(session: s).inspectorColumnWidth(min: 380, ideal: 520, max: 900)
                } else {
                    EmptyState(title: "Session not found", message: "It may have been removed.")
                }
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
    }
}

struct StatusFooter: View {
    let store: DataStore
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(store.isLoading ? Color.orange : Color.green).frame(width: 7, height: 7)
            if store.isLoading { Text("Scanning…") }
            else if let u = store.lastUpdated {
                TimelineView(.periodic(from: .now, by: 15)) { _ in Text("Live · updated \(Fmt.relative(u))") }
            }
            Spacer()
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}
