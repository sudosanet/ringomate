import Foundation
import HookWire
import Network

/// 受信はバックグラウンドのキューで行い、イベントはメインスレッドで `onEvent` に渡す。
public final class HookServer: @unchecked Sendable {
    public static var defaultPath: String {
        HookWire.socketPath() ?? URL.applicationSupportDirectory.appending(path: "ringomate/hook.sock").path
    }

    private let path: String
    private let queue = DispatchQueue(label: "ringomate.hook", qos: .utility)
    private var listener: NWListener?
    private let onEvent: @MainActor (Sessions.Event) -> Void
    public typealias Reply = @Sendable ([String: any Sendable]) -> Void
    private let onRequest: @MainActor (Request, @escaping Reply) -> Void

    public enum Request: Sendable, Equatable {
        case tool(name: String, args: [String: String])
        case permission(session: String, tool: String, summary: String)

        init?(json: Data) {
            guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let r = root["request"] as? [String: Any] else { return nil }
            switch r["kind"] as? String {
            case "permission":
                self = .permission(session: r["session"] as? String ?? "", tool: r["tool"] as? String ?? "",
                                   summary: r["summary"] as? String ?? "")
            case "tool":
                let args = (r["args"] as? [String: Any] ?? [:]).mapValues { "\($0)" }
                self = .tool(name: r["name"] as? String ?? "", args: args)
            default: return nil
            }
        }
    }

    /// `onRequest` はメインスレッドで呼ばれる。
    public init(path: String = HookServer.defaultPath, onEvent: @escaping @MainActor (Sessions.Event) -> Void,
                onRequest: @escaping @MainActor (Request, @escaping Reply) -> Void = { $1([:]) }) {
        self.path = path
        self.onEvent = onEvent
        self.onRequest = onRequest
    }

    public func start() throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        unlink(path)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .unix(path: path)
        let l = try NWListener(using: params)
        let path = self.path
        l.stateUpdateHandler = { state in
            if case .ready = state { chmod(path, 0o600) }
        }
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: DispatchQueue.global(qos: .utility))
            self?.read(c, Data())
        }
        l.start(queue: queue)
        listener = l
    }

    public func stop() {
        listener?.cancel()
        unlink(path)
    }

    public static let replyTimeout = HookWire.replyTimeout
    public static let maxPermissionSummary = HookWire.maxPermissionSummary

    private func read(_ c: NWConnection, _ data: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] chunk, _, complete, error in
            guard let self else { return c.cancel() }
            let data = data + (chunk ?? Data())
            if complete || error != nil || data.count >= 1 << 20 {
                DispatchQueue.global(qos: .utility).async { self.handle(c, data) }
            } else {
                self.read(c, data)
            }
        }
    }

    private func handle(_ c: NWConnection, _ data: Data) {
        var replies = Data()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let request = Request(json: Data(line)) {
                let handler = onRequest
                let box = ReplyBox()
                DispatchQueue.main.async { MainActor.assumeIsolated { handler(request, box.set) } }
                let reply = box.wait(seconds: Self.replyTimeout)
                guard let out = try? JSONSerialization.data(withJSONObject: reply) else { continue }
                replies += out + Data("\n".utf8)
                continue
            }
            guard let event = Sessions.Event(json: Data(line)) else { continue }
            let handler = onEvent
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(event) } }
        }
        c.send(content: replies, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: [String: any Sendable]?

    func set(_ v: [String: any Sendable]) {
        lock.lock()
        defer { lock.unlock() }
        guard value == nil else { return }
        value = v
        done.signal()
    }

    func wait(seconds: Double) -> [String: any Sendable] {
        _ = done.wait(timeout: .now() + seconds)
        lock.lock()
        defer { lock.unlock() }
        return value ?? [:]
    }
}
