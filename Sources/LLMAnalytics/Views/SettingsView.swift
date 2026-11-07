import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage("showDockIcon") private var showDockIcon = true
    @AppStorage("menuBarMetric") private var menuBarMetric = "cost"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var store = DataStore.shared

    var body: some View {
        TabView {
            Form {
                Section("App") {
                    Toggle("Launch at login", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, on in
                            do {
                                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                                loginError = nil
                            } catch { loginError = error.localizedDescription; launchAtLogin = !on }
                        }
                    if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                    Toggle("Show Dock icon", isOn: $showDockIcon)
                        .onChange(of: showDockIcon) { _, on in AppDelegate.applyDockPolicy(on) }
                    Text("With the Dock icon hidden, LLM Analytics lives only in the menu bar.").font(.caption).foregroundStyle(.secondary)
                    Picker("Menu bar shows", selection: $menuBarMetric) {
                        Text("Today's cost").tag("cost")
                        Text("Today's tokens").tag("tokens")
                        Text("Icon only").tag("none")
                    }
                }
                Section("Data sources") {
                    ForEach(Sources.all, id: \.editor) { src in
                        HStack {
                            Image(systemName: src.editor.symbol).foregroundStyle(src.editor.color).frame(width: 18)
                            Text(src.editor.displayName)
                            Spacer()
                            let n = store.sessions.filter { $0.editor == src.editor }.count
                            Text(n > 0 ? "\(n) sessions" : "not found").foregroundStyle(.secondary).font(.caption)
                        }
                    }
                    Text("Everything is read locally and read-only. No analytics, no telemetry.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Pricing") {
                    Text("Override or add model prices (USD per 1M tokens) in:").font(.caption)
                    Text(Pricing.overridesURL.path).font(.caption.monospaced()).textSelection(.enabled)
                    HStack {
                        Button("Create / open pricing.json") { openPricingFile() }
                        Button("Reload prices") { Pricing.reloadOverrides(); Task { await store.refresh() } }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            BudgetSettings().tabItem { Label("Budgets & Alerts", systemImage: "bell.badge") }

            AboutView().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 520)
    }

    private func openPricingFile() {
        let url = Pricing.overridesURL
        if !FS.exists(url.path) {
            let sample = """
            {
              "my-custom-model": { "input": 1.0, "output": 4.0, "cacheRead": 0.1, "cacheWrite": 0 }
            }
            """
            try? sample.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(url)
    }
}

struct BudgetSettings: View {
    @AppStorage("budget.day") private var daily = 0.0
    @AppStorage("budget.week") private var weekly = 0.0
    @AppStorage("budget.month") private var monthly = 0.0
    @AppStorage("alerts.enabled") private var alertsOn = true
    @AppStorage("alerts.threshold") private var threshold = 0.8
    @AppStorage("alerts.runawayCost") private var runaway = 10.0
    @State private var store = DataStore.shared

    var body: some View {
        Form {
            Section {
                money("Daily", $daily, spent: store.live.todayCost)
                money("Weekly", $weekly, spent: store.live.weekCost)
                money("Monthly", $monthly, spent: store.live.monthCost)
            } header: { Text("Budgets") } footer: {
                Text("At API list prices, across all editors. Leave at 0 for no budget. Budgets show as lines on the cost charts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Send macOS notifications", isOn: $alertsOn)
                    .onChange(of: alertsOn) { _, on in if on { AlertCenter.shared.requestPermission() } }
                Picker("Warn at", selection: $threshold) {
                    ForEach([0.5, 0.7, 0.8, 0.9, 0.95], id: \.self) { Text(Fmt.percent($0)).tag($0) }
                }
                .disabled(!alertsOn)
                Text("Applies to budgets and to plan quotas (Claude, Codex, Copilot, Cursor and manual plans). A second alert is sent at 100%.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Runaway session")
                    Spacer()
                    TextField("", value: $runaway, format: .currency(code: "USD")).frame(width: 90).multilineTextAlignment(.trailing)
                }
                .disabled(!alertsOn)
                Text("Alert when a single live session passes this cost, and again each time it doubles. 0 turns it off.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Send test notification") { AlertCenter.shared.requestPermission(); AlertCenter.shared.sendTest() }
                    .disabled(!alertsOn)
            }
        }
        .formStyle(.grouped)
    }

    private func money(_ label: String, _ value: Binding<Double>, spent: Double) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(Fmt.cost(spent)) so far").font(.caption).foregroundStyle(.secondary)
            TextField("", value: value, format: .currency(code: "USD")).frame(width: 90).multilineTextAlignment(.trailing)
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("LLM Analytics").font(.title2.weight(.semibold))
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")").foregroundStyle(.secondary)
            Text("Free and open source (MIT). Local-first usage analytics for AI coding tools.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
