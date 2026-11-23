import Foundation
import HookWire
import Network

/// 何があっても終了コード 0 ですぐ抜ける（Claude の作業を待たせない）。
enum Hook {
    static let envKeys = ["TERM_PROGRAM", "ITERM_SESSION_ID"]
    static let maxInput = 1 << 20


    static let eventKeys = ["hook_event_name", "session_id", "cwd", "tool_name", "notification_type"]
    static let toolInputKeys = ["description", "file_path", "notebook_path", "query"]

    /// アプリが読む項目だけを送る（プロンプト・コマンド・書く中身は送らない）。
    static func message(_ input: String, env: [(String, String)]) -> String {
        var event: Any = NSNull()
        if let e = (try? JSONSerialization.jsonObject(with: Data(input.utf8))) as? [String: Any] {
            var kept = e.filter { eventKeys.contains($0.key) }
            if let t = e["tool_input"] as? [String: Any] { kept["tool_input"] = t.filter { toolInputKeys.contains($0.key) } }
            event = kept
        }
        let root: [String: Any] = ["event": event, "env": Dictionary(env, uniquingKeysWith: { a, _ in a })]
        guard let d = try? JSONSerialization.data(withJSONObject: root, options: .sortedKeys) else { return "{}\n" }
        return String(decoding: d, as: UTF8.self) + "\n"
    }

    static func readStdin() -> String {
        let data = FileHandle.standardInput.readData(ofLength: maxInput)
        return String(decoding: data, as: UTF8.self)
    }

    static func exchange(_ line: String, timeout: TimeInterval, wantReply: Bool) -> Data? {
        guard let path = HookWire.socketPath() else { return nil }
        final class Box: @unchecked Sendable {
            var reply = Data(), ok = false
            let done = DispatchSemaphore(value: 0)
        }
        let box = Box()
        let c = NWConnection(to: .unix(path: path), using: .tcp)
        @Sendable func receive() {
            c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                if let data { box.reply.append(data) }
                if complete || error != nil || box.reply.count >= maxInput { box.done.signal() } else { receive() }
            }
        }
        c.stateUpdateHandler = { state in
            switch state {
            case .ready:
                c.send(content: Data(line.utf8), contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { error in
                    box.ok = error == nil
                    if box.ok && wantReply { receive() } else { box.done.signal() }
                })
            case .waiting, .failed: box.done.signal()
            default: break
            }
        }
        c.start(queue: DispatchQueue(label: "mascot-hook"))
        let finished = box.done.wait(timeout: .now() + timeout) == .success
        c.cancel()
        // 時間切れのあとは受信側がまだ書くかもしれないので読まない
        guard finished else { return nil }
        return box.ok ? box.reply : nil
    }

    static func send() {
        let input = readStdin()
        let env = envKeys.compactMap { k in ProcessInfo.processInfo.environment[k].map { (k, $0) } }
        _ = exchange(message(input, env: env), timeout: 0.3, wantReply: false)
    }

    static func request(_ body: [String: Any], timeout: TimeInterval) -> [String: Any]? {
        guard let line = try? JSONSerialization.data(withJSONObject: ["request": body]),
              let reply = exchange(String(decoding: line, as: UTF8.self) + "\n", timeout: timeout, wantReply: true) else { return nil }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }

    /// ponytail: 素朴な部分一致、漏れより誤検出に倒す。
    static let dangerous = ["rm ", "rm\t", "rmdir", "sudo", "su ", "chmod", "chown", "mv ", "dd ", "mkfs", "diskutil", "kill",
                            "git push", "git reset", "git clean", "git checkout --", "git rebase", "curl", "wget", "| sh", "|sh", "> /",
                            "-delete", "-exec", "xargs", "python", "perl", "ruby", "node ", "osascript", "truncate"]

    static func permissionSummary(_ tool: String, _ input: [String: Any]) -> String? {
        let summary: String?
        switch tool {
        case "Bash":
            let cmd = input["command"] as? String ?? ""
            let lower = " " + cmd.lowercased()
            let risky = dangerous.contains { d in [" ", ";", "&", "|", "(", "`", "\n"].contains { lower.contains($0 + d) } }
                || lower.contains(" -rf") || lower.contains("eval ")
            summary = risky ? nil : cmd
        case _ where HookWire.editTools.contains(tool): summary = input["file_path"] as? String ?? input["notebook_path"] as? String
        case "WebFetch": summary = input["url"] as? String
        case "WebSearch": summary = input["query"] as? String
        default: summary = nil
        }
        guard let summary, !summary.isEmpty, summary.unicodeScalars.count <= HookWire.maxPermissionSummary,
              !summary.contains(where: \.isNewline) else { return nil }
        return summary
    }

    static func permission() {
        let event = (try? JSONSerialization.jsonObject(with: Data(readStdin().utf8))) as? [String: Any] ?? [:]
        let tool = event["tool_name"] as? String ?? ""
        guard let summary = permissionSummary(tool, event["tool_input"] as? [String: Any] ?? [:]) else { return }
        let body: [String: Any] = ["kind": "permission", "session": event["session_id"] ?? NSNull(), "tool": tool, "summary": summary]
        guard let reply = request(body, timeout: HookWire.hookTimeout) else { return }
        let decision: [String: Any]
        switch reply["decision"] as? String {
        case "allow": decision = ["behavior": "allow"]
        case "deny": decision = ["behavior": "deny", "message": "The user denied this in the desktop mascot's speech bubble"]
        default: return
        }
        let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        if let d = try? JSONSerialization.data(withJSONObject: out) { print(String(decoding: d, as: UTF8.self)) }
    }
}

@main
struct Main {
    static func main() async {
        switch CommandLine.arguments.dropFirst().first {
        case "permission": Hook.permission()
        case "mcp": await MascotMCP.serve()
        default: Hook.send()
        }
    }
}
