@testable import Agent
import Foundation
import Network
import Testing

@MainActor
@Test func hookServerAnswersRequestsAndForwardsEvents() async throws {
    let path = FileManager.default.temporaryDirectory.appending(path: "hook-\(UUID().uuidString.prefix(8)).sock").path
    var events: [Sessions.Event] = []
    let server = HookServer(path: path, onEvent: { events.append($0) }, onRequest: { request, reply in
        if case let .tool(name, args) = request { reply(["text": "\(name):\(args["text"] ?? "")"]) }
    })
    try server.start()
    defer { server.stop() }
    try await Task.sleep(for: .milliseconds(100))

    func exchange(_ line: String) async -> String {
        await withCheckedContinuation { done in
            let c = NWConnection(to: .unix(path: path), using: .tcp)
            final class Box: @unchecked Sendable { var data = Data(); var resumed = false }
            let box = Box()
            @Sendable func finish() {
                guard !box.resumed else { return }
                box.resumed = true
                c.cancel()
                done.resume(returning: String(decoding: box.data, as: UTF8.self))
            }
            @Sendable func receive() {
                c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, complete, error in
                    if let d { box.data += d }
                    if complete || error != nil { finish() } else { receive() }
                }
            }
            c.stateUpdateHandler = { if case .ready = $0 {
                c.send(content: Data(line.utf8), contentContext: .finalMessage, isComplete: true,
                       completion: .contentProcessed { _ in receive() })
            } }
            c.start(queue: .global())
        }
    }

    let reply = await exchange(#"{"request":{"kind":"tool","name":"say","args":{"text":"hi"}}}"# + "\n")
    #expect(reply.contains(#""text":"say:hi""#))
    _ = await exchange(#"{"event":{"hook_event_name":"Stop","session_id":"s1","cwd":"/tmp"},"env":{}}"# + "\n")
    for _ in 0..<50 where events.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
    #expect(events.count == 1)
}
