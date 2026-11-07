import Testing
import Foundation
@testable import LLMAnalytics

@Suite struct CodexTests {
    static func ev(_ type: String, _ payload: [String: Any], at t: TimeInterval) -> String {
        line(["type": type, "timestamp": iso(t), "payload": payload])
    }
    static func tokens(total: Int, input: Int, cached: Int, output: Int) -> [String: Any] {
        let u: [String: Any] = ["input_tokens": input, "cached_input_tokens": cached, "output_tokens": output,
                                "reasoning_output_tokens": 5, "total_tokens": total]
        return ["type": "token_count", "info": ["total_token_usage": u, "last_token_usage": u],
                "rate_limits": ["plan_type": "plus",
                                "primary": ["used_percent": 42.0, "window_minutes": 300, "resets_at": 1_900_000_000],
                                "secondary": ["used_percent": 10.0, "window_minutes": 10080, "resets_at": 1_900_500_000]]]
    }
    static var fixture: String {
        ev("session_meta", ["id": "codex-1", "cwd": "/tmp/repo"], at: -100)
            + ev("turn_context", ["model": "gpt-5.6-terra"], at: -99)
            + ev("event_msg", ["type": "user_message", "message": "fix the bug"], at: -98)
            + ev("event_msg", ["type": "user_message", "message": "<environment_context>…"], at: -98)
            + ev("response_item", ["type": "function_call", "name": "shell", "arguments": "{}"], at: -97)
            + ev("event_msg", tokens(total: 1100, input: 1000, cached: 800, output: 100), at: -96)
            + ev("event_msg", tokens(total: 1100, input: 1000, cached: 800, output: 100), at: -95) // duplicate snapshot
            + ev("event_msg", ["type": "agent_message", "message": "done"], at: -94)
    }

    @Test func parsesTokensAndSkipsDuplicateSnapshots() throws {
        let dir = TempDir()
        let path = dir.write("sessions/2026/11/07/rollout-1.jsonl", Self.fixture)
        let s = try #require(CodexSource().parse(file(path)).first)
        #expect(s.nativeID == "codex-1")
        #expect(s.title == "fix the bug")
        #expect(s.userMessages == 1)
        #expect(s.assistantMessages == 1)
        #expect(s.events.count == 1)
        #expect(s.tokens.input == 200)
        #expect(s.tokens.cacheRead == 800)
        #expect(s.tools == ["shell": 1])
        #expect(s.primaryModel == "gpt-5.6-terra")
    }

    @Test func readsLatestRateLimitsOffline() throws {
        let dir = TempDir()
        dir.write("sessions/2026/11/07/rollout-1.jsonl", Self.fixture)
        setenv("CODEX_HOME", dir.url.path, 1)
        defer { unsetenv("CODEX_HOME") }
        let rl = try #require(CodexSource().latestRateLimits())
        #expect(rl.plan == "plus")
        #expect(rl.primary?.used == 42)
        #expect(rl.primary?.windowMinutes == 300)
        #expect(rl.secondary?.windowMinutes == 10080)
    }
}

@Suite struct CopilotTests {
    @Test func cliSessionCountsRequestsAndTools() throws {
        let dir = TempDir()
        func e(_ type: String, _ data: [String: Any], _ t: TimeInterval) -> String { line(["type": type, "data": data, "timestamp": iso(t)]) }
        let path = dir.write("session-state/abc/events.jsonl",
            e("session.start", ["sessionId": "abc", "context": ["cwd": "/tmp/app"], "startTime": iso(-60)], -60)
            + e("user.message", ["content": "make it responsive"], -50)
            + e("assistant.message", ["content": "", "toolRequests": []], -45)
            + e("tool.execution_start", ["toolName": "report_intent"], -44)
            + e("tool.execution_start", ["toolName": "edit"], -43)
            + e("tool.execution_complete", ["model": "claude-haiku-4.5"], -42))
        let s = try #require(CopilotCLISource().parse(file(path)).first)
        #expect(s.nativeID == "abc")
        #expect(s.project == "/tmp/app")
        #expect(s.userMessages == 1)
        #expect(s.tools == ["edit": 1])
        #expect(s.primaryModel == "claude-haiku-4.5")
    }

    @Test func vscodeJSONLPatchesRebuildSession() throws {
        let dir = TempDir()
        let req: [String: Any] = ["timestamp": 1_780_000_000_000, "modelId": "copilot/gpt-5-mini",
                                  "message": ["text": "add an image"], "response": [["value": "Done."], ["toolId": "copilot_readFile"]]]
        let path = dir.write("ws/chatSessions/s1.jsonl",
            line(["kind": 0, "v": ["sessionId": "s1", "creationDate": 1_780_000_000_000, "requests": []]])
            + line(["kind": 1, "k": ["customTitle"], "v": "Add image"])
            + line(["kind": 2, "k": ["requests"], "v": [req]])
            + line(["kind": 1, "k": ["requests", 0, "completionTokens"], "v": 535]))
        let s = try #require(CopilotVSCodeSource().parse(file(path)).first)
        #expect(s.title == "Add image")
        #expect(s.userMessages == 1)
        #expect(s.tools == ["readFile": 1])
        #expect(s.tokens.output == 535)
        #expect(s.primaryModel == "gpt-5-mini")
    }

    @Test func duplicateCopiesAreNotDoubleCounted() {
        let older = SessionSummary(nativeID: "s1", editor: .copilotVSCode, sourcePath: "/a.json", title: "t", project: "",
                                   start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 10), userMessages: 2)
        let newer = SessionSummary(nativeID: "s1", editor: .copilotVSCode, sourcePath: "/a.jsonl", title: "t", project: "",
                                   start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 20), userMessages: 3)
        let merged = Sources.merge([older, newer])
        #expect(merged.count == 1)
        #expect(merged[0].userMessages == 3)
        #expect(merged[0].sourcePath == "/a.jsonl")
    }
}

@Suite struct GeminiTests {
    @Test func parsesChatFile() throws {
        let dir = TempDir()
        let json: [String: Any] = [
            "sessionId": "g1", "projectHash": "abcdef1234", "startTime": iso(-100), "lastUpdated": iso(-10),
            "messages": [
                ["type": "user", "timestamp": iso(-100), "content": "explain this repo"],
                ["type": "gemini", "timestamp": iso(-90), "content": "It is…", "model": "gemini-2.5-pro",
                 "tokens": ["input": 1000, "output": 200, "cached": 600, "thoughts": 50], "toolCalls": [["name": "read_file"]]],
            ]]
        let path = dir.write("tmp/abc/chats/session-1.json", String(data: try JSONSerialization.data(withJSONObject: json), encoding: .utf8)!)
        let s = try #require(GeminiSource().parse(file(path)).first)
        #expect(s.userMessages == 1 && s.assistantMessages == 1)
        #expect(s.tokens.input == 400 && s.tokens.cacheRead == 600 && s.tokens.output == 250)
        #expect(s.tools == ["read_file": 1])
        #expect(s.cost > 0)
    }
}

@Suite struct DatabaseSourceTests {
    static func makeOpenCode(_ path: String) -> WritableDB {
        let db = WritableDB(path)
        db.exec("CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, directory TEXT, model TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER)")
        db.exec("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
        db.exec("CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT, time_created INTEGER, time_updated INTEGER, data TEXT)")
        return db
    }
    static let now = Int(Date().timeIntervalSince1970 * 1000)

    static func addMessage(_ db: WritableDB, id: String, role: String, t: Int, cost: Double = 0.5) {
        let data = role == "user" ? #"{"role":"user"}"#
            : #"{"role":"assistant","modelID":"claude-sonnet-5-5","cost":\#(cost),"tokens":{"input":100,"output":50,"reasoning":10,"cache":{"read":1000,"write":0}}}"#
        db.exec("INSERT OR REPLACE INTO message VALUES (?,?,?,?,?)", [id, "s1", t, t, data])
    }

    @Test func openCodeIncrementalMatchesFull() throws {
        let dir = TempDir()
        let path = dir.url.appendingPathComponent("opencode.db").path
        let db = Self.makeOpenCode(path)
        db.exec("INSERT INTO session VALUES ('s1','Fix tests','/tmp/oc','claude-sonnet-5-5',?,?,NULL)", [Self.now, Self.now])
        Self.addMessage(db, id: "m1", role: "user", t: Self.now)
        Self.addMessage(db, id: "m2", role: "assistant", t: Self.now + 1)
        db.exec("INSERT INTO part VALUES ('p1','m2','s1',?,?,?)", [Self.now + 1, Self.now + 1, #"{"type":"tool","tool":"bash"}"#])

        let src = OpenCodeSource()
        let (first, state) = src.parse(file(path), previous: nil)
        #expect(first.first?.events.count == 1)

        Self.addMessage(db, id: "m3", role: "user", t: Self.now + 2)
        Self.addMessage(db, id: "m4", role: "assistant", t: Self.now + 3, cost: 0.25)
        Self.addMessage(db, id: "m2", role: "assistant", t: Self.now + 4, cost: 0.75)     // updated in place
        db.exec("UPDATE message SET time_created=? WHERE id='m2'", [Self.now + 1])
        let inc = try #require(src.parse(file(path), previous: state).sessions.first)
        let full = try #require(src.parse(file(path), previous: nil).sessions.first)
        #expect(inc.userMessages == 2 && inc.assistantMessages == 2)
        #expect(abs(inc.cost - 1.0) < 1e-9)                 // 0.75 replaced 0.5, plus 0.25
        #expect(inc.cost == full.cost)
        #expect(inc.tokens == full.tokens)
        #expect(inc.tools == ["bash": 1])
        #expect(inc.project == "/tmp/oc")
    }

    @Test func archivedOpenCodeSessionsDisappear() {
        let dir = TempDir()
        let path = dir.url.appendingPathComponent("opencode.db").path
        let db = Self.makeOpenCode(path)
        db.exec("INSERT INTO session VALUES ('s1','t','/tmp','m',?,?,NULL)", [Self.now, Self.now])
        Self.addMessage(db, id: "m1", role: "user", t: Self.now)
        let (first, state) = OpenCodeSource().parse(file(path), previous: nil)
        #expect(first.count == 1)
        db.exec("UPDATE session SET time_archived=?, time_updated=? WHERE id='s1'", [Self.now + 5, Self.now + 5])
        #expect(OpenCodeSource().parse(file(path), previous: state).sessions.isEmpty)
    }

    @Test func cursorComposerWithBubbles() throws {
        let dir = TempDir()
        let path = dir.url.appendingPathComponent("state.vscdb").path
        let db = WritableDB(path)
        db.exec("CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
        db.exec("INSERT INTO cursorDiskKV VALUES (?,?)", ["composerData:c1",
            #"{"composerId":"c1","name":"Refactor auth","createdAt":\#(Self.now),"lastUpdatedAt":\#(Self.now + 5000),"fullConversationHeadersOnly":[{"bubbleId":"b1"},{"bubbleId":"b2"}]}"#])
        db.exec("INSERT INTO cursorDiskKV VALUES (?,?)", ["bubbleId:c1:b1", #"{"type":1,"text":"refactor the auth module"}"#])
        db.exec("INSERT INTO cursorDiskKV VALUES (?,?)", ["bubbleId:c1:b2",
            #"{"type":2,"text":"Done","tokenCount":{"inputTokens":1200,"outputTokens":300},"toolFormerData":{"name":"edit_file"}}"#])
        let src = CursorSource()
        let s = try #require(src.parse(file(path)).first)
        #expect(s.title == "Refactor auth")
        #expect(s.userMessages == 1 && s.assistantMessages == 1)
        #expect(s.tokens.input == 1200 && s.tokens.output == 300)
        #expect(s.tools == ["edit_file": 1])
        let t = src.transcript(for: s)
        #expect(t.map(\.role) == [.user, .tool])
    }
}
