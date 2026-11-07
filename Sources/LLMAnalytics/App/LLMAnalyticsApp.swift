import SwiftUI
import UserNotifications
import AppKit

@main
struct LLMAnalyticsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        if CommandLine.arguments.contains("--dump") { Diagnostics.dumpAndExit() }
    }

    var body: some Scene {
        Window("LLM Analytics", id: "main") {
            RootView()
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Data") { Task { await DataStore.shared.refresh() } }.keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarView()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings { SettingsView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let dir = Snapshots.outputDir {
            Task { @MainActor in await Snapshots.run(to: dir) }
            return
        }
        Self.applyDockPolicy(UserDefaults.standard.object(forKey: "showDockIcon") as? Bool ?? true)
        Task { @MainActor in
            if Bundle.main.bundleURL.pathExtension == "app" { UNUserNotificationCenter.current().delegate = self }
            if AlertSettings.current.enabled { AlertCenter.shared.requestPermission() }
            DataStore.shared.start()
            SubscriptionService.shared.start()
        }
    }

    /// Show alerts as banners even while the app is frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Closing the window keeps the app alive in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    static func applyDockPolicy(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if show { NSApp.activate(ignoringOtherApps: true) }
    }
}

/// `LLMAnalytics --dump` prints what each parser found; handy for bug reports.
enum Diagnostics {
    static func dumpAndExit() -> Never {
        var all: [SessionSummary] = []
        for src in Sources.all {
            let files = src.discover()
            let t0 = Date()
            let sessions = files.flatMap { Sources.parse(src, $0, previous: nil).sessions }
            all += sessions
            let tokens = sessions.reduce(TokenUsage()) { $0 + $1.tokens }
            let cost = sessions.reduce(0) { $0 + $1.cost }
            print(String(format: "%-18@ files=%-5d sessions=%-5d msgs=%-6d tokens=%-12d cost=$%.2f  (%.2fs)",
                         src.editor.displayName as NSString, files.count, sessions.count,
                         sessions.reduce(0) { $0 + $1.messageCount }, tokens.total, cost, Date().timeIntervalSince(t0)))
        }
        all = Sources.merge(all)
        print("After merge:", Editor.allCases.map { e in "\(e.displayName)=\(all.filter { $0.editor == e }.count)" }.joined(separator: ", "))
        let a = Analytics.compute(all: all, filter: Filter(range: .all))
        print("\nTotal sessions \(a.sessions.count), active days \(a.activeDays), streak \(a.currentStreak)/\(a.longestStreak), cost \(Fmt.cost(a.totalCost)), cache hit \(Fmt.percent(a.cacheHitRate))")
        print("Top models:", a.byModel.prefix(6).map { "\($0.model)=\($0.responses) (\(Fmt.cost($0.cost)))" }.joined(separator: ", "))
        print("Top tools:", a.byTool.prefix(8).map { "\($0.name)=\($0.count)" }.joined(separator: ", "))
        print("Top projects:", a.byProject.prefix(5).map { "\($0.name)=\($0.sessions)" }.joined(separator: ", "))
        if let s = a.sessions.first {
            let t = Sources.source(for: s.editor)?.transcript(for: s) ?? []
            print("Latest: [\(s.editor.displayName)] \(s.title) — transcript messages: \(t.count)")
        }
        let l = LiveSnapshot.compute(all: all)
        print("Today: \(Fmt.cost(l.todayCost)), \(Fmt.tokens(l.todayTokens.total)) tokens, active now: \(l.activeSessions.count)")
        if let rl = CodexSource().latestRateLimits() {
            print("Codex limits: plan=\(rl.plan ?? "?") primary=\(rl.primary.map { "\($0.used)% / \($0.windowMinutes)m" } ?? "-")")
        }
        exit(0)
    }
}
