import Foundation
import MascotCore

public struct ChatTriggers: Sendable {
    public struct Config: Sendable, Equatable {
        /// 秒
        public var idleInterval: ClosedRange<Double> = 120...300
        public var minGap: Double = 90
        public var longWorkSeconds: Double = 300
        public var awaySeconds: Double = 300
        public var workResult = true
        public var longWork = true
        public var welcomeBack = true
        public var appSwitch = true
        public var idle = true

        public init() {}
    }

    public var config: Config {
        didSet {
            if config.idleInterval != oldValue.idleInterval { nextIdleChat = Date().addingTimeInterval(.random(in: config.idleInterval)) }
        }
    }
    public private(set) var lastState: AgentState?
    private var lastChat: Date
    private var nextIdleChat: Date
    private var frontApp: (name: String, since: Date, told: Bool)?
    private var wasAway = false
    private var workStarted: Date?
    private var toldLongWork = false
    private var song: (name: String, since: Date, told: Bool)?
    /// 今日それぞれの曲が流れた回数（日が変わったら数えなおす）。
    private var plays: (day: Int, counts: [String: Int]) = (0, [:])
    /// 曲が途切れずに（2 分より長く空かずに）流れはじめた時刻と、最後に流れていた時刻。
    private var music: (since: Date, last: Date)?

    public init(now: Date = Date(), config: Config = Config()) {
        self.config = config
        lastChat = now
        nextIdleChat = now.addingTimeInterval(.random(in: config.idleInterval))
    }

    public mutating func observe(state: AgentState?) { lastState = state }

    /// `focused` は話題が 1 つに決まっているきっかけ（状況の説明を絞って渡す）。
    /// `sound` は曲の雰囲気、`songNotes` は曲について今言えること（テンポ・サビなど）。1 回に 1 つだけ選んで渡す（まとめると詰めこむ）。
    public mutating func next(state: AgentState?, idleSeconds: Double, frontApp app: String?, song playing: String? = nil,
                              sound: String? = nil, songNotes: [String] = [],
                              now: Date = Date()) -> (reason: String, urgent: Bool, focused: Bool)? {
        var reason: String?
        var urgent = false
        var aboutSong = false
        if state != lastState {
            lastState = state
            switch config.workResult ? state : nil {
            case .done: (reason, urgent) = ("The coding task your owner asked for just finished. Thank them for the work", true)
            case .failed: (reason, urgent) = ("Your owner's coding task didn't go well. Cheer them up", true)
            default: break
            }
        }
        if state.map({ [.done, .failed, .waitingInput, .none].contains($0) }) ?? true {
            (workStarted, toldLongWork) = (nil, false)
        } else if workStarted == nil {
            workStarted = now
        }
        if reason == nil, config.longWork, let w = workStarted, !toldLongWork, now.timeIntervalSince(w) > config.longWorkSeconds {
            toldLongWork = true
            reason = "Your owner's AI assistant has been working for about \(Int(now.timeIntervalSince(w) / 60)) minutes. Watch over and encourage"
        }
        if idleSeconds > config.awaySeconds { wasAway = true }
        if reason == nil, wasAway, idleSeconds < 5 {
            wasAway = false
            if config.welcomeBack { reason = "Your owner was away from the desk for a while and just came back. You stayed here the whole time, so greet them as the one welcoming them back (they are the one returning, not you)" }
        }
        hear(playing, now: now)
        // 手を止めて聴いていることも多いので、離席と見なすまでは話す
        if reason == nil, let s = song, !s.told, now.timeIntervalSince(s.since) > 20, idleSeconds < config.awaySeconds {
            (reason, aboutSong) = (songReason(s.name, sound: sound, notes: songNotes, now: now), true)
        }
        if let app {
            if frontApp?.name != app { frontApp = (app, now, false) }
            if reason == nil, config.appSwitch, let f = frontApp, !f.told, now.timeIntervalSince(f.since) > 20, idleSeconds < 30 {
                frontApp?.told = true
                reason = "Your owner started using \"\(app)\". Say something about it"
            }
        }
        if reason == nil, config.idle, now > nextIdleChat, idleSeconds < 30 {
            if let s = song {
                (reason, aboutSong) = (songReason(s.name, sound: sound, notes: songNotes, now: now), true)
            } else {
                reason = "Make casual small talk"
            }
        }
        guard let reason, urgent || now.timeIntervalSince(lastChat) > config.minGap else { return nil }
        lastChat = now
        nextIdleChat = now.addingTimeInterval(.random(in: config.idleInterval))
        if aboutSong { song?.told = true }
        return (reason, urgent, aboutSong)
    }

    private mutating func hear(_ playing: String?, now: Date) {
        if song?.name != playing {
            song = playing.map { ($0, now, false) }
            if let playing {
                let day = Calendar.current.ordinality(of: .day, in: .era, for: now) ?? 0
                if plays.day != day { plays = (day, [:]) }
                plays.counts[playing, default: 0] += 1
            }
        }
        guard playing != nil else { return }
        if let m = music, now.timeIntervalSince(m.last) <= 120 { music?.last = now } else { music = (now, now) }
    }

    private func songReason(_ name: String, sound: String?, notes: [String], now: Date) -> String {
        var notes = notes
        if let n = plays.counts[name], n >= 2 { notes.append("your owner has played this song \(Self.times(n)) today") }
        if let m = music, now.timeIntervalSince(m.since) >= 20 * 60 {
            notes.append("your owner has been listening to music for about \(Int(now.timeIntervalSince(m.since) / 600) * 10) minutes")
        }
        let about = [sound.map { "It sounds \($0)" }, notes.randomElement()].compactMap { $0 }.joined(separator: ", and ")
        return "Your owner is listening to \"\(name)\".\(about.isEmpty ? "" : " \(about).") Say something about the song, not about yourself"
    }

    static func times(_ n: Int) -> String {
        n < 2 ? "once" : n == 2 ? "twice" : n <= 10 ? "\(["three", "four", "five", "six", "seven", "eight", "nine", "ten"][n - 3]) times" : "many times"
    }
}
