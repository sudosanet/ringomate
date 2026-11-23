import MascotCore
import ApplicationServices
import Foundation

public struct Notice: Sendable, Equatable {
    public var app: String
    public var title: String
    public var body: String

    public init(app: String, title: String, body: String) {
        (self.app, self.title, self.body) = (app, title, body)
    }

    /// 確認コードらしい（言葉と 4〜8 桁の数字）。数字は読み上げない。
    public var isCode: Bool {
        let text = title + " " + body
        return text.range(of: #"(?i)code|passcode|otp|verif|コード|認証|確認番号|ワンタイム|验证码"#, options: .regularExpression) != nil
            && text.range(of: #"(?<![\d])\d(?:[- ]?\d){3,7}(?![\d])"#, options: .regularExpression) != nil
    }
}

/// 通知センターの AX の木の写し。
struct NoticeNode {
    var subrole = ""
    var identifier = ""
    var description = ""
    var text = ""
    var children: [NoticeNode] = []
}

/// 通知センターのバナーを読む（アクセシビリティの許可が要る）。集中モード・画面のミラーリング中はバナーが出ないので読めない。
@MainActor
public final class NotificationWatcher {
    public var onNotice: (Notice) -> Void = { _ in }
    private var observer: AXObserver?
    private var app: AXUIElement?
    private var pid: pid_t?
    /// UUID と中身 → 最後に見た時刻。同じ通知がバナー・まとまり・一覧に別の UUID で出るので中身でも重ねない。
    private var seen: [String: Date] = [:]

    public init() {}

    public static var trusted: Bool { AXIsProcessTrusted() }

    public static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// 通知センターの pid を渡す（nil で止める）。変わったらつなぎ直し、そのとき出ている通知は数えない。
    public func watch(pid: pid_t?) {
        guard pid != self.pid else { return }
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        (observer, app, self.pid) = (nil, nil, pid)
        guard let pid else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        var made: AXObserver?
        guard AXObserverCreate(pid, { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<NotificationWatcher>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { me.scan(announce: true) }
        }, &made) == .success, let made else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXLayoutChangedNotification, kAXCreatedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(made, app, n as CFString, me)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
        (observer, self.app) = (made, app)
        scan(announce: false)
    }

    private func scan(announce: Bool) {
        guard let app else { return }
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 600 }
        let windows = (Self.attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for (id, notice) in windows.flatMap({ Self.notices(in: Self.node($0, depth: 8)) }) {
            let content = "\(notice.app)\n\(notice.title)\n\(notice.body)"
            let known = seen[id] != nil || seen[content].map { now.timeIntervalSince($0) < 120 } == true
            (seen[id], seen[content]) = (now, now)
            if announce, !known { onNotice(notice) }
        }
    }

    nonisolated static let kinds: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert",
                                     "AXNotificationCenterBannerStack", "AXNotificationCenterAlertStack"]

    /// 説明は「アプリ名、タイトル, 本文」（区切りは言語による）なので、アプリ名はタイトルか本文より前の部分。
    nonisolated static func notices(in node: NoticeNode) -> [(id: String, notice: Notice)] {
        guard kinds.contains(node.subrole) else { return node.children.flatMap(notices) }
        let text = { (id: String) in node.children.first { $0.identifier == id }?.text ?? "" }
        let (title, body) = (text("title"), text("body"))
        guard let first = [title, body].first(where: { !$0.isEmpty }) else { return [] }
        let app = node.description.range(of: first).map {
            node.description[..<$0.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: "、,，:：").union(.whitespaces))
        } ?? ""
        return [(node.identifier, Notice(app: app, title: title, body: body))]
    }

    private static func node(_ e: AXUIElement, depth: Int) -> NoticeNode {
        let string = { (name: String) in attribute(e, name) as? String ?? "" }
        var n = NoticeNode(subrole: string(kAXSubroleAttribute), identifier: string(kAXIdentifierAttribute),
                           description: string(kAXDescriptionAttribute))
        n.text = string(kAXValueAttribute)
        if n.text.isEmpty { n.text = n.description }
        if depth > 0 { n.children = ((attribute(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []).map { node($0, depth: depth - 1) } }
        return n
    }

    private static func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
    }
}
