import Testing
@testable import Senses
import MascotCore

private func banner(_ id: String, _ subrole: String = "AXNotificationCenterBanner", app: String, title: String, body: String,
                    separator: String = "、") -> NoticeNode {
    NoticeNode(subrole: subrole, identifier: id, description: "\(app)\(separator)\(title), \(body)", children: [
        NoticeNode(identifier: "title", text: title), NoticeNode(identifier: "body", text: body), NoticeNode(text: "now"),
    ])
}

@Test func bannersInTheNotificationCenterTreeBecomeNotices() {
    let tree = NoticeNode(subrole: "AXSystemDialog", children: [
        NoticeNode(subrole: "AXHostingView", children: [banner("A", app: "Slack", title: "Aoi", body: "Lunch at noon?")]),
        banner("B", "AXNotificationCenterAlert", app: "Calendar", title: "Standup", body: "", separator: ", "),
        NoticeNode(subrole: "AXHostingView", identifier: "widget", description: "Weather"),
    ])
    let found = Senses.NotificationWatcher.notices(in: tree)
    #expect(found.map(\.id) == ["A", "B"])
    #expect(found[0].notice == Notice(app: "Slack", title: "Aoi", body: "Lunch at noon?"))
    #expect(found[1].notice == Notice(app: "Calendar", title: "Standup", body: ""))
}

@Test func bannerWithoutTextIsIgnored() {
    #expect(Senses.NotificationWatcher.notices(in: NoticeNode(subrole: "AXNotificationCenterBanner", identifier: "X")).isEmpty)
}

@Test func verificationCodesAreRecognized() {
    #expect(Notice(app: "Messages", title: "", body: "Your verification code is 123456").isCode)
    #expect(Notice(app: "Messages", title: "認証コード", body: "123-456 を入力してください").isCode)
    #expect(!Notice(app: "Slack", title: "Aoi", body: "Meeting moved to 3pm").isCode)
    #expect(!Notice(app: "Messages", title: "", body: "Call me at 1234 Main St").isCode)
}

@Test func badgesReportOnlyIncreases() {
    let b = AppBadges()
    #expect(b.increased(["Slack": 3]).isEmpty)
    #expect(b.increased(["Slack": 3]).isEmpty)
    #expect(b.increased(["Slack": 4, "Discord": 1]).map(\.app) == ["Discord", "Slack"])
    #expect(b.increased(["Slack": 2]).isEmpty)
}
