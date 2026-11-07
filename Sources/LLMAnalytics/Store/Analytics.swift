import Foundation

enum DateRange: String, CaseIterable, Identifiable, Sendable {
    case today = "Today", week = "7 days", month = "30 days", quarter = "90 days", year = "12 months", all = "All time"
    var id: String { rawValue }

    func start(now: Date = Date(), cal: Calendar = .current) -> Date? {
        let today = cal.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return cal.date(byAdding: .day, value: -6, to: today)
        case .month: return cal.date(byAdding: .day, value: -29, to: today)
        case .quarter: return cal.date(byAdding: .day, value: -89, to: today)
        case .year: return cal.date(byAdding: .month, value: -12, to: today)
        case .all: return nil
        }
    }
}

struct Filter: Equatable, Sendable {
    var range: DateRange = .month
    var editors: Set<Editor> = []      // empty == all
    var project: String? = nil

    func includes(_ s: SessionSummary, rangeStart: Date?) -> Bool {
        if !editors.isEmpty && !editors.contains(s.editor) { return false }
        if let project, s.project != project { return false }
        if let rangeStart, s.end < rangeStart { return false }
        return true
    }
}

struct DayPoint: Identifiable, Hashable, Sendable {
    var id: String { "\(date.timeIntervalSince1970)-\(editor.rawValue)" }
    let date: Date
    let editor: Editor
    var tokens: Int = 0
    var cost: Double = 0
    var messages: Int = 0
    var sessions: Int = 0
}

struct EditorStat: Identifiable, Hashable, Sendable {
    var id: Editor { editor }
    let editor: Editor
    var sessions = 0, userMessages = 0, assistantMessages = 0, toolCalls = 0
    var tokens = TokenUsage()
    var cost = 0.0
    var totalDuration: TimeInterval = 0
    var activeDays = Set<Date>()
    var models: [String: Int] = [:]

    var messages: Int { userMessages + assistantMessages }
    var avgMessages: Double { sessions == 0 ? 0 : Double(messages) / Double(sessions) }
    var avgTokens: Double { sessions == 0 ? 0 : Double(tokens.total) / Double(sessions) }
    var avgCost: Double { sessions == 0 ? 0 : cost / Double(sessions) }
    var avgDurationMin: Double { sessions == 0 ? 0 : totalDuration / Double(sessions) / 60 }
    var toolsPerSession: Double { sessions == 0 ? 0 : Double(toolCalls) / Double(sessions) }
    var outputInputRatio: Double { tokens.allInput == 0 ? 0 : Double(tokens.output) / Double(tokens.allInput) }
    var cacheHitRate: Double { tokens.allInput == 0 ? 0 : Double(tokens.cacheRead) / Double(tokens.allInput) }
    var tokensPerMessage: Double { messages == 0 ? 0 : Double(tokens.total) / Double(messages) }
}

struct ModelStat: Identifiable, Hashable, Sendable {
    var id: String { model }
    let model: String
    var responses = 0
    var tokens = TokenUsage()
    var cost = 0.0
    var editors = Set<Editor>()
}

struct ProjectStat: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    var name: String { SessionSummary.projectName(path) }
    var sessions = 0, messages = 0, toolCalls = 0
    var tokens = TokenUsage()
    var cost = 0.0
    var lastActive = Date.distantPast
    var firstActive = Date.distantFuture
    var editors: [Editor: Int] = [:]
    var models: [String: Int] = [:]
    var tools: [String: Int] = [:]
}

struct MonthCost: Identifiable, Hashable, Sendable {
    var id: String { "\(month.timeIntervalSince1970)-\(editor.rawValue)" }
    let month: Date
    let editor: Editor
    var cost: Double
    var tokens: Int
}

struct HourCell: Identifiable, Hashable, Sendable {
    var id: Int { weekday * 24 + hour }
    let weekday: Int  // 0 = Monday
    let hour: Int
    var count: Int
}

struct Analytics: Sendable {
    var sessions: [SessionSummary] = []
    var totalTokens = TokenUsage()
    var totalCost = 0.0
    var userMessages = 0, assistantMessages = 0, toolCalls = 0
    var activeDays = 0, currentStreak = 0, longestStreak = 0
    var avgSessionMinutes = 0.0
    var daily: [DayPoint] = []
    var heatmap: [Date: Int] = [:]           // messages per day, last 53 weeks
    var hours: [HourCell] = []
    var byEditor: [EditorStat] = []
    var byModel: [ModelStat] = []
    var byTool: [(name: String, count: Int)] = []
    var toolByEditor: [String: [Editor: Int]] = [:]
    var byProject: [ProjectStat] = []
    var byMonth: [MonthCost] = []
    var peakHour: Int? = nil
    var mostActiveDay: (date: Date, count: Int)? = nil

    var messages: Int { userMessages + assistantMessages }
    var cacheHitRate: Double { totalTokens.allInput == 0 ? 0 : Double(totalTokens.cacheRead) / Double(totalTokens.allInput) }

    static func compute(all: [SessionSummary], filter: Filter, now: Date = Date()) -> Analytics {
        let cal = Calendar.current
        let rangeStart = filter.range.start(now: now)
        var a = Analytics()
        let selected = all.filter { filter.includes($0, rangeStart: rangeStart) }
        a.sessions = selected.sorted { $0.end > $1.end }

        func inRange(_ d: Date) -> Bool { rangeStart.map { d >= $0 } ?? true }

        var daily: [Date: [Editor: DayPoint]] = [:]
        var editors: [Editor: EditorStat] = [:]
        var models: [String: ModelStat] = [:]
        var tools: [String: Int] = [:]
        var projects: [String: ProjectStat] = [:]
        var months: [Date: [Editor: MonthCost]] = [:]
        var hourGrid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        var activeDaySet = Set<Date>()
        var durations: TimeInterval = 0

        for s in selected {
            let day0 = cal.startOfDay(for: s.start)
            var es = editors[s.editor] ?? EditorStat(editor: s.editor)
            var ps = projects[s.project] ?? ProjectStat(path: s.project)
            es.sessions += 1; es.userMessages += s.userMessages; es.assistantMessages += s.assistantMessages
            es.toolCalls += s.toolCalls; es.totalDuration += min(s.duration, 8 * 3600)
            durations += min(s.duration, 8 * 3600)
            ps.sessions += 1; ps.messages += s.messageCount; ps.toolCalls += s.toolCalls
            ps.lastActive = max(ps.lastActive, s.end); ps.firstActive = min(ps.firstActive, s.start)
            ps.editors[s.editor, default: 0] += 1
            for (t, c) in s.tools {
                tools[t, default: 0] += c; ps.tools[t, default: 0] += c
                a.toolByEditor[t, default: [:]][s.editor, default: 0] += c
            }
            a.userMessages += s.userMessages; a.assistantMessages += s.assistantMessages; a.toolCalls += s.toolCalls

            var sessionDay = day0
            if !inRange(day0) { sessionDay = cal.startOfDay(for: max(s.start, rangeStart ?? s.start)) }
            daily[sessionDay, default: [:]][s.editor, default: DayPoint(date: sessionDay, editor: s.editor)].sessions += 1

            for t in s.userTimes where inRange(t) {
                let d = cal.startOfDay(for: t)
                activeDaySet.insert(d); es.activeDays.insert(d)
                daily[d, default: [:]][s.editor, default: DayPoint(date: d, editor: s.editor)].messages += 1
                let wd = (cal.component(.weekday, from: t) + 5) % 7  // Monday = 0
                hourGrid[wd][cal.component(.hour, from: t)] += 1
            }
            if s.userTimes.isEmpty, inRange(s.start) { activeDaySet.insert(day0); es.activeDays.insert(day0) }

            for e in s.events where inRange(e.timestamp) {
                let d = cal.startOfDay(for: e.timestamp)
                let cost = e.cost
                daily[d, default: [:]][s.editor, default: DayPoint(date: d, editor: s.editor)].tokens += e.tokens.total
                daily[d, default: [:]][s.editor]!.cost += cost
                es.tokens += e.tokens; es.cost += cost
                es.models[e.model, default: 0] += 1
                ps.tokens += e.tokens; ps.cost += cost; ps.models[e.model, default: 0] += 1
                var ms = models[e.model] ?? ModelStat(model: e.model)
                ms.responses += 1; ms.tokens += e.tokens; ms.cost += cost; ms.editors.insert(s.editor)
                models[e.model] = ms
                let mo = cal.date(from: cal.dateComponents([.year, .month], from: e.timestamp))!
                months[mo, default: [:]][s.editor, default: MonthCost(month: mo, editor: s.editor, cost: 0, tokens: 0)].cost += cost
                months[mo]![s.editor]!.tokens += e.tokens.total
                a.totalTokens += e.tokens; a.totalCost += cost
            }
            if s.events.isEmpty, let fm = s.fallbackModel {
                var ms = models[fm] ?? ModelStat(model: fm)
                ms.responses += s.assistantMessages; ms.editors.insert(s.editor)
                models[fm] = ms
                es.models[fm, default: 0] += s.assistantMessages
                ps.models[fm, default: 0] += s.assistantMessages
            }
            editors[s.editor] = es
            projects[s.project] = ps
        }

        a.daily = daily.values.flatMap { $0.values }.sorted { $0.date < $1.date }
        a.byEditor = editors.values.sorted { $0.sessions > $1.sessions }
        a.byModel = models.values.sorted { ($0.cost, $0.responses) > ($1.cost, $1.responses) }
        a.byTool = tools.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
        a.byProject = projects.values.sorted { $0.lastActive > $1.lastActive }
        a.byMonth = months.values.flatMap { $0.values }.sorted { $0.month < $1.month }
        a.hours = (0..<7).flatMap { w in (0..<24).map { h in HourCell(weekday: w, hour: h, count: hourGrid[w][h]) } }
        let hourTotals = (0..<24).map { h in (0..<7).reduce(0) { $0 + hourGrid[$1][h] } }
        if let mx = hourTotals.max(), mx > 0 { a.peakHour = hourTotals.firstIndex(of: mx) }
        a.activeDays = activeDaySet.count
        a.avgSessionMinutes = selected.isEmpty ? 0 : durations / Double(selected.count) / 60

        // Heatmap + streaks ignore the date range (always the last year) but honour editor/project filters.
        var unbounded = filter; unbounded.range = .all
        let yearAgo = cal.date(byAdding: .day, value: -371, to: cal.startOfDay(for: now))!
        var allDays = Set<Date>()
        for s in all where unbounded.includes(s, rangeStart: nil) {
            let times = s.userTimes.isEmpty ? [s.start] : s.userTimes
            for t in times {
                let d = cal.startOfDay(for: t)
                allDays.insert(d)
                if d >= yearAgo { a.heatmap[d, default: 0] += 1 }
            }
        }
        if let best = a.heatmap.max(by: { $0.value < $1.value }) { a.mostActiveDay = (best.key, best.value) }
        (a.currentStreak, a.longestStreak) = streaks(allDays, now: now, cal: cal)
        return a
    }

    static func streaks(_ days: Set<Date>, now: Date, cal: Calendar) -> (Int, Int) {
        guard !days.isEmpty else { return (0, 0) }
        let sorted = days.sorted()
        var longest = 0, run = 0
        var prev: Date?
        for d in sorted {
            if let p = prev, cal.dateComponents([.day], from: p, to: d).day == 1 { run += 1 } else { run = 1 }
            longest = max(longest, run); prev = d
        }
        var current = 0
        var d = cal.startOfDay(for: now)
        if !days.contains(d) { d = cal.date(byAdding: .day, value: -1, to: d)! } // today not started yet is fine
        while days.contains(d) { current += 1; d = cal.date(byAdding: .day, value: -1, to: d)! }
        return (current, longest)
    }
}

/// Always-unfiltered numbers for the menu bar.
struct LiveSnapshot: Sendable {
    var todayTokens = TokenUsage()
    var todayCost = 0.0
    var todayMessages = 0
    var todaySessions = 0
    var todayByEditor: [(editor: Editor, cost: Double, tokens: Int)] = []
    var activeSessions: [SessionSummary] = []
    var last7Days: [(date: Date, cost: Double, tokens: Int)] = []
    var monthCost = 0.0
    var weekCost = 0.0          // since the start of the calendar week
    var burnRatePerHour = 0.0   // cost in the last 60 minutes

    static func compute(all: [SessionSummary], now: Date = Date()) -> LiveSnapshot {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekStart = cal.date(byAdding: .day, value: -6, to: today)!
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now))!
        let hourAgo = now.addingTimeInterval(-3600)
        let calWeekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? weekStart
        var snap = LiveSnapshot()
        var perDay: [Date: (Double, Int)] = [:]
        var perEditor: [Editor: (Double, Int)] = [:]
        let from = min(weekStart, monthStart, calWeekStart)
        for s in all where s.end >= from {
            if s.end >= today { snap.todaySessions += 1 }
            snap.todayMessages += s.userTimes.filter { $0 >= today }.count
            for e in s.events where e.timestamp >= from {
                let c = e.cost
                if e.timestamp >= monthStart { snap.monthCost += c }
                if e.timestamp >= calWeekStart { snap.weekCost += c }
                if e.timestamp >= hourAgo { snap.burnRatePerHour += c }
                guard e.timestamp >= weekStart else { continue }
                let d = cal.startOfDay(for: e.timestamp)
                perDay[d, default: (0, 0)].0 += c; perDay[d]!.1 += e.tokens.total
                if e.timestamp >= today {
                    snap.todayTokens += e.tokens; snap.todayCost += c
                    perEditor[s.editor, default: (0, 0)].0 += c; perEditor[s.editor]!.1 += e.tokens.total
                }
            }
        }
        snap.todayByEditor = perEditor.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.tokens > $1.tokens }
        snap.last7Days = (0..<7).map { i in
            let d = cal.date(byAdding: .day, value: i, to: weekStart)!
            return (d, perDay[d]?.0 ?? 0, perDay[d]?.1 ?? 0)
        }
        snap.activeSessions = all.filter { now.timeIntervalSince($0.end) < 15 * 60 }.sorted { $0.end > $1.end }
        return snap
    }
}
