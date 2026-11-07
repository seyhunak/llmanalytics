import Foundation
import Testing
@testable import LLMAnalytics

private func json(_ o: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!
}

@Suite struct ExtraSourceTests {
    @Test func qwenReusesGeminiFormat() throws {
        let dir = TempDir()
        let path = dir.write("tmp/h/chats/session-1.json", json([
            "sessionId": "q1", "messages": [
                ["type": "user", "timestamp": iso(-60), "content": "hi"],
                ["type": "qwen", "timestamp": iso(-50), "content": "hello", "model": "qwen3-coder-plus",
                 "tokens": ["input": 100, "output": 10, "cached": 0, "thoughts": 0]],
            ]]))
        let src = GeminiSource(editor: .qwen, root: dir.url.path + "/tmp", defaultModel: "qwen3-coder-plus")
        #expect(src.discover().count == 1)
        let s = try #require(src.parse(file(path)).first)
        #expect(s.id == "qwen:q1" && s.assistantMessages == 1 && s.cost > 0)
    }

    @Test func continueAttachesTokensToOpenChat() throws {
        let dir = TempDir()
        let created = Date().addingTimeInterval(-600)
        dir.write("sessions/sessions.json", json([["sessionId": "c1", "title": "Fix tests",
                                                    "dateCreated": String(Int(created.timeIntervalSince1970 * 1000)),
                                                    "workspaceDirectory": "file:///tmp/proj"]]))
        dir.write("sessions/c1.json", json([
            "sessionId": "c1", "title": "Fix tests", "workspaceDirectory": "file:///tmp/proj",
            "history": [
                ["message": ["role": "user", "content": [["type": "text", "text": "fix the tests"]]]],
                ["message": ["role": "assistant", "content": "done", "toolCalls": [["function": ["name": "edit_file"]]]]],
            ]]))
        // One event inside the chat window, one a day earlier (autocomplete).
        dir.write("dev_data/0.2.0/tokensGenerated.jsonl",
                  line(["timestamp": iso(-300), "model": "gpt-4o", "promptTokens": 1000, "generatedTokens": 100])
                  + line(["timestamp": iso(-86_400), "model": "starcoder2:3b", "promptTokens": 500, "generatedTokens": 5]))
        let src = ContinueSource(root: dir.url.path)
        let unit = try #require(src.discover().first)
        let sessions = src.parse(unit)
        let chat = try #require(sessions.first { $0.nativeID == "c1" })
        #expect(chat.userMessages == 1 && chat.assistantMessages == 1)
        #expect(chat.tokens.input == 1000 && chat.tools == ["edit_file": 1])
        #expect(chat.project == "/tmp/proj" && chat.title == "Fix tests")
        let usage = try #require(sessions.first { $0.nativeID.hasPrefix("usage-") })
        #expect(usage.tokens.input == 500 && usage.userMessages == 0)
    }

    @Test func clineTaskWithTokensCostAndTools() throws {
        let dir = TempDir()
        let t0 = Date().addingTimeInterval(-120).timeIntervalSince1970 * 1000
        let req = json(["request": "<task>x</task>\n# Current Working Directory (/tmp/app) Files", "tokensIn": 1200,
                        "tokensOut": 300, "cacheReads": 5000, "cacheWrites": 800, "cost": 0.042])
        let path = dir.write("tasks/1700000000000/ui_messages.json", json([
            ["ts": t0, "type": "say", "say": "task", "text": "Add a login page"],
            ["ts": t0 + 1000, "type": "say", "say": "api_req_started", "text": req],
            ["ts": t0 + 2000, "type": "say", "say": "tool", "text": json(["tool": "readFile", "path": "a.ts"])],
            ["ts": t0 + 3000, "type": "ask", "ask": "command", "text": "npm test"],
            ["ts": t0 + 4000, "type": "say", "say": "text", "text": "Done."],
        ]))
        dir.write("tasks/1700000000000/task_metadata.json", json(["model_usage": [["ts": t0, "model_id": "claude-sonnet-4-5"]]]))
        let src = ClineSource(roots: [dir.url.path + "/tasks"])
        #expect(src.discover().count == 1)
        let s = try #require(src.parse(file(path)).first)
        #expect(s.title == "Add a login page" && s.project == "/tmp/app")
        #expect(s.tokens.input == 1200 && s.tokens.cacheRead == 5000 && s.tokens.cacheWrite == 800)
        #expect(abs(s.cost - 0.042) < 1e-9)     // reported cost wins over estimates
        #expect(s.tools == ["readFile": 1, "execute_command": 1])
        #expect(s.primaryModel == "claude-sonnet-4-5")
        #expect(src.transcript(for: s).map(\.role) == [.user, .tool, .tool, .assistant])
    }

    @Test func aiderHistorySplitsRunsAndParsesTokens() throws {
        let dir = TempDir()
        let md = """
        # aider chat started at 2026-10-01 09:00:00

        > Aider v0.80.0
        > Main model: claude-sonnet-4-5 with diff edit format
        > Git repo: .git with 12 files

        #### add a readme
        #### with install steps

        Sure, here it is.

        > Tokens: 12k sent, 2.5k cache hit, 1.2k received. Cost: $0.05 message, $0.05 session.
        > Applied edit to README.md
        > Commit abc123 docs: add readme

        # aider chat started at 2026-10-02 10:00:00

        > Model: gpt-4o with diff edit format

        """
        let path = dir.write("proj/.aider.chat.history.md", md)
        let sessions = AiderSource.parse(text: md, file: file(path))
        #expect(sessions.count == 1)            // the second run has no prompts
        let s = try #require(sessions.first)
        #expect(s.userMessages == 1 && s.title == "add a readme")
        #expect(s.tokens.input == 9_500 && s.tokens.cacheRead == 2_500 && s.tokens.output == 1_200)
        #expect(abs(s.cost - 0.05) < 1e-9)
        #expect(s.tools == ["edit": 1, "commit": 1] && s.primaryModel == "claude-sonnet-4-5")
        let real = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        #expect(AiderSource.scan([dir.url.path]).map(real) == [real(path)])
        let tr = AiderSource().transcript(for: s)
        #expect(tr.first?.role == .user && tr.first?.text == "add a readme\nwith install steps")
    }

    @Test func kiroSkipsToolOnlySessionsAndEmptyCLIShells() throws {
        let dir = TempDir()
        dir.write("sessions/ws1/sess_a/session.json", json(["id": "sess_a", "title": "New Session",
                                                             "workspacePaths": ["/tmp/k"], "createdAt": iso(-100)]))
        dir.write("sessions/ws1/sess_a/messages.jsonl",
                  line(["timestamp": iso(-90), "payload": ["type": "user_message", "content": "build the API"]])
                  + line(["timestamp": iso(-80), "payload": ["type": "tool_call", "toolName": "fsWrite"]])
                  + line(["timestamp": iso(-70), "payload": ["type": "assistant_message", "content": "Done"]]))
        dir.write("sessions/ws1/sess_b/session.json", json(["id": "sess_b"]))
        dir.write("sessions/ws1/sess_b/messages.jsonl", line(["payload": ["type": "tool_call", "toolName": "fetch_cloud_config"]]))
        dir.write("sessions/cli/empty.json", json(["session_id": "empty", "cwd": "/tmp"]))
        dir.write("sessions/cli/empty.jsonl", "")
        let src = KiroSource(root: dir.url.path + "/sessions")
        let files = src.discover()
        #expect(files.count == 2)               // both IDE sessions, no CLI shell
        let sessions = files.flatMap(src.parse)
        #expect(sessions.count == 1)
        let s = try #require(sessions.first)
        #expect(s.title == "build the API" && s.project == "/tmp/k")
        #expect(s.userMessages == 1 && s.assistantMessages == 1 && s.tools == ["fsWrite": 1])
    }

    @Test func factorySessionWithSettingsTokens() throws {
        let dir = TempDir()
        let path = dir.write("sessions/proj/abc.jsonl",
            line(["type": "session_start", "id": "abc", "title": "Refactor auth", "cwd": "/tmp/f"])
            + line(["type": "message", "timestamp": iso(-60), "message": ["role": "user", "content": [["type": "text", "text": "refactor auth"]]]])
            + line(["type": "message", "timestamp": iso(-50), "message": ["role": "assistant", "content": [
                ["type": "text", "text": "ok"], ["type": "tool_use", "name": "Edit"]]]])
            + line(["type": "message", "timestamp": iso(-40), "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]]))
        dir.write("sessions/proj/abc.settings.json", json(["model": "claude-sonnet-4-5",
            "tokenUsage": ["inputTokens": 2000, "outputTokens": 500, "cacheReadTokens": 10000, "cacheCreationTokens": 0, "thinkingTokens": 100]]))
        let src = FactorySource(root: dir.url.path + "/sessions")
        let s = try #require(src.parse(file(path)).first)
        #expect(s.userMessages == 1 && s.assistantMessages == 1)   // tool results aren't prompts
        #expect(s.tokens.output == 600 && s.tokens.cacheRead == 10000 && s.cost > 0)
        #expect(s.title == "Refactor auth" && s.tools == ["Edit": 1])
    }
}
