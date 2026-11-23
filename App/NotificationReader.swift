import AI
import AppKit
import MascotCore
import os
import Senses

/// 通知のバナーを読んで一言で知らせる（設定でオンのときだけ）。中身は保存せず、ログはアプリ名と文字数だけ。
@MainActor
final class NotificationReader {
    var announce: (_ app: String, _ line: String) -> Void = { _, _ in }
    private let watcher = NotificationWatcher()
    private var ai = AISettings()
    private var waiting: [Notice] = []
    private var lastSpoke = Date.distantPast
    private var read: [String: Date] = [:]
    private var asked = false
    private let log = Logger(subsystem: "app.ringomate", category: "notice")

    init() {
        watcher.onNotice = { [weak self] in self?.receive($0) }
    }

    /// 2 秒おき。
    func tick(_ ai: AISettings) {
        self.ai = ai
        guard ai.readNotifications else {
            watcher.watch(pid: nil)
            (waiting, asked) = ([], false)
            return
        }
        guard NotificationWatcher.trusted else {
            if !asked {
                asked = true
                NotificationWatcher.requestTrust()
            }
            watcher.watch(pid: nil)
            return
        }
        watcher.watch(pid: NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first?.processIdentifier)
        flush()
    }

    /// 通知センターの AX の監視を外す。次の `tick` でまた付ける
    func suspend() {
        watcher.watch(pid: nil)
        waiting = []
    }

    /// バッジの一言と重ねないため。
    func recentlyRead(_ app: String) -> Bool {
        read[app].map { Date().timeIntervalSince($0) < 15 } ?? false
    }

    private func receive(_ n: Notice) {
        let source = NSWorkspace.shared.runningApplications.first { $0.localizedName == n.app }
        let front = !n.app.isEmpty && NSWorkspace.shared.frontmostApplication?.localizedName == n.app
        guard mayLook(atApp: source?.bundleIdentifier, extra: ai.neverLook), !front, !ai.isQuiet() else {
            log.info("notice skipped \(n.app, privacy: .public) front \(front)")
            return
        }
        log.info("notice \(n.app, privacy: .public) title \(n.title.count) body \(n.body.count)")
        waiting.append(n)
        flush()
    }

    private func flush() {
        guard let first = waiting.first, Date().timeIntervalSince(lastSpoke) > 20 else { return }
        let more = waiting.count - 1
        waiting = []
        (lastSpoke, read[first.app]) = (Date(), Date())
        let app = first.app.isEmpty ? String(localized: "an app") : first.app
        if first.isCode {
            announce(first.app, String(localized: "A verification code arrived from \(app)"))
            return
        }
        let fallback = String(localized: "Notification from \(app): \(String((first.title.isEmpty ? first.body : first.title).prefix(30)))")
        let style = ai.style
        Task { [weak self] in
            let line = await NotificationLine.make(app: first.app, title: first.title, body: first.body, more: more, style: style)
            self?.announce(first.app, line ?? fallback)
        }
    }
}
