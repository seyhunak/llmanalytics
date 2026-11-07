import Testing
import Foundation
@testable import LLMAnalytics

@Suite struct AnalyticsTests {
    let cal = Calendar.current

    func session(_ id: String, editor: Editor = .claudeCode, daysAgo: Int, cost tokens: Int = 1000, project: String = "/p") -> SessionSummary {
        let t = cal.date(byAdding: .day, value: -daysAgo, to: Date())!
        return SessionSummary(nativeID: id, editor: editor, sourcePath: "/x/\(id)", title: id, project: project,
                              start: t, end: t, userMessages: 1, assistantMessages: 1,
                              events: [UsageEvent(timestamp: t, model: "claude-opus-5-5", tokens: TokenUsage(input: tokens), reportedCost: nil)],
                              userTimes: [t])
    }

    @Test func streaks() {
        let today = cal.startOfDay(for: Date())
        let days = Set([0, 1, 2, 5, 6, 7, 8].map { cal.date(byAdding: .day, value: -$0, to: today)! })
        let (current, longest) = Analytics.streaks(days, now: Date(), cal: cal)
        #expect(current == 3)
        #expect(longest == 4)
        #expect(Analytics.streaks([], now: Date(), cal: cal) == (0, 0))
    }

    @Test func rangeAndEditorFilters() {
        let all = [session("a", daysAgo: 0), session("b", daysAgo: 3), session("c", editor: .codex, daysAgo: 40)]
        let week = Analytics.compute(all: all, filter: Filter(range: .week))
        #expect(week.sessions.count == 2)
        #expect(week.totalTokens.input == 2000)
        let codex = Analytics.compute(all: all, filter: Filter(range: .all, editors: [.codex]))
        #expect(codex.sessions.map(\.nativeID) == ["c"])
        #expect(codex.byEditor.first?.editor == .codex)
    }

    @Test func liveSnapshotCountsTodayOnly() {
        let snap = LiveSnapshot.compute(all: [session("a", daysAgo: 0, cost: 1_000_000), session("b", daysAgo: 2, cost: 1_000_000)])
        #expect(snap.todayTokens.input == 1_000_000)
        #expect(abs(snap.todayCost - 4) < 1e-9)
        #expect(snap.last7Days.count == 7)
    }

    @Test func diskCacheRoundTrip() throws {
        let dir = TempDir()
        let url = dir.url.appendingPathComponent("cache.json")
        let s = session("a", daysAgo: 1)
        let f = SourceFile(path: "/x/a", mtime: Date(timeIntervalSince1970: 1_700_000_000), size: 42)
        DiskCache.save(["/x/a": .init(editor: .claudeCode, file: f, sessions: [s], state: nil)], to: url)
        let loaded = DiskCache.load(from: url)
        let entry = try #require(loaded["/x/a"])
        #expect(entry.file == f)
        #expect(entry.sessions.first?.tokens == s.tokens)
        #expect(entry.sessions.first?.cost == s.cost)
    }
}

@Suite struct ProjectResolverTests {
    @Test func resolvesGitRootAndWorktrees() {
        let dir = TempDir()
        let repo = dir.mkdir("repo")
        _ = dir.mkdir("repo/.git/worktrees/feature")
        let sub = dir.mkdir("repo/src/deep")
        let wt = dir.mkdir("wt-feature")
        dir.write("wt-feature/.git", "gitdir: \(repo)/.git/worktrees/feature\n")
        let plain = dir.mkdir("not-a-repo")
        ProjectResolver.resetCache()
        #expect(ProjectResolver.root(for: sub) == repo)
        #expect(ProjectResolver.root(for: wt) == repo)
        #expect(ProjectResolver.root(for: plain) == plain)
        #expect(ProjectResolver.root(for: "gemini:abc") == "gemini:abc")
    }
}
