import Foundation
import MascotCore
import Testing
@testable import AI

@Test func chatTriggersFollowTheAgentAndTheGap() {
    let t0 = Date(timeIntervalSince1970: 0)
    var c = ChatTriggers(now: t0)
    #expect(c.next(state: .working, idleSeconds: 0, frontApp: nil, now: t0) == nil)
    let done = c.next(state: .done, idleSeconds: 0, frontApp: nil, now: t0.addingTimeInterval(10))
    #expect(done?.urgent == true)
    _ = c.next(state: .working, idleSeconds: 999, frontApp: nil, now: t0.addingTimeInterval(20))
    let long = c.next(state: .working, idleSeconds: 999, frontApp: nil, now: t0.addingTimeInterval(330))
    #expect(long?.reason.contains("has been working") == true)
    #expect(c.next(state: .working, idleSeconds: 999, frontApp: nil, now: t0.addingTimeInterval(500)) == nil)
    let back = c.next(state: .working, idleSeconds: 1, frontApp: nil, now: t0.addingTimeInterval(600))
    #expect(back?.reason.contains("just came back") == true)
}

@Test func chatTriggersFollowTheConfig() {
    let t0 = Date(timeIntervalSince1970: 0)
    var config = ChatTriggers.Config()
    (config.workResult, config.welcomeBack, config.idle) = (false, false, false)
    config.minGap = 10
    var c = ChatTriggers(now: t0, config: config)
    _ = c.next(state: .working, idleSeconds: 0, frontApp: nil, now: t0)
    #expect(c.next(state: .done, idleSeconds: 0, frontApp: nil, now: t0.addingTimeInterval(20)) == nil)
    _ = c.next(state: nil, idleSeconds: 999, frontApp: nil, now: t0.addingTimeInterval(30))
    #expect(c.next(state: nil, idleSeconds: 1, frontApp: nil, now: t0.addingTimeInterval(40)) == nil)
    #expect(c.next(state: nil, idleSeconds: 1, frontApp: nil, now: t0.addingTimeInterval(9999)) == nil)
    let app = c.next(state: nil, idleSeconds: 1, frontApp: "Xcode", now: t0.addingTimeInterval(10000))
    #expect(app == nil)
    let told = c.next(state: nil, idleSeconds: 1, frontApp: "Xcode", now: t0.addingTimeInterval(10030))
    #expect(told?.reason.contains("Xcode") == true)
}

@Test func chatTriggersTalkAboutANewSongOnce() {
    let t0 = Date(timeIntervalSince1970: 0)
    var config = ChatTriggers.Config()
    (config.idle, config.minGap) = (false, 60)
    var c = ChatTriggers(now: t0, config: config)
    #expect(c.next(state: nil, idleSeconds: 1, frontApp: nil, song: "Song A", now: t0.addingTimeInterval(1)) == nil)
    // 間が空いていないあいだは待って、空いたら話す
    #expect(c.next(state: nil, idleSeconds: 1, frontApp: nil, song: "Song A", now: t0.addingTimeInterval(30)) == nil)
    let a = c.next(state: nil, idleSeconds: 1, frontApp: nil, song: "Song A", now: t0.addingTimeInterval(70))
    #expect(a?.focused == true && a?.reason.contains("Song A") == true)
    #expect(c.next(state: nil, idleSeconds: 1, frontApp: nil, song: "Song A", now: t0.addingTimeInterval(200)) == nil)
    _ = c.next(state: nil, idleSeconds: 1, frontApp: nil, song: "Song B", now: t0.addingTimeInterval(210))
    let b = c.next(state: nil, idleSeconds: 1, frontApp: nil, song: "Song B", now: t0.addingTimeInterval(240))
    #expect(b?.reason.contains("Song B") == true)
}

@Test func chatTriggersTalkAboutTheSongWhileTheOwnerJustListens() {
    let t0 = Date(timeIntervalSince1970: 0)
    var config = ChatTriggers.Config()
    (config.idle, config.minGap) = (false, 60)
    var c = ChatTriggers(now: t0, config: config)
    _ = c.next(state: nil, idleSeconds: 100, frontApp: nil, song: "Song A", now: t0.addingTimeInterval(70))
    let a = c.next(state: nil, idleSeconds: 120, frontApp: nil, song: "Song A", sound: "cute",
                   songNotes: ["the song just started"], now: t0.addingTimeInterval(100))
    #expect(a?.focused == true)
    #expect(a?.reason.contains("It sounds cute, and the song just started.") == true)
    #expect(a?.reason.contains("not about yourself") == true)
    // 離席と見なしたら話さない
    _ = c.next(state: nil, idleSeconds: 400, frontApp: nil, song: "Song B", now: t0.addingTimeInterval(200))
    #expect(c.next(state: nil, idleSeconds: 400, frontApp: nil, song: "Song B", now: t0.addingTimeInterval(300)) == nil)
}

@Test func smallTalkDuringMusicIsAboutTheSongAndCountsPlays() {
    let t0 = Date(timeIntervalSince1970: 0)
    var config = ChatTriggers.Config()
    (config.minGap, config.idleInterval) = (60, 100...100)
    var c = ChatTriggers(now: t0, config: config)
    for (i, name) in ["Song A", "Song B", "Song A"].enumerated() {
        let start = Double(i) * 1000
        let said = [0, 70, 200, 400].compactMap {
            c.next(state: nil, idleSeconds: 1, frontApp: nil, song: name, now: t0.addingTimeInterval(start + $0))
        }
        #expect(said.count >= 2 && said.allSatisfy { $0.focused && $0.reason.contains(name) })
        if i == 2 { #expect(said.contains { $0.reason.contains("played this song twice today") }) }
    }
    #expect(ChatTriggers.times(3) == "three times" && ChatTriggers.times(11) == "many times")
}
