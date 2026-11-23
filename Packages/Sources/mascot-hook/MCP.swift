import Foundation
import HookWire
import MCP

enum MascotMCP {
    static let performances: [Value] = ["wave", "bigWave", "bow", "beckon", "reply", "bothHandsWave", "cheer", "dance", "nod", "stretch", "hop"]
    static let expressions: [Value] = ["smile", "surprise", "calm", "blush", "mouthOpen", "eyesClosed", "angry", "troubled", "wink"]

    static func object(_ properties: [String: Value], required: [Value] = []) -> Value {
        ["type": "object", "properties": .object(properties), "required": .array(required)]
    }

    static let tools = [
        Tool(name: "say", description: "Make the desktop mascot say one line in a speech bubble (up to 40 Japanese characters or 80 characters in other languages; write it in the user's language). Use it when you want to speak to the user at a milestone.",
             inputSchema: object(["text": ["type": "string", "maxLength": 80]], required: ["text"])),
        Tool(name: "perform", description: "Make the mascot do a gesture (for example cheer when all tests pass, wave to greet). Refused while it is walking, sitting, or sleeping.",
             inputSchema: object(["action": ["type": "string", "enum": .array(performances)]], required: ["action"])),
        Tool(name: "express", description: "Make the mascot show an expression for a few seconds.",
             inputSchema: object(["expression": ["type": "string", "enum": .array(expressions)],
                                  "seconds": ["type": "number", "minimum": 0.5, "maximum": 10]], required: ["expression"])),
        Tool(name: "compose_motion",
             description: "Describe an upper-body movement in words (for example \"raise both hands in joy\" or \"tilt the head and think\"); the mascot's on-device model composes it and performs it once. Takes a few seconds. Nods if it can't compose it.",
             inputSchema: object(["description": ["type": "string", "maxLength": 200]], required: ["description"])),
        Tool(name: "get_state", description: "Return the mascot's current state (activity, sleepiness, mood, energy).", inputSchema: object([:])),
    ]

    typealias Call = @Sendable ([String: Any]) -> [String: Any]?

    static func server(call: @escaping Call) async -> Server {
        let server = Server(name: "ringomate", version: "0.1.0", capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            guard tools.contains(where: { $0.name == params.name }) else { throw MCPError.invalidParams("unknown tool: \(params.name)") }
            let args = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(params.arguments ?? [:]))) ?? [String: Any]()
            guard let reply = call(["kind": "tool", "name": params.name, "args": args]) else {
                return .init(content: [.text(text: "RingoMate isn't running", annotations: nil, _meta: nil)], isError: true)
            }
            return .init(content: [.text(text: reply["text"] as? String ?? "ok", annotations: nil, _meta: nil)],
                         isError: reply["error"] as? Bool ?? false)
        }
        return server
    }

    static func serve() async {
        let server = await server { Hook.request($0, timeout: HookWire.hookTimeout) }
        do { try await server.start(transport: StdioTransport()) } catch { return }
        await server.waitUntilCompleted()
    }
}
