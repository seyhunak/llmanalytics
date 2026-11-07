import Testing
import Foundation
@testable import LLMAnalytics

@Suite struct ClaudeCodeTests {
    let src = ClaudeCodeSource()
    static let sid = "11111111-2222-3333-4444-555555555555"

    static func user(_ text: Any, at t: TimeInterval, meta: Bool = false) -> String {
        var o: [String: Any] = ["type": "user", "sessionId": sid, "cwd": "/tmp/proj", "timestamp": iso(t),
                                "message": ["role": "user", "content": text]]
        if meta { o["isMeta"] = true }
        return line(o)
    }

    /// Claude Code writes one line per content block, each repeating the message's usage.
    static func assistant(id: String, blocks: [[String: Any]], at t: TimeInterval, model: String = "claude-opus-5-5") -> String {
        let usage: [String: Any] = ["input_tokens": 10, "output_tokens": 100, "cache_read_input_tokens": 1000,
                                    "cache_creation_input_tokens": 500,
                                    "cache_creation": ["ephemeral_5m_input_tokens": 100, "ephemeral_1h_input_tokens": 400]]
        return blocks.map { b in
            line(["type": "assistant", "sessionId": sid, "cwd": "/tmp/proj", "timestamp": iso(t),
                  "message": ["id": id, "model": model, "role": "assistant", "content": [b], "usage": usage]])
        }.joined()
    }

    static var fixture: String {
        user("Build me a dashboard", at: -300)
            + user("<command-name>/clear</command-name>", at: -299)                    // injected, ignored
            + user("caveat text", at: -298, meta: true)                              // meta, ignored
            + assistant(id: "msg_1", blocks: [["type": "thinking", "thinking": ""],
                                              ["type": "text", "text": "Sure"],
                                              ["type": "tool_use", "id": "tu_1", "name": "Bash", "input": ["command": "ls"]]], at: -290)
            + user([["type": "tool_result", "tool_use_id": "tu_1", "content": "ok"]], at: -289) // tool result, not a prompt
            + assistant(id: "msg_2", blocks: [["type": "tool_use", "id": "tu_2", "name": "mcp__github__create_pr", "input": [:]]], at: -280)
            + line(["type": "custom-title", "customTitle": "Dashboard work", "sessionId": sid])
            + assistant(id: "msg_3", blocks: [["type": "text", "text": "x"]], at: -270, model: "<synthetic>")
    }

    @Test func parsesSessionAndDeduplicatesStreamedUsage() throws {
        let dir = TempDir()
        let path = dir.write("proj/\(Self.sid).jsonl", Self.fixture)
        let s = try #require(src.parse(file(path)).first)
        #expect(s.nativeID == Self.sid)
        #expect(s.title == "Dashboard work")
        #expect(s.project == "/tmp/proj")
        #expect(s.userMessages == 1)
        #expect(s.assistantMessages == 2)                 // synthetic message skipped
        #expect(s.events.count == 2)                      // msg_1's three lines count once
        #expect(s.tokens.output == 200)
        #expect(s.tokens.cacheWrite1h == 800)
        #expect(s.tokens.cacheWrite == 200)
        #expect(s.tools == ["Bash": 1, "mcp:github": 1])
        let perMessage = Pricing.cost(model: "claude-opus-5-5", tokens: TokenUsage(input: 10, output: 100, cacheRead: 1000, cacheWrite: 100, cacheWrite1h: 400))
        #expect(abs(s.cost - 2 * perMessage) < 1e-12)
    }

    @Test func incrementalParseMatchesFullParse() throws {
        let dir = TempDir()
        let lines = Self.fixture.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) + "\n" }
        let path = dir.write("proj/\(Self.sid).jsonl", lines[..<4].joined())
        var (_, state) = src.parse(file(path), previous: nil)
        // Append the rest, including a half-written last line.
        let rest = lines[4...].joined()
        dir.append(path, String(rest.dropLast(20)))
        (_, state) = src.parse(file(path), previous: state)
        dir.append(path, String(rest.suffix(20)))
        let incremental = try #require(src.parse(file(path), previous: state).sessions.first)
        let full = try #require(src.parse(file(path)).first)
        #expect(incremental.tokens == full.tokens)
        #expect(incremental.events.count == full.events.count)
        #expect(incremental.userMessages == full.userMessages)
        #expect(incremental.tools == full.tools)
        #expect(incremental.title == full.title)
    }

    @Test func truncatedFileStartsOver() throws {
        let dir = TempDir()
        let path = dir.write("proj/\(Self.sid).jsonl", Self.fixture)
        let (_, state) = src.parse(file(path), previous: nil)
        dir.write("proj/\(Self.sid).jsonl", Self.user("fresh start", at: -10))
        let s = try #require(src.parse(file(path), previous: state).sessions.first)
        #expect(s.userMessages == 1)
        #expect(s.events.isEmpty)
    }

    @Test func subagentRunsFoldIntoParent() throws {
        let dir = TempDir()
        let main = dir.write("proj/\(Self.sid).jsonl", Self.fixture)
        let sub = dir.write("proj/\(Self.sid)/subagents/agent-abc.jsonl",
                            Self.user("Research X for the parent", at: -200)
                            + Self.assistant(id: "msg_s1", blocks: [["type": "tool_use", "id": "tu_s1", "name": "WebFetch", "input": [:]]], at: -190))
        let subSession = try #require(src.parse(file(sub)).first)
        #expect(subSession.isPartial)
        #expect(subSession.nativeID == Self.sid)
        #expect(subSession.userMessages == 0)             // parent-agent prompts aren't human turns

        let merged = Sources.merge(src.parse(file(main)) + [subSession])
        #expect(merged.count == 1)
        let m = try #require(merged.first)
        #expect(!m.isPartial)
        #expect(m.title == "Dashboard work")
        #expect(m.sourcePath == main)
        #expect(m.userMessages == 1)
        #expect(m.events.count == 3)
        #expect(m.tools["WebFetch"] == 1)
        #expect(m.tools["Bash"] == 1)
    }

    @Test func transcriptIncludesTextToolsAndResults() {
        let dir = TempDir()
        let path = dir.write("proj/\(Self.sid).jsonl", Self.fixture)
        let s = src.parse(file(path))[0]
        let t = src.transcript(for: s)
        #expect(t.first?.role == .user)
        #expect(t.contains { $0.role == .assistant && $0.text == "Sure" })
        #expect(t.contains { $0.role == .tool && $0.toolName == "Bash" })
        #expect(t.contains { $0.role == .tool && $0.text == "ok" })
        #expect(!t.contains { $0.text.contains("/clear") })
    }
}
