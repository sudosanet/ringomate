import Foundation
import MascotCore

public final class TerminalLocator: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ringomate.locator", qos: .utility)
    /// `windows` はそのときの端末のウィンドウの番号（タイトルは作業中に変わり続けるので見ない）。増減したらすぐ探しなおす。
    private var cache: [String: (found: Found?, at: Date, windows: String)] = [:]
    private var resolved: [String: Int] = [:]
    private var pending: Set<String> = []
    private let lock = NSLock()
    /// ウィンドウが増減しないとき。タブを別のウィンドウへ移したのに気づくのはこれだけ遅れる。
    static let sameWindowsSeconds: TimeInterval = 30

    public init() {}

    public static func owner(for terminal: String?) -> String? {
        switch terminal {
        case "ghostty": "Ghostty"
        case "iTerm.app": "iTerm2"
        case "Apple_Terminal": "Terminal"
        case "vscode": "Code"
        case "WezTerm": "WezTerm"
        default: nil
        }
    }

    /// AppleScript の窓の並び（画面外の窓も入る）での位置と、窓の総数。
    struct Found: Equatable {
        var index: Int
        var count: Int
    }

    public func window(for session: Sessions.Session, in windows: [DesktopWindow]) -> Int? {
        guard let owner = Self.owner(for: session.terminal) else { return nil }
        let candidates = windows.filter { $0.owner == owner }
        guard !candidates.isEmpty else { return nil }
        let key: String?, script: String?
        switch session.terminal {
        case "ghostty" where !session.cwd.isEmpty:
            (key, script) = ("ghostty:" + session.cwd, Self.ghosttyScript(cwd: session.cwd))
        case "iTerm.app":
            (key, script) = session.terminalSession.map { ("iterm:" + $0, Self.itermScript(session: $0)) } ?? (nil, nil)
        default:
            (key, script) = (nil, nil)
        }
        if let key, let script {
            refresh(key: key, script: script, windows: candidates.map(\.number).sorted().map(String.init).joined(separator: ","))
            lock.lock()
            defer { lock.unlock() }
            if let n = resolved[key], candidates.contains(where: { $0.number == n }) { return n }
            guard let n = Self.pick(cache[key]?.found, candidates: candidates) else { return nil }
            resolved[key] = n
            return n
        }
        return candidates.count == 1 ? candidates[0].number : nil
    }

    /// 画面外の窓があると AppleScript と CG で並びがずれるので、枚数が同じときだけ番号で対応させる。
    static func pick(_ found: Found?, candidates: [DesktopWindow]) -> Int? {
        guard let found, found.count == candidates.count else { return nil }
        return candidates[found.index].number
    }

    private func refresh(key: String, script: String, windows: String) {
        lock.lock()
        defer { lock.unlock() }
        if let c = cache[key], c.windows == windows,
           Date().timeIntervalSince(c.at) < (c.found == nil ? 60 : Self.sameWindowsSeconds) { return }
        guard !pending.contains(key) else { return }
        pending.insert(key)
        queue.async { [weak self] in
            let found = Self.run(script)
            guard let self else { return }
            self.lock.lock()
            if self.cache[key]?.found?.index != found?.index { self.resolved[key] = nil }
            self.cache[key] = (found, Date(), windows)
            self.pending.remove(key)
            self.lock.unlock()
        }
    }

    static func quoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func itermScript(session: String) -> String {
        """
        tell application "iTerm2"
            set i to 0
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (unique ID of s as text) is \(quoted(session)) then return (i as text) & "," & (count of windows)
                    end repeat
                end repeat
                set i to i + 1
            end repeat
            return "-1"
        end tell
        """
    }

    static func ghosttyScript(cwd: String) -> String {
        let escaped = quoted(cwd)
        return """
        tell application "Ghostty"
            set i to 0
            set found to -1
            set matches to 0
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with term in terminals of t
                        if (working directory of term as text) is \(escaped) then
                            set found to i
                            set matches to matches + 1
                        end if
                    end repeat
                end repeat
                set i to i + 1
            end repeat
            if matches is not 1 then return "-1"
            return (found as text) & "," & (count of windows)
        end tell
        """
    }

    static func run(_ script: String) -> Found? {
        parse(runTool("/usr/bin/osascript", ["-e", script]) ?? "")
    }

    /// `"位置,総数"`。見つからない・同じ cwd が何枚もあるときは nil。
    static func parse(_ text: String) -> Found? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",").compactMap { Int($0) }
        guard parts.count == 2, parts[0] >= 0, parts[0] < parts[1] else { return nil }
        return Found(index: parts[0], count: parts[1])
    }
}
