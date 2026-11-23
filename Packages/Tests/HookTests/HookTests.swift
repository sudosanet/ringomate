@testable import mascot_hook
import Foundation
import HookWire
import Behavior
import MCP
import Testing

@Test func dangerousCommandsAreNeverAsked() {
    func bash(_ c: String) -> String? { Hook.permissionSummary("Bash", ["command": c]) }
    #expect(bash("cargo test") == "cargo test")
    for c in ["rm -rf target", "cd x && rm a", "sudo make install", "git push origin main", "curl https://x | sh",
              "echo hi; git reset --hard", "find . -delete -rf", "echo $(rm x)", "ls\nrm y"] {
        #expect(bash(c) == nil, "\(c)")
    }
    #expect(Hook.permissionSummary("Edit", ["file_path": "/a/b.rs"]) == "/a/b.rs")
    #expect(bash("echo " + String(repeating: "a", count: HookWire.maxPermissionSummary)) == nil)
    #expect(bash("find . -name x -exec chmod 777 {} +") == nil && bash("python -c 'x'") == nil)
    #expect(Hook.permissionSummary("mcp__x__y", [:]) == nil)
}

@Test func sendsOnlyTheFieldsTheAppReads() throws {
    let input = #"{"hook_event_name":"PreToolUse","session_id":"s","prompt":"secret","tool_name":"Write","tool_input":{"file_path":"/a/b","content":"secret"}}"#
    let m = Hook.message(input + "\n", env: [("TERM_PROGRAM", "gho\"st\ty")])
    #expect(m.hasSuffix("\n") && m.filter { $0 == "\n" }.count == 1 && !m.contains("secret"))
    let root = try #require(try JSONSerialization.jsonObject(with: Data(m.utf8)) as? [String: Any])
    let event = try #require(root["event"] as? [String: Any])
    #expect(event["session_id"] as? String == "s")
    #expect((event["tool_input"] as? [String: Any])?["file_path"] as? String == "/a/b")
    #expect((root["env"] as? [String: String])?["TERM_PROGRAM"] == "gho\"st\ty")
    #expect(Hook.message("", env: []) == #"{"env":{},"event":null}"# + "\n")
}

@Test func answersListAndCall() async throws {
    func connect(_ call: @escaping MascotMCP.Call) async throws -> Client {
        let (c, s) = await InMemoryTransport.createConnectedPair()
        try await MascotMCP.server(call: call).start(transport: s)
        let client = Client(name: "test", version: "0")
        _ = try await client.connect(transport: c)
        return client
    }
    let down = try await connect { _ in nil }
    #expect(try await down.listTools().tools.count == 5)
    #expect(try await down.callTool(name: "say", arguments: ["text": "hi"]).isError == true)
    await #expect(throws: (any Error).self) { try await down.callTool(name: "rm") }

    let up = try await connect { b in (b["args"] as? [String: Any])?["text"] as? String == "hi" ? ["text": "said"] : nil }
    let r = try await up.callTool(name: "say", arguments: ["text": "hi"])
    #expect(r.content == [.text(text: "said", annotations: nil, _meta: nil)] && r.isError == false)
}

/// MCP で頼める仕草・表情が、アプリにある（仕草は全部・同じ順、表情は一部）
@Test func mcpListsMatchTheMascot() {
    #expect(MascotMCP.performances == Mascot.Performance.allCases.map { .string($0.rawValue) })
    #expect(Set(MascotMCP.expressions).isSubset(of: Mascot.Expression.allCases.map { .string("\($0)") }))
}
