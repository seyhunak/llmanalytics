import Foundation
import Observation
import CoreServices

/// Owns all parsed sessions, keeps them fresh via FSEvents, and publishes analytics.
@MainActor
@Observable
final class DataStore {
    static let shared = DataStore()

    private(set) var sessions: [SessionSummary] = []
    private(set) var analytics = Analytics()
    private(set) var live = LiveSnapshot()
    private(set) var isLoading = false
    private(set) var lastUpdated: Date?
    private(set) var detectedEditors: Set<Editor> = []
    private(set) var lastChangeAt: Date?

    var filter = Filter() { didSet { if filter != oldValue { recompute() } } }

    private var cache: [String: (editor: Editor, file: SourceFile, sessions: [SessionSummary])] = [:]
    private var watcher: FileWatcher?
    private var pendingEditors: Set<Editor> = []
    private var debounce: Task<Void, Never>?
    private var tick: Timer?
    private var computeGeneration = 0

    private init() {}

    func start() {
        guard watcher == nil else { return }
        Task { await reload(editors: Set(Editor.allCases)) }
        let roots = Sources.all.flatMap { s in s.watchRoots.map { ($0, s.editor) } }
        watcher = FileWatcher(paths: roots.map(\.0)) { [weak self] changed in
            Task { @MainActor in self?.filesChanged(changed, roots: roots) }
        }
        // Fallback poll + keeps "active now" and today's numbers rolling over at midnight.
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.reload(editors: Set(Editor.allCases))
            }
        }
    }

    private func filesChanged(_ paths: [String], roots: [(String, Editor)]) {
        for p in paths {
            for (root, editor) in roots where p.hasPrefix(root) { pendingEditors.insert(editor) }
        }
        guard !pendingEditors.isEmpty else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled, let self else { return }
            let eds = self.pendingEditors; self.pendingEditors = []
            self.lastChangeAt = Date()
            await self.reload(editors: eds)
        }
    }

    func refresh() async { await reload(editors: Set(Editor.allCases), force: true) }

    /// Re-stat every file for the given editors and re-parse only those whose mtime/size changed.
    func reload(editors: Set<Editor>, force: Bool = false) async {
        isLoading = true
        let snapshot = cache
        let sources = Sources.all.filter { editors.contains($0.editor) }
        let result = await Task.detached(priority: .utility) { () -> [String: (Editor, SourceFile, [SessionSummary])] in
            var out: [String: (Editor, SourceFile, [SessionSummary])] = [:]
            await withTaskGroup(of: (Editor, [(String, SourceFile, [SessionSummary])]).self) { group in
                for src in sources {
                    group.addTask {
                        let files = src.discover()
                        var rows: [(String, SourceFile, [SessionSummary])] = []
                        let changed = files.filter { f in force || snapshot[f.path]?.file != f }
                        let unchanged = files.filter { f in !force && snapshot[f.path]?.file == f }
                        for f in unchanged { rows.append((f.path, f, snapshot[f.path]!.sessions)) }
                        // Parse changed files concurrently in small chunks.
                        let parsed = await withTaskGroup(of: (SourceFile, [SessionSummary]).self) { g in
                            for f in changed { g.addTask { (f, src.parse(f)) } }
                            var acc: [(SourceFile, [SessionSummary])] = []
                            for await r in g { acc.append(r) }
                            return acc
                        }
                        for (f, s) in parsed { rows.append((f.path, f, s)) }
                        return (src.editor, rows)
                    }
                }
                for await (editor, rows) in group { for (p, f, s) in rows { out[p] = (editor, f, s) } }
            }
            return out
        }.value

        // Every discovered file for these editors is in `result`; anything else vanished.
        let reloadedEditors = Set(sources.map(\.editor))
        cache = cache.filter { !reloadedEditors.contains($0.value.editor) }
        for (p, v) in result { cache[p] = (v.0, v.1, v.2) }

        var dedup: [String: SessionSummary] = [:]
        for entry in cache.values { for s in entry.sessions { dedup[s.id] = s } }
        sessions = dedup.values.sorted { $0.end > $1.end }
        detectedEditors = Set(sessions.map(\.editor))
        lastUpdated = Date()
        isLoading = false
        recompute()
    }

    private func recompute() {
        computeGeneration += 1
        let gen = computeGeneration
        let all = sessions, f = filter
        Task.detached(priority: .userInitiated) {
            let a = Analytics.compute(all: all, filter: f)
            let l = LiveSnapshot.compute(all: all)
            await MainActor.run { [weak self] in
                guard let self, gen == self.computeGeneration else { return }
                self.analytics = a
                self.live = l
            }
        }
    }

    func transcript(for s: SessionSummary) async -> [TranscriptMessage] {
        guard let src = Sources.source(for: s.editor) else { return [] }
        return await Task.detached(priority: .userInitiated) { src.transcript(for: s) }.value
    }

    func session(id: String) -> SessionSummary? { sessions.first { $0.id == id } }
}

/// Thin FSEvents wrapper delivering changed file paths.
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init?(paths: [String], handler: @escaping ([String]) -> Void) {
        self.handler = handler
        guard !paths.isEmpty else { return nil }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.handler(Array(arr.prefix(count)))
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
