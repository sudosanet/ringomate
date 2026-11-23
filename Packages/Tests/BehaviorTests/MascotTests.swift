import Testing
@testable import Behavior

private let body = Mascot.Body(root: [10, 0], grounded: true, height: 20)

@Test func clickOnHeadGigglesAndHops() {
    let m = Mascot()
    let head = SIMD2<Float>(10, 18)
    _ = m.update(dt: 1 / 60, pointer: .init(location: head, part: .head, pressed: true), body: body)
    let up = m.update(dt: 1 / 60, pointer: .init(location: head, part: .head, released: true), body: body)
    #expect(up.hop > 0)
    var smile: Float = 0
    for _ in 0..<20 {
        smile = m.update(dt: 1 / 60, pointer: .init(location: head, part: .head), body: body)
            .expressions[Mascot.Expression.smile.rawValue]
    }
    #expect(smile > 0.5)
}

@Test func dragHoldsAtGrabOffsetThenReleasesAndLands() {
    let m = Mascot()
    _ = m.update(dt: 1 / 60, pointer: .init(location: [10, 10], part: .torso, pressed: true), body: body)
    let held = m.update(dt: 1 / 60, pointer: .init(location: [15, 20], part: .torso), body: body)
    #expect(held.drag == .hold([15, 10]))
    let released = m.update(dt: 1 / 60, pointer: .init(location: [15, 20], part: nil, released: true), body: body)
    #expect(released.drag == .release)
    #expect(m.state == .falling)
    _ = m.update(dt: 1 / 60, pointer: .init(location: [15, 20], part: nil), body: .init(root: [15, 0], grounded: true, height: 20))
    if case .reacting(.landed, _) = m.state {} else { Issue.record("expected landed, got \(m.state)") }
}

@Test func strokingHeadBackAndForthPets() {
    let m = Mascot()
    var x: Float = 9
    for i in 0..<12 {
        x += (i / 3) % 2 == 0 ? 0.4 : -0.4
        _ = m.update(dt: 1 / 60, pointer: .init(location: [x, 18], part: .head), body: body)
    }
    if case .reacting(.petted, _) = m.state {} else { Issue.record("expected petted, got \(m.state)") }
}

@Test func clickWithinOneFrameDoesNotStartDrag() {
    let m = Mascot()
    let r = m.update(dt: 1 / 30, pointer: .init(location: [10, 18], part: .head, pressed: true, released: true), body: body)
    #expect(r.hop > 0)
    let moved = m.update(dt: 1 / 30, pointer: .init(location: [20, 18], part: nil), body: body)
    #expect(moved.drag == .none)
}

@Test func performsRequestedGestureOnlyWhenStanding() {
    let m = Mascot()
    let far = Mascot.Pointer(location: [200, 200], part: nil)
    #expect(m.perform(.dance))
    let out = m.update(dt: 1 / 60, pointer: far, body: body)
    #expect(out.motion == Mascot.Motion.gesture(6))
    #expect(!m.perform(.bow))
    let hopper = Mascot()
    #expect(hopper.perform(.hop))
    #expect(hopper.update(dt: 1 / 60, pointer: far, body: body).hop > 0)
    let face = Mascot()
    face.express(.surprise, seconds: 1)
    var surprise: Float = 0
    for _ in 0..<15 { surprise = face.update(dt: 1 / 60, pointer: far, body: body).expressions[Mascot.Expression.surprise.rawValue] }
    #expect(surprise > 0.5)
}

@Test func requestIsHonoredWhenIdle() {
    let far = Mascot.Pointer(location: [200, 200], part: nil)
    let m = Mascot(random: { 0.1 })
    m.gestureNames = ["bow:happy", "wave:happy"]
    #expect(m.request(.gesture("wave")))
    var motions: [Mascot.Motion] = []
    for _ in 0..<240 { motions.append(m.update(dt: 1 / 30, pointer: far, body: body).motion) }
    #expect(motions.contains(.gesture(1)))
    #expect(motions.first != .gesture(1))
    let p = Mascot(random: { 0.1 })
    #expect(p.request(.prop(.mug)))
    var held: Mascot.Prop?
    for _ in 0..<240 { held = p.update(dt: 1 / 30, pointer: far, body: body).prop ?? held }
    #expect(held == .mug)
    let sleepy = Mascot()
    sleepy.sleepiness = 1
    #expect(!sleepy.request(.dance))
}

@Test func reactsToSoundEvents() {
    let m = Mascot(random: { 0.1 })
    #expect(m.hear(.boom))
    #expect(!m.hear(.laughter))
    m.time += 9
    #expect(m.hear(.laughter))
    m.time += 9
    #expect(!m.hear(.boom))
    m.time += 25
    #expect(m.hear(.boom))
    m.time += 60
    m.needs.sleepiness = 1
    #expect(!m.hear(.applause))
}

@Test func musicMoodSteersDanceArms() {
    let m = Mascot(random: { 0.85 })
    var world = Mascot.World()
    world.env.musicMood = .energetic
    guard case let .dancing(.move(i), _, _) = m.nextDance(world: world, left: 30) else {
        Issue.record("not a built dance move")
        return
    }
    let arms = Mascot.DanceArms.allCases[i % Mascot.DanceArms.allCases.count]
    #expect(Mascot.DanceArms.energetic.contains(arms), "\(arms)")
}

@Test func voicedLineLeavesTheMouthToTheVoice() {
    func widestMouth(_ line: (Mascot) -> Void) -> Float {
        let m = Mascot()
        line(m)
        let mouths = [Mascot.Expression.mouthOpen, .mouthI, .mouthU, .mouthE, .mouthO].map(\.rawValue)
        var widest: Float = 0
        for _ in 0..<60 {
            let out = m.update(dt: 1 / 60, pointer: .init(location: [0, 0], part: nil), body: body)
            widest = max(widest, mouths.map { out.expressions[$0] }.max() ?? 0)
        }
        return widest
    }
    let resting = widestMouth { _ in }
    #expect(widestMouth { $0.say("こんにちは", seconds: 3) } > resting + 0.1)
    #expect(widestMouth { $0.say("こんにちは", seconds: 3, voiced: true) } <= resting + 0.01)
}

@Test func voiceDrivesTheMouthOverAnOpenMouthedFace() {
    func mouthOpen(lips: [Float]?) -> Float {
        let m = Mascot()
        m.express(weights: [.mouthOpen: 1], seconds: 5)
        m.lips = lips
        var last: Float = 0
        for _ in 0..<60 {
            last = m.update(dt: 1 / 60, pointer: .init(location: [0, 0], part: nil), body: body)
                .expressions[Mascot.Expression.mouthOpen.rawValue]
        }
        return last
    }
    #expect(mouthOpen(lips: nil) > 0.8)
    #expect(mouthOpen(lips: [0, 0, 0, 0, 0]) < 0.1)
}
