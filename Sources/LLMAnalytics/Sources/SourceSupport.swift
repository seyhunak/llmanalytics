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
    /// Full conversation for the transcript viewer (loaded on demand).
    func transcript(for session: SessionSummary) -> [TranscriptMessage]
}

enum Sources {
    static let all: [UsageSource] = [
        ClaudeCodeSource(), CodexSource(), CursorSource(), CopilotCLISource(),
        CopilotVSCodeSource(), GeminiSource(), OpenCodeSource(),
    ]
    static func source(for editor: Editor) -> UsageSource? { all.first { $0.editor == editor } }
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

    /// Calls `body` with each JSON object line of a JSONL file. `prefilter` lets callers skip
    /// lines cheaply (on raw bytes) before paying for JSON parsing.
    static func eachJSONLine(_ path: String, prefilter: ((Data) -> Bool)? = nil, _ body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else { return }
        var start = data.startIndex
        let nl = UInt8(ascii: "\n")
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: nl) ?? data.endIndex
            if end > start {
                let line = data[start..<end]
                if prefilter?(line) ?? true,
                   let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    body(obj)
                }
            }
            start = end + 1
        }
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
