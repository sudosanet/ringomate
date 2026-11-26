import Testing
@testable import Behavior

/// 身長 17.3・ボーンの幅 6.7（つくよみちゃん）を、1710pt の画面（56.8）に置く。
private let width: Float = 56.8
private func body(at x: Float) -> Mascot.Body {
    Mascot.Body(root: [x, 0], grounded: true, height: 17.3, walkSpeed: 10, seatHeight: 8, width: 6.7)
}

private func world(_ busy: [Float]) -> Mascot.World {
    var w = Mascot.World(width: width)
    w.canLookForSpace = true
    w.busy = busy
    return w
}

private func walk(_ m: Mascot, seconds: Float, body: inout Mascot.Body, world: Mascot.World, agent: Mascot.Agent = .init()) {
    let dt: Float = 1 / 30
    let pointer = Mascot.Pointer(location: [-100, -100], part: nil)
    for _ in 0..<Int(seconds / dt) {
        let i = m.update(dt: dt, pointer: pointer, body: body, world: world, agent: agent)
        body.root.x += i.walkVelocity * dt
    }
}

@Test func staysPutWhenNowhereIsFree() {
    // 実機の足もとの帯: 13 列目だけ少し空いている
    let m = Mascot(random: { 0.1 })
    m.boredom = 1
    var b = body(at: 30)
    walk(m, seconds: 60, body: &b, world: world((0..<64).map { $0 == 13 ? 0.15 : 1 }))
    #expect(abs(b.root.x - 30) < 1, "\(b.root.x)")
}

@Test func walksToAFreeScreenEdge() {
    let m = Mascot(random: { 0.1 })
    m.boredom = 1
    var b = body(at: 20)
    walk(m, seconds: 30, body: &b, world: world((0..<64).map { $0 >= 52 ? 0 : 1 }))
    #expect(b.root.x > 46, "\(b.root.x)")
}

@Test func busynessLooksOnlyUnderTheBody() {
    // 体の幅の外、身長の半分の内側（x = 34）だけに文字
    let w = world((0..<64).map { $0 == Int(34 / width * 64) ? 1 : 0 })
    #expect(Mascot().busyness(28, body: body(at: 28), world: w) == 0)
}

@Test func callingGoesToTheFreeSideOfTheWindow() {
    let agent = Mascot.Agent(state: .done, window: 24...34)
    let m = Mascot(random: { 0.1 })
    var b = body(at: 30)
    walk(m, seconds: 10, body: &b, world: world((0..<64).map { $0 <= 22 ? 1 : 0 }), agent: agent)
    #expect(b.root.x > 40, "\(b.root.x)")

    let stuck = Mascot(random: { 0.1 })
    var s = body(at: 30)
    walk(stuck, seconds: 10, body: &s, world: world([Float](repeating: 1, count: 64)), agent: agent)
    #expect(abs(s.root.x - 30) < 1, "\(s.root.x)")
}
