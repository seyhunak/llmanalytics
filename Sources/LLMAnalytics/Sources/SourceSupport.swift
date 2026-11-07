import Foundation
import SQLite3

/// A reader for one tool's local history.
protocol UsageSource: Sendable {
    var editor: Editor { get }
    /// Directories to watch with FSEvents for live updates.
    var watchRoots: [String] { get }
    /// Every file/db this source reads; cheap (stat only).
    func discover() -> [SourceFile]
    /// Parse one file into zero or more sessions.
    func parse(_ file: SourceFile) -> [SessionSummary]
    /// Incremental variant: `previous` is the state returned for this file last time.
    /// Sources that can resume (append-only JSONL, databases with update timestamps) override it.
    func parse(_ file: SourceFile, previous: ParseState?) -> (sessions: [SessionSummary], state: ParseState?)
    /// Full conversation for the transcript viewer (loaded on demand).
    func transcript(for session: SessionSummary) -> [TranscriptMessage]
}

extension UsageSource {
    func parse(_ file: SourceFile, previous: ParseState?) -> (sessions: [SessionSummary], state: ParseState?) {
        (parse(file), nil)
    }
}

/// Opaque per-file parser state kept between reloads.
protocol ParseState: Sendable {}

enum Sources {
    static let all: [UsageSource] = [
        ClaudeCodeSource(), CodexSource(), CursorSource(), CopilotCLISource(),
        CopilotVSCodeSource(), GeminiSource(), OpenCodeSource(),
        GeminiSource(editor: .qwen, root: AppPaths.expand(".qwen/tmp"), defaultModel: "qwen3-coder-plus"),
        ContinueSource(), KiroSource(), ClineSource(), AiderSource(), FactorySource(),
    ]
    static func source(for editor: Editor) -> UsageSource? { all.first { $0.editor == editor } }

    /// Parse + post-process (project folders resolved to their git root). Used by the store,
    /// diagnostics and tests so they all see identical results.
    static func parse(_ src: UsageSource, _ file: SourceFile, previous: ParseState?) -> (sessions: [SessionSummary], state: ParseState?) {
        var (sessions, state) = src.parse(file, previous: previous)
        for i in sessions.indices { sessions[i].project = ProjectResolver.root(for: sessions[i].project) }
        return (sessions, state)
    }

    /// Sessions that share an id become one: subagent fragments are summed into their parent,
    /// while duplicate copies of the same session are de-duplicated.
    static func merge(_ sessions: [SessionSummary]) -> [SessionSummary] {
        var byID: [String: SessionSummary] = [:]
        for s in sessions {
            guard let existing = byID[s.id] else { byID[s.id] = s; continue }
            if existing.isPartial || s.isPartial {
                byID[s.id] = .merged(existing, s)
            } else if (s.end, s.messageCount) > (existing.end, existing.messageCount) {
                // Same session stored twice (VS Code keeps .json and .jsonl copies): keep the newest.
                byID[s.id] = s
            }
        }
        return Array(byID.values)
    }
}

// MARK: - Incremental JSONL

/// Folds JSONL objects into session data. Value type so a saved state can be resumed safely.
protocol LineAccumulator: Sendable {
    init()
    static func prefilter(_ line: Data) -> Bool
    mutating func consume(_ obj: [String: Any])
    func build(file: SourceFile) -> [SessionSummary]
}

struct JSONLState<A: LineAccumulator>: ParseState {
    let offset: Int
    let accumulator: A
}

enum IncrementalJSONL {
    /// Resumes from the previous byte offset when the file only grew; otherwise starts over.
    static func parse<A: LineAccumulator>(_ file: SourceFile, previous: ParseState?, as _: A.Type) -> (sessions: [SessionSummary], state: ParseState?) {
        var acc = A()
        var offset = 0
        if let p = previous as? JSONLState<A>, Int64(p.offset) <= file.size {
            acc = p.accumulator; offset = p.offset
        }
        let end = FS.eachJSONLine(file.path, from: offset, prefilter: A.prefilter) { acc.consume($0) }
        return (acc.build(file: file), JSONLState(offset: end, accumulator: acc))
    }
}

// MARK: - Projects

enum ProjectResolver {
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let lock = NSLock()

    /// Walks up to the enclosing git repository. Linked worktrees map to their main repo.
    /// Paths outside any repo (or that no longer exist) are returned unchanged.
    static func root(for path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        lock.lock(); if let hit = cache[path] { lock.unlock(); return hit }; lock.unlock()
        let resolved = resolve(path)
        lock.lock(); cache[path] = resolved; lock.unlock()
        return resolved
    }

    static func resetCache() { lock.lock(); cache = [:]; lock.unlock() }

    private static func resolve(_ path: String) -> String {
        let home = AppPaths.home.path
        var dir = (path as NSString).standardizingPath
        while dir != "/" && dir != home && !dir.isEmpty {
            let git = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: git, isDirectory: &isDir) {
                if isDir.boolValue { return dir }
                // Worktree / submodule: ".git" is a file containing "gitdir: <path>"
                if let text = try? String(contentsOfFile: git, encoding: .utf8),
                   let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let target = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    if let r = target.range(of: "/.git/worktrees/") { return String(target[..<r.lowerBound]) }
                }
                return dir
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return path
    }
}

// MARK: - File helpers

enum FS {
    static func stat(_ path: String) -> SourceFile? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let m = a[.modificationDate] as? Date else { return nil }
        return SourceFile(path: path, mtime: m, size: (a[.size] as? NSNumber)?.int64Value ?? 0)
    }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Recursively find files under `root` whose name satisfies `match`.
    static func find(_ root: String, maxDepth: Int = 8, match: (String) -> Bool) -> [SourceFile] {
        let url = URL(fileURLWithPath: root)
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [SourceFile] = []
        for case let f as URL in en {
            if en.level > maxDepth { en.skipDescendants(); continue }
            guard match(f.lastPathComponent),
                  let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true else { continue }
            out.append(SourceFile(path: f.path, mtime: v.contentModificationDate ?? .distantPast, size: Int64(v.fileSize ?? 0)))
        }
        return out
    }

    /// Calls `body` with each JSON object line of a JSONL file, starting at byte `offset`.
    /// Only newline-terminated lines are consumed (a line still being written is left for next
    /// time); returns the offset just past the last consumed line. `prefilter` lets callers skip
    /// lines cheaply on raw bytes before paying for JSON parsing.
    @discardableResult
    static func eachJSONLine(_ path: String, from offset: Int = 0, prefilter: ((Data) -> Bool)? = nil,
                             _ body: ([String: Any]) -> Void) -> Int {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return offset }
        guard offset < data.count else { return min(offset, data.count) }
        let nl = UInt8(ascii: "\n")
        var start = data.startIndex + offset
        var consumedTo = offset
        while start < data.endIndex {
            guard let end = data[start...].firstIndex(of: nl) else { break }
            if end > start {
                let line = data[start..<end]
                if prefilter?(line) ?? true,
                   let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    body(obj)
                }
            }
            start = end + 1
            consumedTo = start - data.startIndex
        }
        return consumedTo
    }

    static func readJSON(_ path: String) -> Any? {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONSerialization.jsonObject(with: d)
    }
}

extension Data {
    func containsASCII(_ s: String) -> Bool { range(of: Data(s.utf8)) != nil }
}

// MARK: - Dates

enum Dates {
    nonisolated(unsafe) private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let lock = NSLock()

    static func parse(_ any: Any?) -> Date? {
        switch any {
        case let s as String:
            lock.lock(); defer { lock.unlock() }
            return isoFrac.date(from: s) ?? iso.date(from: s)
        case let n as NSNumber:
            let v = n.doubleValue
            if v > 1e14 { return Date(timeIntervalSince1970: v / 1_000_000) } // µs
            if v > 1e11 { return Date(timeIntervalSince1970: v / 1000) }      // ms
            if v > 1e8 { return Date(timeIntervalSince1970: v) }              // s
            return nil
        default: return nil
        }
    }
}

// MARK: - JSON access sugar

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
    func dbl(_ k: String) -> Double? { (self[k] as? NSNumber)?.doubleValue }
    func obj(_ k: String) -> [String: Any]? { self[k] as? [String: Any] }
    func arr(_ k: String) -> [Any]? { self[k] as? [Any] }
}

enum Str {
    static func clean(_ s: String, max: Int = 120) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return one.count > max ? String(one.prefix(max)) + "…" : one
    }

    /// Prompts that tools inject (system reminders, env context) are not real user turns.
    static func looksInjected(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("<environment_context") || t.hasPrefix("<user_instructions")
            || t.hasPrefix("<command-") || t.hasPrefix("<local-command") || t.hasPrefix("<system-reminder")
            || t.hasPrefix("Caveat:") || t.hasPrefix("<permissions") || t.hasPrefix("# AGENTS.md")
            || t.hasPrefix("<skills_instructions") || t.isEmpty
    }
}

// MARK: - SQLite (read-only)

final class SQLiteDB {
    private var db: OpaquePointer?

    init?(path: String) {
        guard FS.exists(path) else { return nil }
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) != SQLITE_OK {
            sqlite3_close(db); return nil
        }
        sqlite3_busy_timeout(db, 1500)
    }
    deinit { sqlite3_close(db) }

    /// Each row as an array of optional strings/ints (as String).
    func rows(_ sql: String, _ binds: [String] = []) -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), b, -1, transient) }
        var out: [[String?]] = []
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String?] = []
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_NULL: row.append(nil)
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c) {
                        row.append(String(data: Data(bytes: p, count: len), encoding: .utf8))
                    } else { row.append(nil) }
                default:
                    row.append(sqlite3_column_text(stmt, c).map { String(cString: $0) })
                }
            }
            out.append(row)
        }
        return out
    }

    func hasTable(_ name: String) -> Bool {
        !rows("SELECT name FROM sqlite_master WHERE type='table' AND name=?", [name]).isEmpty
    }
}

func parseJSONObject(_ s: String?) -> [String: Any]? {
    guard let s, let d = s.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
}
