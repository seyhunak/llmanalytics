import SwiftUI

struct SubscriptionsView: View {
    @State private var subs = SubscriptionService.shared
    @State private var editing: ManualPlan?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Plans, quotas and rate limits. Codex limits are read from Codex's own logs. Live lookups for Claude Code, Copilot and Cursor call that vendor's API with the login the tool already stored on this Mac — nothing is sent anywhere else.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await subs.refresh() } } label: {
                        if subs.isRefreshing { ProgressView().controlSize(.small) } else { Label("Refresh", systemImage: "arrow.clockwise") }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16, alignment: .top)], spacing: 16) {
                    ForEach(subs.providers) { ProviderCard(provider: $0) }
                }
                Card("Manually tracked plans", subtitle: "For tools without local usage data (Devin, Windsurf, ChatGPT…). Counts toward monthly spend.",
                     trailing: AnyView(Button { editing = ManualPlan(name: "", monthlyPrice: 20) } label: { Label("Add plan", systemImage: "plus") })) {
                    if subs.manualPlans.isEmpty {
                        Text("No manual plans yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(subs.manualPlans) { plan in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(plan.name).font(.headline)
                                Text("\(Fmt.cost(plan.monthlyPrice))/month · renews on day \(plan.renewalDay)").font(.caption).foregroundStyle(.secondary)
                                if plan.quotaTotal > 0 {
                                    QuotaBar(window: QuotaWindow(label: plan.quotaLabel.isEmpty ? "Quota" : plan.quotaLabel,
                                                                 usedFraction: plan.quotaUsed / plan.quotaTotal,
                                                                 usedText: "\(Fmt.compact(plan.quotaUsed)) / \(Fmt.compact(plan.quotaTotal))",
                                                                 resetsAt: nextRenewal(day: plan.renewalDay)))
                                        .frame(maxWidth: 360)
                                }
                            }
                            Spacer()
                            Button("Edit") { editing = plan }
                            Button(role: .destructive) { subs.manualPlans.removeAll { $0.id == plan.id } } label: { Image(systemName: "trash") }
                        }
                        Divider()
                    }
                }
            }
            .pagePadding()
        }
        .sheet(item: $editing) { plan in
            ManualPlanEditor(plan: plan) { saved in
                if let i = subs.manualPlans.firstIndex(where: { $0.id == saved.id }) { subs.manualPlans[i] = saved }
                else { subs.manualPlans.append(saved) }
            }
        }
        .task { if subs.providers.isEmpty { await subs.refresh() } }
    }

    private func nextRenewal(day: Int) -> Date? {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month], from: Date()); c.day = min(max(day, 1), 28)
        guard let thisMonth = cal.date(from: c) else { return nil }
        return thisMonth > Date() ? thisMonth : cal.date(byAdding: .month, value: 1, to: thisMonth)
    }
}

struct ProviderCard: View {
    let provider: ProviderUsage
    @State private var subs = SubscriptionService.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: provider.symbol).font(.title3).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.provider).font(.headline)
                        Text(provider.plan ?? "Plan unknown").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusPill
                }
                switch provider.status {
                case .notDetected(let why):
                    Text(why).font(.callout).foregroundStyle(.secondary)
                case .disconnected:
                    Text("Turn on live lookup to see current quota usage.").font(.callout).foregroundStyle(.secondary)
                case .error(let e):
                    Label(e, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                case .ok:
                    if provider.windows.isEmpty { Text("No quota data available.").font(.callout).foregroundStyle(.secondary) }
                    ForEach(provider.windows) { QuotaBar(window: $0) }
                }
                ForEach(provider.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                if provider.supportsLive, !isNotDetected {
                    Toggle("Live lookup", isOn: Binding(get: { subs.liveEnabled.contains(provider.provider) },
                                                        set: { subs.setLive(provider.provider, $0) }))
                        .toggleStyle(.switch).controlSize(.small).font(.caption)
                }
            }
        }
    }

    private var isNotDetected: Bool { if case .notDetected = provider.status { return true }; return false }

    @ViewBuilder private var statusPill: some View {
        let (text, color): (String, Color) = {
            switch provider.status {
            case .ok: return ("Connected", .green)
            case .disconnected: return ("Offline", .secondary)
            case .notDetected: return ("Not found", .secondary)
            case .error: return ("Error", .orange)
            }
        }()
        Text(text).font(.caption2.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
            .foregroundStyle(color).background(Capsule().fill(color.opacity(0.14)))
    }
}

struct ManualPlanEditor: View {
    @State var plan: ManualPlan
    let onSave: (ManualPlan) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Name", text: $plan.name, prompt: Text("e.g. Devin Team"))
            TextField("Monthly price (USD)", value: $plan.monthlyPrice, format: .number)
            Stepper("Renews on day \(plan.renewalDay)", value: $plan.renewalDay, in: 1...28)
            Section("Optional quota") {
                TextField("Quota label", text: $plan.quotaLabel, prompt: Text("e.g. ACUs"))
                TextField("Used", value: $plan.quotaUsed, format: .number)
                TextField("Total", value: $plan.quotaTotal, format: .number)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { onSave(plan); dismiss() }.disabled(plan.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
