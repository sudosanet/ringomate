import Foundation

/// アプリに入れた Claude Code のプラグインを、Claude Code の CLI で入れる。
/// フォルダから入れたプラグインはその場から読まれるので、アプリを入れ替えればプラグインも新しくなる。
public enum ClaudePlugin {
    /// 失敗したときは、そのままユーザーに見せる文
    public static func connect(marketplace: URL) async -> String? {
        await Task.detached(priority: .userInitiated) {
            for args in [["plugin", "marketplace", "add", marketplace.path], ["plugin", "install", "ringomate@ringomate"]] {
                if let error = claude(args) { return error }
            }
            return nil
        }.value
    }

    /// Finder から開いたアプリはターミナルの PATH を知らないので、ログインシェル（対話）を通して呼ぶ
    private static func claude(_ args: [String]) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = ["-lic", #"command -v claude >/dev/null || { echo "Claude Code (claude) was not found" >&2; exit 127; }; claude "$@""#, "zsh"] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = out
        do { try p.run() } catch { return error.localizedDescription }
        let message = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        return message.split(separator: "\n").last.map(String.init) ?? "claude: exit \(p.terminationStatus)"
    }
}
