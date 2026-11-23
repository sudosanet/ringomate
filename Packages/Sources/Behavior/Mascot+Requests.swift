import MascotCore
import Foundation
import simd

extension Mascot {
    public func say(_ text: String, seconds: Float = 5, voiced: Bool = false) {
        speech = text
        speechLeft = seconds
        speechVoiced = voiced
    }

    /// 声が続いているあいだ吹き出しを消さない。
    public func holdSpeech(_ seconds: Float) {
        guard speech != nil else { return }
        speechLeft = max(speechLeft, seconds)
    }

    /// となりの画面へ移ったときに座標を `dx` ずらす。
    public func shift(dx: Float) {
        if case let .walking(x, then) = activity { activity = .walking(to: x + dx, then: then) }
        lastRoot = lastRoot.map { $0 + [dx, 0] }
    }

    /// 床に立って待っているときだけする。したら true。
    @discardableResult
    public func perform(_ p: Performance) -> Bool {
        guard state == .idle, sleepiness <= Self.sleepThreshold, case .standing = activity else { return false }
        switch p {
        case .wave:
            state = .reacting(.waving, left: Self.waveSeconds)
            activity = .standing(left: Self.waveSeconds + 1)
        case .hop:
            state = .reacting(.giggle, left: 1.4)
            pendingHop = 18
        case .stretch: activity = .stretching(elapsed: 0, thenLie: false)
        case .bigWave: activity = .gesturing(index: 0, elapsed: 0)
        case .bow: activity = .gesturing(index: 1, elapsed: 0)
        case .beckon: activity = .gesturing(index: 2, elapsed: 0)
        case .reply: activity = .gesturing(index: 3, elapsed: 0)
        case .bothHandsWave: activity = .gesturing(index: 4, elapsed: 0)
        case .cheer: activity = .gesturing(index: 5, elapsed: 0)
        case .dance: activity = .gesturing(index: 6, elapsed: 0)
        case .nod: activity = .gesturing(index: 7, elapsed: 0)
        }
        return true
    }

    /// 起きていれば受け付けて true。立って待っているときに 1 つだけ実行し、10 秒で捨てる。
    @discardableResult
    public func request(_ r: Request) -> Bool {
        guard sleepiness <= Self.sleepThreshold else { return false }
        if r == .sit {
            requestSit()
        } else {
            pendingRequest = (r, time)
        }
        return true
    }

    public var isDancing: Bool {
        if case .dancing = activity { return true }
        return false
    }

    var playingComposed: Bool {
        if case .gesturing(-1, _) = activity { return true }
        return false
    }

    /// 最大 10 秒、最後の 0.3 秒で薄れる。
    public func express(weights: [Expression: Float], seconds: Float = 3) {
        var w = [Float](repeating: 0, count: Expression.allCases.count)
        for (e, v) in weights { w[e.rawValue] = min(max(v, 0), 1) }
        acting = (w, min(max(seconds, 0.1), 10))
    }

    /// 床に立って待っているときだけ。
    @discardableResult
    public func performComposed() -> Bool {
        guard state == .idle, sleepiness <= Self.sleepThreshold, case .standing = activity else { return false }
        activity = .gesturing(index: -1, elapsed: 0)
        return true
    }

    /// 強さは 0〜1、最大 10 秒。
    public func express(_ e: Expression, weight: Float = 1, seconds: Float = 2) {
        flicker = (e, min(max(weight, 0), 1), min(max(seconds, 0.1), 10))
    }

    /// 次に地面に立っているとき、呼ぶ仕草で知らせる。
    public func notify(app: String) { pendingNotice = app }

    /// 同じできごとは 30 秒、どれでも 8 秒空ける。反応したら true。
    @discardableResult
    public func hear(_ event: SoundEvent) -> Bool {
        guard sleepiness <= Self.sleepThreshold, time - lastHeard.any > 8,
              time - (lastHeard.each[event] ?? -.infinity) > 30 else { return false }
        lastHeard.any = time
        lastHeard.each[event] = time
        let standing = state == .idle && activity.onGround && !activity.moving
        switch event {
        case .laughter:
            express(weights: [.smile: 1, .mouthOpen: 0.5, .eyesClosed: 0.6], seconds: 2.5)
            if standing, random() < 0.4 { request(.gesture("laugh")) }
        case .applause:
            express(weights: [.smile: 1, .mouthOpen: 0.4], seconds: 2.5)
            if standing, random() < 0.5 { request(.gesture("happy")) }
        case .boom:
            express(.surprise, weight: 1, seconds: 1.2)
            if standing {
                state = .reacting(.surprised, left: 1.0)
                pendingHop = 9
            }
        case .animal:
            express(weights: [.smile: 0.8, .blush: 0.5], seconds: 2.5)
        case .crying:
            express(.troubled, weight: 0.8, seconds: 3)
        case .scream:
            express(weights: [.surprise: 1, .troubled: 0.6], seconds: 1.5)
        }
        return true
    }
}
