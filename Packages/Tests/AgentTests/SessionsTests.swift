import Foundation
import Testing
@testable import Agent

private func event(_ name: String, _ id: String = "s1", tool: String? = nil, note: String? = nil) -> Sessions.Event {
    .init(name: name, sessionID: id, cwd: "/tmp/p", toolName: tool, notificationType: note, terminal: "ghostty")
}

@Test func toolEventsMapToStates() {
    var s = Sessions()
    s.apply(event("PreToolUse", tool: "Grep"))
    #expect(s.sessions["s1"]?.state == .reading)
    s.apply(event("PreToolUse", tool: "Edit"))
    #expect(s.sessions["s1"]?.state == .writing)
    s.apply(event("PreToolUse", tool: "Bash"))
    #expect(s.sessions["s1"]?.state == .running)
    s.apply(event("Notification", note: "permission_prompt"))
    #expect(s.sessions["s1"]?.state == .waitingPermission)
    s.apply(event("Notification", note: "idle_prompt"))
    #expect(s.sessions["s1"]?.state == .waitingPermission)
    s.apply(event("UserPromptSubmit"))
    #expect(s.sessions["s1"]?.state == .thinking)
    s.apply(event("SubagentStart"))
    #expect(s.sessions["s1"]?.state == .delegating)
    s.apply(event("PreCompact"))
    #expect(s.sessions["s1"]?.state == .compacting)
    s.apply(event("Stop"))
    #expect(s.sessions["s1"]?.state == .done)
    s.apply(event("SessionEnd"))
    #expect(s.sessions.isEmpty)
}

@Test func focusPrefersPermissionThenFailureAndDoneExpires() {
    var s = Sessions()
    let t0 = Date()
    s.apply(event("PreToolUse", "a", tool: "Read"), at: t0)
    s.apply(event("Stop", "b"), at: t0)
    #expect(s.focus(at: t0)?.id == "b")
    #expect(s.focus(at: t0 + 11)?.id == "a")
    s.apply(event("PermissionRequest", "c"), at: t0 + 12)
    #expect(s.focus(at: t0 + 12)?.id == "c")
}

@Test func parsesHookLine() throws {
    let line = #"{"event":{"hook_event_name":"PreToolUse","session_id":"x","cwd":"/a","tool_name":"Bash","extra":1},"env":{"TERM_PROGRAM":"ghostty"}}"#
    let e = try #require(Sessions.Event(json: Data(line.utf8)))
    #expect(e.name == "PreToolUse" && e.toolName == "Bash" && e.terminal == "ghostty" && e.cwd == "/a")
}

@Test func keepsITermSessionAndParsesRequests() throws {
    let line = #"{"event":{"hook_event_name":"UserPromptSubmit","session_id":"s","cwd":"/p"},"env":{"TERM_PROGRAM":"iTerm.app","ITERM_SESSION_ID":"w0t1p0:ABC-123"}}"#
    let e = try #require(Sessions.Event(json: Data(line.utf8)))
    #expect(e.terminalSession == "ABC-123")
    var s = Sessions()
    s.apply(e)
    #expect(s.sessions["s"]?.terminalSession == "ABC-123")
    #expect(TerminalLocator.itermScript(session: "A\"B").contains(#"is "A\"B""#))
}

@Test func remembersRecentActionsWithoutDetails() throws {
    var s = Sessions()
    func pre(_ tool: String, _ input: [String: Any]) throws -> Sessions.Event {
        let json = try JSONSerialization.data(withJSONObject: ["event": ["hook_event_name": "PreToolUse", "session_id": "s1",
                                                                           "cwd": "/tmp/p", "tool_name": tool, "tool_input": input]])
        return try #require(Sessions.Event(json: json))
    }
    s.apply(try pre("Bash", ["command": "curl -H 'token: secret' x", "description": "Run tests"]))
    s.apply(try pre("Edit", ["file_path": "/Users/a/secret/Chatter.swift"]))
    s.apply(try pre("Edit", ["file_path": "/Users/a/secret/Chatter.swift"]))
    s.apply(try pre("Read", ["file_path": "/x/README.md"]))
    s.apply(try pre("Grep", ["pattern": "x"]))
    let a = try #require(s.sessions["s1"]?.actions)
    #expect(a == ["read \"README.md\"", "edited \"Chatter.swift\"", "started a command to \"Run tests\""])
    #expect(!a.joined().contains("secret") && !a.joined().contains("curl"))
}

@Test func failureStopsCallingAfterAMinute() {
    var s = Sessions()
    let t0 = Date()
    s.apply(event("StopFailure"), at: t0)
    #expect(s.focus(at: t0 + 59)?.state == .failed)
    #expect(s.focus(at: t0 + 61)?.state == .waitingInput)
}
