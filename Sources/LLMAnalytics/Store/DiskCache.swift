import Foundation

/// Parsed session summaries persisted between launches, keyed by file path + mtime + size,
/// so a cold start only re-parses files that changed while the app was closed.
enum DiskCache {
    /// Bump whenever parser output changes shape or meaning; old caches are then ignored.
    static let version = 2

    private struct Entry: Codable {
        let editor: Editor
        let path: String
        let mtime: Date
        let size: Int64
        let sessions: [SessionSummary]
    }
    private struct Payload: Codable {
        let version: Int
        let entries: [Entry]
    }

    static var url: URL { AppPaths.supportDir.appendingPathComponent("sessions-cache.json") }

    static func load(from url: URL = url) -> [String: DataStore.CacheEntry] {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version else { return [:] }
        var out: [String: DataStore.CacheEntry] = [:]
        for e in payload.entries {
            out[e.path] = .init(editor: e.editor, file: SourceFile(path: e.path, mtime: e.mtime, size: e.size),
                                sessions: e.sessions, state: nil)
        }
        return out
    }

    static func save(_ entries: [String: DataStore.CacheEntry], to url: URL = url) {
        let payload = Payload(version: version, entries: entries.values.map {
            Entry(editor: $0.editor, path: $0.file.path, mtime: $0.file.mtime, size: $0.file.size, sessions: $0.sessions)
        })
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
