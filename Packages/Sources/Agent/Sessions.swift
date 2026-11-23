import Foundation
import HookWire
import MascotCore

public struct Sessions {
    public typealias State = AgentState

    public struct Session: Equatable, Sendable {
        public var id: String
        public var cwd: String
        public var terminal: String?
        public var terminalSession: String?
        public var state: State
        public var updated: Date
        public var toolName: String?
        public var actions: [String] = []
    }

    public struct Event: Sendable {
        public var name: String
        public var sessionID: String
        public var cwd: String
        public var toolName: String?
        public var notificationType: String?
        public var terminal: String?
        public var terminalSession: String?
        public var action: String?

        public init(name: String, sessionID: String, cwd: String, toolName: String? = nil,
                    notificationType: String? = nil, terminal: String? = nil, terminalSession: String? = nil,
                    action: String? = nil) {
            self.action = action
            self.terminalSession = terminalSession
            self.name = name
            self.sessionID = sessionID
            self.cwd = cwd
            self.toolName = toolName
            self.notificationType = notificationType
            self.terminal = terminal
        }

        public init?(json: Data) {
            guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                  let e = root["event"] as? [String: Any],
                  let name = e["hook_event_name"] as? String,
                  let id = e["session_id"] as? String
            else { return nil }
            let env = root["env"] as? [String: String] ?? [:]
            self.init(name: name, sessionID: id, cwd: e["cwd"] as? String ?? "",
                      toolName: e["tool_name"] as? String, notificationType: e["notification_type"] as? String,
                      terminal: env["TERM_PROGRAM"],
                      terminalSession: env["ITERM_SESSION_ID"].flatMap { $0.split(separator: ":").last.map(String.init) },
                      action: name == "PreToolUse" ? Self.action(e["tool_name"] as? String, e["tool_input"] as? [String: Any] ?? [:]) : nil)
        }

        /// コマンドの中身・ファイルのパスは渡さない。
        static func action(_ tool: String?, _ input: [String: Any]) -> String? {
            func text(_ k: String) -> String? { (input[k] as? String).map { String($0.prefix(40)) }.flatMap { $0.isEmpty ? nil : $0 } }
            let file = text("file_path").map { URL(filePath: $0).lastPathComponent } ?? text("notebook_path").map { URL(filePath: $0).lastPathComponent }
            switch tool {
            case "Bash": return text("description").map { "started a command to \"\($0)\"" }
            case let t? where HookWire.editTools.contains(t): return file.map { "edited \"\($0)\"" }
            case "Read": return file.map { "read \"\($0)\"" }
            case "WebSearch": return text("query").map { "searched the web for \"\($0)\"" }
            case "Task", "Agent": return text("description").map { "asked another AI to \"\($0)\"" }
            default: return nil
            }
        }
    }

    public private(set) var sessions: [String: Session] = [:]
    static let doneSeconds: TimeInterval = 10
    static let failedSeconds: TimeInterval = 60
    static let staleSeconds: TimeInterval = 30 * 60

    public init() {}

    public mutating func apply(_ e: Event, at now: Date = Date()) {
        if e.name == "SessionEnd" {
            sessions[e.sessionID] = nil
            return
        }
        guard let state = Self.state(for: e, previous: sessions[e.sessionID]?.state) else { return }
        var s = sessions[e.sessionID] ?? Session(id: e.sessionID, cwd: e.cwd, terminal: e.terminal, terminalSession: e.terminalSession,
                                                 state: state, updated: now)
        s.state = state
        s.updated = now
        if !e.cwd.isEmpty { s.cwd = e.cwd }
        if let t = e.terminal { s.terminal = t }
        if let t = e.terminalSession { s.terminalSession = t }
        if let t = e.toolName { s.toolName = t }
        if let a = e.action, s.actions.first != a { s.actions = Array(([a] + s.actions).prefix(3)) }
        sessions[e.sessionID] = s
    }

    static func state(for e: Event, previous: State?) -> State? {
        switch e.name {
        case "SessionStart": return .waitingInput
        case "UserPromptSubmit": return .thinking
        case "SubagentStart": return .delegating
        case "PreCompact": return .compacting
        case "PostToolUse", "SubagentStop": return .working
        case "PreToolUse":
            switch e.toolName {
            case "Read", "Grep", "Glob", "WebFetch", "WebSearch": return .reading
            case let t? where HookWire.editTools.contains(t): return .writing
            case "Bash": return .running
            default: return .working
            }
        case "PermissionRequest": return .waitingPermission
        case "Notification":
            switch e.notificationType {
            case "permission_prompt": return .waitingPermission
            case "idle_prompt": return previous == .waitingPermission ? previous : .waitingInput
            default: return nil
            }
        case "PostToolUseFailure", "StopFailure": return .failed
        case "Stop": return .done
        default: return nil
        }
    }

    public func focus(at now: Date = Date()) -> Session? {
        sessions.values
            .filter { now.timeIntervalSince($0.updated) < Self.staleSeconds }
            .map { s -> Session in
                var s = s
                let age = now.timeIntervalSince(s.updated)
                if s.state == .done && age > Self.doneSeconds || s.state == .failed && age > Self.failedSeconds { s.state = .waitingInput }
                return s
            }
            .max { ($0.state.priority, $0.updated) < ($1.state.priority, $1.updated) }
    }
}

extension AgentState {
    var priority: Int {
        switch self {
        case .waitingPermission: 5
        case .failed: 4
        case .done: 3
        case .working, .reading, .writing, .running, .thinking, .delegating, .compacting: 2
        case .waitingInput: 1
        case .none: 0
        }
    }
}

extension Sessions.Session {
    public var doing: String? {
        switch toolName {
        case "Bash": "running a command"
        case let t? where HookWire.editTools.contains(t): "editing files"
        case "Read", "Grep", "Glob": "reading code"
        case "WebFetch", "WebSearch": "researching on the web"
        case "Task", "Agent": "asking another AI for help"
        default: nil
        }
    }
}
