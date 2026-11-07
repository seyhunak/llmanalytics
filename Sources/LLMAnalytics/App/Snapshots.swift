import SwiftUI
import AppKit

/// `LLMAnalytics --snapshot <dir>` renders every page and the menu bar popover to PNGs
/// (used for README screenshots and visual checks without screen-recording permission).
@MainActor
enum Snapshots {
    static var outputDir: String? {
        guard let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    static func run(to dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let store = DataStore.shared
        await store.reload(editors: Set(Editor.allCases))
        await SubscriptionService.shared.refresh()
        try? await Task.sleep(for: .milliseconds(600)) // let analytics publish
        for page in Page.allCases {
            Navigation.shared.page = page
            if page == .projects { Navigation.shared.selectedProject = store.analytics.byProject.first?.id }
            await render(RootView(), size: NSSize(width: 1280, height: 860), to: "\(dir)/\(page.rawValue.replacingOccurrences(of: " ", with: "-").lowercased()).png")
        }
        Navigation.shared.page = .sessions
        Navigation.shared.inspectedSessionID = store.sessions.first { $0.editor == .claudeCode }?.id ?? store.sessions.first?.id
        await render(RootView(), size: NSSize(width: 1280, height: 860), to: "\(dir)/transcript.png")
        Navigation.shared.inspectedSessionID = nil
        await render(MenuBarView().background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 330, height: 640), to: "\(dir)/menubar.png")
        await render(SubscriptionsView().background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 1040, height: 860), to: "\(dir)/subscriptions-standalone.png")
        print("snapshots written to \(dir)")
        exit(0)
    }

    private static func render<V: View>(_ view: V, size: NSSize, to path: String) async {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
        window.contentView = nil
    }
}
