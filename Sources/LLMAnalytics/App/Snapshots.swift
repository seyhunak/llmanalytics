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

    static var light: Bool { CommandLine.arguments.contains("--light") }

    static func run(to dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(1))   // activation is asynchronous
        let store = DataStore.shared
        if DemoData.enabled {
            store.loadDemo(DemoData.sessions())
            SubscriptionService.shared.loadDemo(providers: DemoData.providers(), manual: DemoData.manualPlans)
        } else {
            await store.reload(editors: Set(Editor.allCases))
            await SubscriptionService.shared.refresh()
        }
        try? await Task.sleep(for: .milliseconds(600)) // let analytics publish
        for page in Page.allCases {
            Navigation.shared.page = page
            if page == .projects { Navigation.shared.selectedProject = store.analytics.byProject.first?.id }
            await render(RootView(), size: NSSize(width: 1280, height: 860), to: "\(dir)/\(page.rawValue.replacingOccurrences(of: " ", with: "-").lowercased()).png")
        }
        Navigation.shared.page = .sessions
        Navigation.shared.inspectedSessionID = (DemoData.enabled ? store.sessions.first { $0.title == DemoData.featured }?.id : nil)
            ?? store.sessions.first { $0.editor == .claudeCode && $0.userMessages > 3 }?.id ?? store.sessions.first?.id
        await render(RootView(), size: NSSize(width: 1280, height: 860), to: "\(dir)/transcript.png")
        Navigation.shared.inspectedSessionID = nil
        await render(MenuBarView().background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 330, height: DemoData.enabled ? 1010 : 640), to: "\(dir)/menubar.png")
        await render(SubscriptionsView().background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 1040, height: 860), to: "\(dir)/subscriptions-standalone.png")
        let bg = Color(nsColor: .windowBackgroundColor)
        await render(VStack(spacing: 16) {
            WhatIfCard(sessions: store.analytics.sessions)
            OverpoweredCard(sessions: store.analytics.sessions)
        }.padding(20).frame(maxHeight: .infinity, alignment: .top).background(bg),
                     size: NSSize(width: 1040, height: 1080), to: "\(dir)/what-if.png")
        await render(BudgetSettings().background(bg), size: NSSize(width: 520, height: 520), to: "\(dir)/budgets-settings.png")
        print("snapshots written to \(dir)")
        exit(0)
    }

    private static func render<V: View>(_ view: V, size: NSSize, to path: String) async {
        let window = SnapshotWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.appearance = NSAppearance(named: Snapshots.light ? .aqua : .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        // Active, key window so controls draw in their real colors instead of inactive graphite.
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1500))
        window.makeFirstResponder(nil)   // no focus ring or selected text field in screenshots
        host.layoutSubtreeIfNeeded()
        // Prefer the window server's composited image: it keeps translucency, tables and
        // materials exactly as on screen. A process may capture its own windows without
        // Screen Recording permission. Fall back to AppKit's cached drawing otherwise.
        if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                            [.boundsIgnoreFraming, .bestResolution]), cg.width > 10 {
            let rep = NSBitmapImageRep(cgImage: cg)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } else if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        window.orderOut(nil)
        window.contentView = nil
    }
}

/// Borderless-style offscreen windows refuse key status by default; screenshots need it.
private final class SnapshotWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
