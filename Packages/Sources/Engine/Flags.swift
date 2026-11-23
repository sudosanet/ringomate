import Foundation
import Synchronization

/// 調整用の値（`MASCOT_DISABLE`・`MASCOT_BUST` など）。起動時の環境変数が初期値で、アプリは `set` で変える。
/// どのスレッドから読んでもいい（環境変数を setenv で書き換えると getenv と競合するので、その代わり）。
public enum Flags {
    private struct State {
        var values: [String: String]
        var disabled: Set<String>

        init(_ values: [String: String]) {
            self.values = values
            disabled = Set((values["MASCOT_DISABLE"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
    }

    private static let launch = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("MASCOT_") }
    private static let state = Mutex(State(launch))

    public static func value(_ name: String) -> String? { state.withLock { $0.values[name] } }

    /// `MASCOT_DISABLE` の項目（`+名前` はオプトイン）。
    public static func disabled(_ name: String) -> Bool { state.withLock { $0.disabled.contains(name) } }

    /// 空・nil は消す。起動時の環境変数があればそちらが優先（調べるときに設定より強くする）。
    public static func set(_ values: [String: String?]) {
        state.withLock { s in
            var v = s.values
            for (k, value) in values { v[k] = launch[k] ?? value.flatMap { $0.isEmpty ? nil : $0 } }
            s = State(v)
        }
    }
}
