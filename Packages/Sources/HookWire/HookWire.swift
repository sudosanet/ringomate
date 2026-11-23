import Foundation

/// アプリ（Agent）と mascot-hook の間の決まり。両方がこれを使う。
public enum HookWire {
    /// アプリが吹き出しの答えを待つ秒数。
    public static let replyTimeout: Double = 20
    /// フックがアプリの答えを待つ秒数（アプリより少し長く待つ）。
    public static let hookTimeout = replyTimeout + 1
    /// 承認の吹き出しに全部出せる長さ。超えるものは端末で聞く（見えない部分を承認させない）。
    public static let maxPermissionSummary = 60

    /// Claude Code のファイルを書き換える道具。
    public static let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    /// `RINGOMATE_HOOK_SOCKET` で差し替えられる。
    public static func socketPath(_ env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let p = env["RINGOMATE_HOOK_SOCKET"] { return p }
        guard let home = env["HOME"] else { return nil }
        return home + "/Library/Application Support/ringomate/hook.sock"
    }
}
