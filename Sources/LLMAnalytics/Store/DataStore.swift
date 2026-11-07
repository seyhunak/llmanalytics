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

    private var cache: [String: CacheEntry] = [:]
    private var watcher: FileWatcher?
    private var pendingEditors: Set<Editor> = []
    private var debounce: Task<Void, Never>?
    private var tick: Timer?
    private var computeGeneration = 0
    private var reloading = false
    private var queued: (editors: Set<Editor>, force: Bool)?
    private var saveTask: Task<Void, Never>?

    struct CacheEntry: Sendable {
        let editor: Editor
        let file: SourceFile
        let sessions: [SessionSummary]
        let state: ParseState?
    }

    private init() {}

    func start() {
        guard watcher == nil else { return }
        Task {
            // Show the last known numbers instantly, then catch up with what changed on disk.
            let saved = await Task.detached(priority: .userInitiated) { DiskCache.load() }.value
            if cache.isEmpty, !saved.isEmpty {
                cache = saved
                publish()
            }
            await reload(editors: Set(Editor.allCases))
        }
        let roots = Sources.all.flatMap { s in s.watchRoots.map { ($0, s.editor) } }
        watcher = FileWatcher(paths: roots.map(\.0)) { [weak self] changed in
            Task { @MainActor in self?.filesChanged(changed, roots: roots) }
        }
        // Fallback poll; also rolls "today" and "active now" over without file changes.
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reload(editors: Set(Editor.allCases)) }
        }
    }

    private func filesChanged(_ paths: [String], roots: [(String, Editor)]) {
        for p in paths {
            for (root, editor) in roots where p.hasPrefix(root) { pendingEditors.insert(editor) }
        }
        guard !pendingEditors.isEmpty else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            let eds = self.pendingEditors; self.pendingEditors = []
            self.lastChangeAt = Date()
            await self.reload(editors: eds)
        }
    }

    /// Manual refresh: re-parses everything from scratch (drops incremental state).
    func refresh() async {
        ProjectResolver.resetCache()
        await reload(editors: Set(Editor.allCases), force: true)
    }

    /// Re-stat every file for the given editors and parse only what changed — appended JSONL is
    /// read from the previous offset, databases from their last update timestamp.
    /// Overlapping calls are coalesced so two parses of the same file never race.
    func reload(editors: Set<Editor>, force: Bool = false) async {
        if reloading {
            let q = queued
            queued = ((q?.editors ?? []).union(editors), (q?.force ?? false) || force)
            return
        }
        reloading = true
        isLoading = true
        let snapshot = cache
        let sources = Sources.all.filter { editors.contains($0.editor) }
        let result = await Task.detached(priority: .utility) { () -> [String: CacheEntry] in
            await withTaskGroup(of: [CacheEntry].self) { group in
                for src in sources {
                    group.addTask {
                        await withTaskGroup(of: CacheEntry.self) { files in
                            for f in src.discover() {
                                let prev = snapshot[f.path]
                                if !force, let prev, prev.file == f {
                                    files.addTask { prev }
                                    continue
                                }
                                files.addTask {
                                    let (sessions, state) = Sources.parse(src, f, previous: force ? nil : prev?.state)
                                    return CacheEntry(editor: src.editor, file: f, sessions: sessions, state: state)
                                }
                            }
                            var out: [CacheEntry] = []
                            for await e in files { out.append(e) }
                            return out
                        }
                    }
                }
                var out: [String: CacheEntry] = [:]
                for await entries in group { for e in entries { out[e.file.path] = e } }
                return out
            }
        }.value

        // Every discovered file for these editors is in `result`; anything else vanished.
        let reloaded = Set(sources.map(\.editor))
        let changed = force || result.contains { snapshot[$0.key]?.file != $0.value.file }
            || snapshot.contains { reloaded.contains($0.value.editor) && result[$0.key] == nil }
        cache = cache.filter { !reloaded.contains($0.value.editor) }
        for (p, e) in result { cache[p] = e }
        lastUpdated = Date()
        if changed || analytics.sessions.isEmpty { publish(); scheduleSave() } else { recomputeLiveOnly() }
        isLoading = false
        reloading = false

        if let q = queued {
            queued = nil
            await reload(editors: q.editors, force: q.force)
        }
    }

    private func publish() {
        sessions = Sources.merge(cache.values.flatMap(\.sessions)).sorted { $0.end > $1.end }
        detectedEditors = Set(sessions.map(\.editor))
        recompute()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let entries = cache
        saveTask = Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            DiskCache.save(entries)
        }
    }

    /// Nothing on disk changed: only the time-based numbers ("today", "active now") can move.
    private func recomputeLiveOnly() {
        let all = sessions
        Task.detached(priority: .utility) {
            let l = LiveSnapshot.compute(all: all)
            await MainActor.run { [weak self] in
                self?.live = l
                AlertCenter.shared.evaluate(live: l)
            }
        }
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
                AlertCenter.shared.evaluate(live: l)
            }
        }
    }

    /// Screenshot mode: show synthetic sessions instead of reading anything from disk.
    func loadDemo(_ demo: [SessionSummary]) {
        sessions = demo.sorted { $0.end > $1.end }
        detectedEditors = Set(demo.map(\.editor))
        lastUpdated = Date()
        recompute()
    }

    func transcript(for s: SessionSummary) async -> [TranscriptMessage] {
        if s.sourcePath == "demo" { return DemoData.transcript(for: s) }
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
