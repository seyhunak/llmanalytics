import Foundation
import SQLite3
@testable import LLMAnalytics

/// A throwaway directory per test.
final class TempDir {
    let url: URL
    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("llma-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func write(_ rel: String, _ text: String) -> String {
        let path = url.appendingPathComponent(rel).path
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    func append(_ path: String, _ text: String) {
        let h = FileHandle(forWritingAtPath: path)!
        h.seekToEndOfFile(); h.write(Data(text.utf8)); try! h.close()
    }

    func mkdir(_ rel: String) -> String {
        let path = url.appendingPathComponent(rel).path
        try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
}

func file(_ path: String) -> SourceFile { FS.stat(path)! }

/// JSON-encode a dictionary as one JSONL line.
func line(_ obj: [String: Any]) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)! + "\n"
}

/// Minimal writable SQLite helper for building fixture databases.
final class WritableDB {
    private var db: OpaquePointer?
    init(_ path: String) { precondition(sqlite3_open(path, &db) == SQLITE_OK) }
    deinit { sqlite3_close(db) }
    func exec(_ sql: String, _ binds: [Any?] = []) {
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case let v as Int: sqlite3_bind_int64(stmt, idx, sqlite3_int64(v))
            case let v as String: sqlite3_bind_text(stmt, idx, v, -1, transient)
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        precondition(sqlite3_step(stmt) == SQLITE_DONE, String(cString: sqlite3_errmsg(db)))
    }
}

func iso(_ secondsFromNow: TimeInterval) -> String {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: Date().addingTimeInterval(secondsFromNow))
}
