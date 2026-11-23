import Testing

private extension Mascot.Intent {
    /// 足 × 22 + 腕。
    var danceIndex: Int? { if case let .dance(i) = motion { Int(i) } else { nil } }
}

private extension Mascot.Motion {
    var gestureNumber: Int? { if case let .gesture(i) = self { Int(i) } else { nil } }
}
@testable import Behavior

private func mascot() -> Mascot { Mascot(random: { 0.1 }) }
private let pointer = Mascot.Pointer(location: [-100, -100], part: nil)

private func run(_ m: Mascot, seconds: Float, body: inout Mascot.Body, world: Mascot.World,
                 agent: Mascot.Agent = .init(), ground: Float = 0) -> [Mascot.Intent] {
    var out: [Mascot.Intent] = []
    var held = false
    let dt: Float = 1 / 30
    var motion = Mascot.Motion.idle
    var motionTime: Float = 0
    for _ in 0..<Int(seconds / dt) {
        let i = m.update(dt: dt, pointer: pointer, body: body, world: world, agent: agent)
        out.append(i)
        motionTime = i.motion == motion ? motionTime + dt : 0
        motion = i.motion
        body.motionDone = [.sitDown, .standUp, .stretch].contains(motion) && motionTime > 1
        if let to = i.warp { body.root = to }
        switch i.drag {
        case let .hold(p): body.root = p; held = true
        case let .stand(p): body.root = p; held = true
        case .release: held = false
        case .none: break
        }
        if !held {
            body.root.x += i.walkVelocity * dt
            body.root.y = max(ground, body.root.y - 60 * dt)
        }
        body.grounded = !held && body.root.y <= ground + 0.01
    }
    return out
}

@Test func boredMascotWalksSomewhere() {
    let m = mascot()
    m.boredom = 1
    var body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let intents = run(m, seconds: 8, body: &body, world: .init(width: 200))
    #expect(intents.contains { $0.motion == .walk && $0.walkVelocity != 0 })
    #expect(abs(body.root.x - 50) > 5)
}

@Test func climbsOntoWindowSitsAndFollowsIt() {
    let m = mascot()
    m.boredom = 1
    m.needs.energy = 0.1
    var body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    var world = Mascot.World(surfaces: [.init(id: 7, minX: 80, maxX: 160, top: 60)], width: 300)
    _ = run(m, seconds: 12, body: &body, world: world)
    guard case .sitting(7, _, _, _) = m.activity else { Issue.record("not sitting: \(m.activity)"); return }
    #expect(abs(body.root.y - (60 - 8)) < 0.01)
    world.surfaces[0].minX += 20; world.surfaces[0].maxX += 20; world.surfaces[0].top += 10
    let x = body.root.x
    _ = run(m, seconds: 0.2, body: &body, world: world)
    #expect(abs(body.root.x - (x + 20)) < 0.01 && abs(body.root.y - 62) < 0.01)
    world.surfaces = []
    _ = run(m, seconds: 3, body: &body, world: world)
    #expect(body.grounded)
    if case .standing = m.activity {} else { Issue.record("expected standing, got \(m.activity)") }
}

@Test func agentWaitingForPermissionPullsMascotToTerminalAndShowsBubble() {
    let m = mascot()
    var body = Mascot.Body(root: [20, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let world = Mascot.World(surfaces: [.init(id: 3, minX: 120, maxX: 220, top: 40)], width: 300)
    let intents = run(m, seconds: 20, body: &body, world: world, agent: .init(state: .waitingPermission, surfaceID: 3))
    if case .sitting(3, _, _, _) = m.activity {} else { Issue.record("not on terminal: \(m.activity)") }
    #expect(intents.last?.bubble != nil && intents.last?.frameRate == .active)
}

@Test func longIdleUserMakesMascotDozeAndDropFrameRate() {
    let m = mascot()
    var body = Mascot.Body(root: [20, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 0)
    let intents = run(m, seconds: 40, body: &body, world: .init(width: 300, userIdleSeconds: 3600, hour: 2))
    let last = intents.last!
    #expect(last.sleeping && last.expressions[Mascot.Expression.eyesClosed.rawValue] > 0.9)
    #expect(last.frameRate == .sleep)
}

@Test func terminalWithoutALedgeMakesMascotWaitBesideItOnlyWhenCalled() {
    let m = mascot()
    var body = Mascot.Body(root: [20, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    _ = run(m, seconds: 15, body: &body, world: .init(width: 300), agent: .init(state: .waitingPermission, window: 100...200))
    #expect(abs(body.root.x - 88) < 10)
    if case .standing = m.activity {} else { Issue.record("expected standing beside, got \(m.activity)") }
    _ = run(m, seconds: 40, body: &body, world: .init(width: 300), agent: .init(state: .waitingPermission, window: 100...200))
    #expect(abs(body.root.x - 88) < 10)
    let idle = mascot()
    var b = Mascot.Body(root: [20, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    _ = run(idle, seconds: 3, body: &b, world: .init(width: 300), agent: .init(state: .waitingInput, window: 100...200))
    #expect(abs(b.root.x - 20) < 1)
}

@Test func calledMascotStaysPutWhenTheWayToTheTerminalIsBlocked() {
    let m = mascot()
    var body = Mascot.Body(root: [20, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    _ = run(m, seconds: 15, body: &body, world: .init(width: 300),
            agent: .init(state: .waitingPermission, window: 100...200, blocked: [0...300]))
    #expect(abs(body.root.x - 20) < 1)
    let hidden = mascot()
    var b = Mascot.Body(root: [20, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    _ = run(hidden, seconds: 15, body: &b, world: .init(width: 300), agent: .init(state: .waitingPermission))
    #expect(abs(b.root.x - 20) < 1)
}

@Test func draggedAwayMascotDoesNotReturnUntilTheNextCall() {
    let m = mascot()
    let calling = Mascot.Agent(state: .waitingPermission, window: 100...200)
    m.draggedAway = true
    #expect(m.unlessDismissed(calling).window == nil)
    #expect(m.unlessDismissed(calling).window == nil)
    _ = m.unlessDismissed(.init(state: .working, window: 100...200))
    #expect(m.unlessDismissed(.init(state: .done, window: 100...200)).window == 100...200)
}

@Test func asksToLookBeforePickingWhereToWalk() {
    let m = mascot()
    m.boredom = 1
    var body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    var world = Mascot.World(width: 200)
    world.canLookForSpace = true
    let intents = run(m, seconds: 8, body: &body, world: world)
    let asked = intents.firstIndex { $0.lookForSpace }
    let walked = intents.firstIndex { $0.walkVelocity != 0 }
    #expect(asked != nil && walked != nil && asked! < walked!)
}

@Test func wandersToTheEmptyHalf() {
    var world = Mascot.World(width: 200)
    world.canLookForSpace = true
    world.busy = (0..<64).map { $0 < 32 ? 1 : 0 }
    for start: Float in [30, 150] {
        let m = mascot()
        m.boredom = 1
        var body = Mascot.Body(root: [start, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
        _ = run(m, seconds: 25, body: &body, world: world)
        #expect(body.root.x > 110, "from \(start): \(body.root.x)")
    }
}

@Test func longWorkDoesNotKeepThePhoneForever() {
    let m = mascot()
    var body = Mascot.Body(root: [100, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let intents = run(m, seconds: 180, body: &body, world: .init(width: 300), agent: .init(state: .working))
    var run = 0, longest = 0
    for i in intents {
        run = i.motion == .idlePhone ? run + 1 : 0
        longest = max(longest, run)
    }
    #expect(intents.contains { $0.motion == .idlePhone })
    #expect(Float(longest) / 30 <= Mascot.phoneMax + 1, "phone for \(Float(longest) / 30) s")
}

@Test func lonelyMascotWalksToCursorAndWaves() {
    let m = mascot()
    m.needs.attention = 1
    m.needs.boredom = 0
    var body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    var intents: [Mascot.Intent] = []
    var closest = Float.infinity
    let cursor = Mascot.Pointer(location: [150, 30], part: nil)
    for _ in 0..<(30 * 20) {
        let i = m.update(dt: 1 / 30, pointer: cursor, body: body, world: .init(width: 300, userIdleSeconds: 1))
        intents.append(i)
        body.root.x += i.walkVelocity / 30
        closest = min(closest, abs(body.root.x - 140))
    }
    #expect(closest < 3, "walked to the cursor: \(closest)")
    #expect(intents.contains { $0.motion == .gesture(0) })
}

@Test func moodPicksTheWalkStyle() {
    for (mood, expected) in [(Float(0.9), Mascot.Motion.walk), (-0.5, .walkCalm)] {
        let m = mascot()
        m.needs.boredom = 1
        m.needs.mood = mood
        m.needs.energy = 0.9
        var body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 0, calmWalkSpeed: 8)
        let intents = run(m, seconds: 10, body: &body, world: .init(width: 300, userIdleSeconds: 999))
        #expect(intents.contains { $0.motion == expected && $0.walkVelocity != 0 }, "mood \(mood)")
    }
}

@Test func needsReactToEvents() {
    var n = Needs()
    let before = n
    n.record(.petted)
    #expect(n.mood > before.mood && n.attention < before.attention)
    n.record(.dropped)
    n.record(.dropped)
    #expect(n.mood < before.mood + 0.3)
    var e = Needs()
    e.update(dt: 60, activity: .walking(to: 0, then: nil), world: .init(), touched: false)
    #expect(e.energy < 0.8)
    let tired = e.energy
    e.update(dt: 60, activity: .sitting(surface: 0, offset: 0, phase: .idle, left: 10), world: .init(), touched: false)
    #expect(e.energy > tired)
}

@Test func tiredMascotWithoutSeatsHugsKneesAndDozesThenWakes() {
    let m = mascot()
    m.needs.energy = 0.05
    var body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let intents = run(m, seconds: 60, body: &body, world: .init(width: 300, userIdleSeconds: 999))
    #expect(intents.contains { $0.motion == .stretch })
    #expect(intents.contains { $0.motion == .hug && $0.sleeping })
    #expect(m.needs.energy > 0.05)
}

@Test func calmMascotDoesNotGestureTooOften() {
    let m = Mascot(random: { Float.random(in: 0..<1) })
    var body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let intents = run(m, seconds: 120, body: &body, world: .init(width: 300, userIdleSeconds: 999))
    var starts = 0
    for (a, b) in zip(intents, intents.dropFirst()) where b.motion.gestureNumber.map { $0 < 8 } == true && a.motion != b.motion {
        starts += 1
    }
    #expect(starts <= 4, "gestures in 2 minutes: \(starts)")
}

@Test func clickWhileSittingReleasesTheSeatHold() {
    let m = mascot()
    var body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let world = Mascot.World(surfaces: [.init(id: 3, minX: 120, maxX: 220, top: 40)], width: 300)
    m.requestSit()
    let climb = run(m, seconds: 15, body: &body, world: world)
    guard case .sitting = m.activity else { Issue.record("not sitting: \(m.activity)"); return }
    #expect(climb.contains { $0.motion == .climb })
    let at = body.root + [0, 10]
    let press = m.update(dt: 1 / 30, pointer: .init(location: at, part: .torso, pressed: true), body: body, world: world, agent: .init())
    let release = m.update(dt: 1 / 30, pointer: .init(location: at, part: .torso, released: true), body: body, world: world, agent: .init())
    #expect(press.drag == .release || release.drag == .release)
    #expect(!m.activity.holdsBody)
}

@Test func hopsToNeighboringWindowAfterSitting() {
    let m = mascot()
    m.boredom = 1
    m.needs.energy = 0.1
    var body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let world = Mascot.World(surfaces: [.init(id: 7, minX: 80, maxX: 160, top: 60), .init(id: 8, minX: 170, maxX: 260, top: 66)],
                             width: 300)
    _ = run(m, seconds: 12, body: &body, world: world)
    guard case let .sitting(7, offset, _, _) = m.activity else { Issue.record("not sitting: \(m.activity)"); return }
    m.needs.energy = 1
    m.needs.sleepiness = 0
    m.activity = .sitting(surface: 7, offset: offset, phase: .up, left: 0)
    _ = run(m, seconds: 4, body: &body, world: world)
    guard case .sitting(8, _, _, _) = m.activity else { Issue.record("not on the next window: \(m.activity)"); return }
    #expect(abs(body.root.y - (66 - 8)) < 0.01 && body.root.x > 170)
}

@Test func keepsToCornerDuringFullScreen() {
    let m = mascot()
    m.boredom = 1
    var body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let world = Mascot.World(surfaces: [], width: 300, keepToCorner: true)
    _ = run(m, seconds: 40, body: &body, world: world)
    #expect(abs(body.root.x - (300 - 12)) < 6)
    if case .standing = m.activity {} else { Issue.record("expected standing, got \(m.activity)") }
}

@Test func walksAcrossToTheNextScreen() {
    let m = mascot()
    m.boredom = 1
    var body = Mascot.Body(root: [250, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let world = Mascot.World(surfaces: [], width: 300, exitRight: true)
    var crossed = false
    for _ in 0..<40 {
        let out = run(m, seconds: 0.5, body: &body, world: world)
        body.root.x = min(body.root.x, 300 - 3)
        if out.contains(where: { $0.crossScreen == 1 }) { crossed = true; break }
    }
    #expect(crossed)
    m.shift(dx: -300)
    body.root.x -= 300
    _ = run(m, seconds: 5, body: &body, world: world)
    #expect(body.root.x > 0 && body.root.x < 60)
}

@Test func picksAGestureThatFitsTheMood() {
    let m = mascot()
    m.gestureNames = ["byebye:happy", "bow:happy"] + Array(repeating: "", count: 6) + ["wave-both-hands:happy", "bow:sad"]
    #expect(m.pickGesture(contents: ["wave"]) == 8)
}

@Test func warpsWithPuffsWhenTooFarToWalk() {
    let m = mascot()
    var body = Mascot.Body(root: [20, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let world = Mascot.World(surfaces: [], width: 400)
    m.activity = .walking(to: 380, then: nil)
    let intents = run(m, seconds: 1.5, body: &body, world: world)
    #expect(abs(body.root.x - 380) < 1)
    #expect(intents.reduce(0) { $0 + $1.puffs.count } == 2)
    #expect(intents.contains { $0.hidden })
    #expect(!intents.contains { $0.walkVelocity != 0 })
}

@Test func warpsOntoAWindowThatCannotBeClimbed() {
    let m = mascot()
    var body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let world = Mascot.World(surfaces: [.init(id: 3, minX: 0, maxX: 300, top: 80)], width: 300)
    m.activity = .walking(to: 150, then: 3)
    _ = run(m, seconds: 3, body: &body, world: world)
    guard case .sitting(3, _, _, _) = m.activity else { Issue.record("not sitting: \(m.activity)"); return }
    #expect(abs(body.root.y - (80 - 8)) < 0.01)
}

@Test func jumpsOntoALowWindowThatCannotBeClimbed() {
    let m = mascot()
    var body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let world = Mascot.World(surfaces: [.init(id: 4, minX: 0, maxX: 300, top: 15)], width: 300)
    m.activity = m.route(to: world.surfaces[0], surfaces: world.surfaces, body: body, world: world)
    let intents = run(m, seconds: 2, body: &body, world: world)
    #expect(!intents.contains { $0.hidden })
    guard case .sitting(4, _, _, _) = m.activity else { Issue.record("not sitting: \(m.activity)"); return }
}

@Test func climbsANeighborAndHopsAcross() {
    let m = mascot()
    var body = Mascot.Body(root: [250, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let target = Mascot.Surface(id: 5, minX: 0, maxX: 395, top: 60)
    let via = Mascot.Surface(id: 6, minX: 376, maxX: 399, top: 55)
    #expect(!m.climbable(target, body: body, world: .init(width: 400)))
    let world = Mascot.World(surfaces: [target, via], width: 400)
    m.activity = m.route(to: target, surfaces: world.surfaces, body: body, world: world)
    #expect(m.routeNext == 5)
    let intents = run(m, seconds: 20, body: &body, world: world)
    #expect(!intents.contains { $0.hidden })
    guard case .sitting(5, _, _, _) = m.activity else { Issue.record("not on the target: \(m.activity)"); return }
}

@Test func environmentPicksMatchingProps() {
    for (heated, music, want) in [(true, false, Mascot.Prop.fan), (false, true, .headphones)] {
        let m = mascot()
        m.boredom = 1
        var body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 0)
        var world = Mascot.World(width: 300)
        world.env.hot = heated
        world.env.nowPlaying = music ? "song / artist" : nil
        let intents = run(m, seconds: 240, body: &body, world: world)
        #expect(intents.contains { $0.prop == want }, "never used \(want)")
    }
}

@Test func dancesWhenTheBeatIsClear() {
    let m = mascot()
    var body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 0)
    var world = Mascot.World(width: 300)
    world.env.beat = .init(bpm: 128, phase: 0, energy: 0.9)
    world.env.audioPlaying = true
    let intents = run(m, seconds: 120, body: &body, world: world)
    #expect(intents.contains { $0.danceIndex != nil && $0.beat?.bpm == 128 })
    #expect(Set(intents.compactMap(\.danceIndex)).count >= 2)
}

@Test func announcesNotifications() {
    let m = mascot()
    var body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 0)
    let world = Mascot.World(width: 300)
    m.notify(app: "Slack")
    _ = run(m, seconds: 0.2, body: &body, world: world)
    #expect(m.announcingApp == "Slack")
}

@Test func spinsOnTheBeat() {
    let m = mascot()
    var world = Mascot.World(width: 300)
    world.env.audioPlaying = true
    let body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 0)
    var faces: [Float] = []
    let dt: Float = 1 / 30
    for i in 0..<(30 * 20) {
        world.env.beat = .init(bpm: 120, phase: (Float(i) * dt * 2).truncatingRemainder(dividingBy: 1), energy: 0.9)
        faces.append(m.update(dt: dt, pointer: pointer, body: body, world: world, agent: .init()).facing)
    }
    #expect(faces.contains { abs($0) > 3 }, "never turned: max \(faces.map(abs).max() ?? 0)")
    let jumps = zip(faces, faces.dropFirst()).map { a, b -> Float in
        let d = (b - a).truncatingRemainder(dividingBy: .pi * 2)
        return min(abs(d), .pi * 2 - abs(d))
    }
    #expect((jumps.max() ?? 0) < 0.5, "turn jumps \(jumps.max() ?? 0)")
}

@Test func climbsOnlyVisibleAndReachableSides() {
    let m = mascot()
    let body = Mascot.Body(root: [50, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    let world = Mascot.World(width: 300)
    let open = Mascot.Surface(id: 1, minX: 100, maxX: 200, top: 60, bottom: 0)
    #expect(m.climbSides(open, body: body, world: world).count == 2)
    let leftHidden = Mascot.Surface(id: 2, minX: 100, maxX: 200, top: 60, bottom: 0, climbLeft: false)
    #expect(m.climbSides(leftHidden, body: body, world: world) == [206])
    let floating = Mascot.Surface(id: 3, minX: 100, maxX: 200, top: 60, bottom: 30)
    #expect(!m.climbable(floating, body: body, world: world))
    let low = Mascot.Surface(id: 4, minX: 100, maxX: 200, top: 60, bottom: 10)
    #expect(m.climbable(low, body: body, world: world))
}

@Test func livesOnTopOfAWindow() {
    let m = Mascot(random: { Float.random(in: 0..<1) })
    m.gestureNames = Array(repeating: "wave:happy", count: 10)
    var body = Mascot.Body(root: [150, 60], grounded: false, height: 20, walkSpeed: 10, seatHeight: 8, calmWalkSpeed: 8)
    var world = Mascot.World(surfaces: [.init(id: 7, minX: 80, maxX: 260, top: 60)], width: 300)
    m.perch = .init(surface: 7, x: 150)
    m.activity = .standing(left: 0.1)
    var motions = Set<Mascot.Motion>()
    var lowest: Float = .infinity
    for _ in 0..<12 {
        for i in run(m, seconds: 10, body: &body, world: world) {
            motions.insert(i.motion)
            if case let .stand(p) = i.drag {
                #expect(abs(p.y - 60) < 0.01 && p.x >= 86 && p.x <= 254)
                lowest = min(lowest, p.y)
            }
            if case let .hold(p) = i.drag { lowest = min(lowest, p.y) }
        }
        print("ON THE WINDOW:", motions.map { "\($0)" }.sorted(), m.activity)
        if m.perch == nil { break }
    }
    #expect(lowest >= 60 - 8 - 0.01)
    #expect(motions.count >= 4, "motions \(motions.map { "\($0)" }.sorted())")
    if m.perch != nil {
        world.surfaces = []
        _ = run(m, seconds: 3, body: &body, world: world)
        #expect(m.perch == nil && body.grounded)
    }
}

@Test func danceMovesChangeOnDownbeats() {
    for meter in [4, 3] {
        let m = Mascot(random: { Float.random(in: 0..<0.89) })
        var body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
        var world = Mascot.World(width: 300)
        let dt: Float = 1 / 60
        var t: Float = 0.3
        var lastIndex: Int?
        var changes: [(Int?, Float, Float?)] = []
        var changeBars: [Int] = []
        var sectionChangeBar: Int?
        var bars = 0
        m.activity = .dancing(move: .waiting, moveLeft: 0, left: 120)
        for _ in 0..<(60 * 60) {
            let beats = t * 2
            let inBar = Int(beats) % meter
            if inBar == 0, Int(beats) != Int((t - dt) * 2) { bars += 1 }
            let section = bars >= 20 ? 1 : 0
            world.env.beat = .init(bpm: 120, phase: beats - beats.rounded(.down), energy: 0.8, beatInBar: inBar,
                                   meter: meter, section: section, intensity: section == 1 ? 1 : 0.3)
            let i = m.update(dt: dt, pointer: .init(location: [-100, -100], part: nil), body: body, world: world)
            if let d = i.danceIndex, d != lastIndex {
                changes.append((inBar, beats - beats.rounded(.down), i.beat?.clip))
                changeBars.append(bars)
                if section == 1, sectionChangeBar == nil, lastIndex != nil { sectionChangeBar = bars }
                lastIndex = d
                if meter == 3 {
                    let legs = Mascot.DanceLegs(rawValue: d / Mascot.DanceArms.allCases.count)
                    #expect([.sway, .bounce, .twist, .rock, .hipRoll].contains(legs), "waltz legs \(String(describing: legs))")
                }
            }
            body.motionDone = false
            t += dt
            if case .dancing = m.activity {} else { break }
        }
        #expect(changes.count >= 3, "changes \(changes.count) at meter \(meter)")
        for (inBar, phase, clip) in changes {
            #expect(inBar == meter - 1 && phase >= 0.55, "changed at beat \(inBar ?? -1) phase \(phase) (meter \(meter))")
            #expect(clip.map { $0 > -0.45 && $0 < 0 } == true, "clip \(clip ?? .nan)")
        }
        let gaps = zip(changeBars.dropFirst(), changeBars).map { $0 - $1 }
        print("CHANGE BARS", meter, changeBars)
        #expect(gaps.filter { $0 < 2 }.count <= 1, "too short moves: \(changeBars)")
        #expect(sectionChangeBar.map { $0 <= 21 } == true, "section change at bar \(sectionChangeBar ?? -1)")
    }
}

@Test func visitsAnObject() {
    let m = mascot()
    var body = Mascot.Body(root: [20, 0], grounded: true, height: 20, walkSpeed: 20)
    var world = Mascot.World(surfaces: [], width: 200)
    world.things = [Mascot.Thing(id: -1, name: "りんご", comment: "おいしそう", point: [150, 30])]
    let out = run(m, seconds: 40, body: &body, world: world)
    let pointing = out.compactMap(\.point)
    #expect(pointing.contains([150, 30]))
    #expect(out.contains { $0.bubble == "おいしそう" })
    #expect(abs(body.root.x - 150) < 30)
}

@Test func dancesTheSongChorusAtItsPosition() {
    let m = Mascot(random: { 0.5 })
    m.songDances = ["a": 508]
    var body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    var world = Mascot.World(width: 300)
    let dt: Float = 1 / 60
    m.activity = .standing(left: 30)
    var played: [(index: Int?, clip: Float?, rate: Float?, t: Float, inBar: Int, phase: Float)] = []
    for k in 0..<(60 * 40) {
        let t = Float(k) * dt, beats = t * 2.2
        let inBar = Int(beats) % 4, phase = beats - beats.rounded(.down)
        var beat = Mascot.Beat(bpm: 132, phase: phase, energy: 0.8, beatInBar: inBar)
        world.env.beat = beat
        world.env.song = t >= 2 && t < 8.1 ? Mascot.SongPlaying(id: "a", clipTime: 30 + (t - 2) * 1.1, rate: 1.1) : nil
        let i = m.update(dt: dt, pointer: .init(location: [-100, -100], part: nil), body: body, world: world)
        body.motionDone = false
        played.append((i.danceIndex, i.song?.clipTime, i.song?.rate, t, inBar, phase))
    }
    let song = played.filter { $0.t >= 2.05 && $0.t < 8.1 }
    #expect(song.allSatisfy { $0.index == 508 }, "song dance while the chorus plays")
    #expect(song.allSatisfy { abs(($0.clip ?? -99) - (30 + ($0.t - 2) * 1.1)) < 0.05 && $0.rate == 1.1 }, "clip follows the song")
    #expect(played.filter { $0.t < 1.9 }.allSatisfy { $0.index == nil }, "standing before the chorus")
    var changes: [(Int, Float)] = []
    var last: Int? = 508
    for p in played where p.t > 8.1 {
        if let d = p.index, d != last { changes.append((p.inBar, p.phase)); last = d }
    }
    #expect(changes.count >= 2, "normal moves keep changing after the chorus: \(changes.count)")
    for (inBar, phase) in changes {
        #expect(inBar == 3 && phase >= 0.55, "changed at beat \(inBar) phase \(phase)")
    }
}

@Test func songChorusStartsTheDanceFromRestingActivities() {
    for start: Activity in [.chair(phase: .idle, left: 30), .hugging(elapsed: 5, left: 30), .stretching(elapsed: 0.5, thenLie: false)] {
        let m = Mascot(random: { 0.5 })
        m.songDances = ["a": 508]
        m.activity = start
        let body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
        var world = Mascot.World(width: 300)
        world.env.beat = Mascot.Beat(bpm: 132, phase: 0.1, energy: 0.8, beatInBar: 0)
        world.env.song = Mascot.SongPlaying(id: "a", clipTime: 0.1, rate: 1)
        let i = m.update(dt: 1 / 60, pointer: .init(location: [-100, -100], part: nil), body: body, world: world)
        #expect(i.danceIndex == 508, "from \(start)")
    }
}

@Test func songMakesTheMascotStandUpFromAWindowSeatAndDance() {
    let m = Mascot(random: { 0.5 })
    m.songDances = ["a": 508]
    let s = Mascot.Surface(id: 7, minX: 100, maxX: 300, top: 60, bottom: 0)
    var body = Mascot.Body(root: [150, 52], grounded: false, height: 20, walkSpeed: 10, seatHeight: 8)
    var world = Mascot.World(surfaces: [s], width: 400)
    m.activity = .sitting(surface: 7, offset: 50, phase: .idle, left: 60)
    world.env.beat = Mascot.Beat(bpm: 132, phase: 0.1, energy: 0.8, beatInBar: 0)
    var danced: Float? = nil
    for k in 0..<(60 * 6) {
        let t = Float(k) / 60
        world.env.song = Mascot.SongPlaying(id: "a", clipTime: 10 + t, rate: 1)
        let i = m.update(dt: 1 / 60, pointer: .init(location: [-100, -100], part: nil), body: body, world: world)
        body.motionDone = t > 1
        if i.danceIndex == 508, danced == nil { danced = t }
    }
    #expect(danced.map { $0 < 3 } == true, "danced at \(danced ?? -1)s")
}

@Test func dancesTheChorusOfTheSongThatIsPlaying() {
    for (song, want) in [("b", 509), ("c", nil)] as [(String, Int?)] {
        let m = Mascot(random: { 0.5 })
        m.songDances = ["a": 508, "b": 509]
        m.activity = .standing(left: 30)
        let body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
        var world = Mascot.World(width: 300)
        world.env.beat = Mascot.Beat(bpm: 132, phase: 0.1, energy: 0.8, beatInBar: 0)
        world.env.song = Mascot.SongPlaying(id: song, clipTime: 0.1, rate: 1)
        let i = m.update(dt: 1 / 60, pointer: .init(location: [-100, -100], part: nil), body: body, world: world)
        #expect(i.danceIndex == want, "song \(song)")
    }
}

@Test func danceFaceMovesLikeOfficialDances() {
    let m = Mascot(random: { Float.random(in: 0..<0.89) })
    let body = Mascot.Body(root: [150, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 8)
    var world = Mascot.World(width: 300)
    let dt: Float = 1 / 60
    var t: Float = 0.3
    m.activity = .dancing(move: .waiting, moveLeft: 0, left: 120)
    m.lips = [0.5, 0, 0, 0, 0]
    var (brows, frames, laughs, downs) = (0, 0, 0, 0)
    var (laughing, down) = (false, false)
    for _ in 0..<(60 * 60) {
        let beats = t * 2
        world.env.beat = .init(bpm: 120, phase: beats - beats.rounded(.down), energy: 0.8, beatInBar: Int(beats) % 4,
                               meter: 4, section: 0, intensity: 0.5)
        let i = m.update(dt: dt, pointer: .init(location: [-100, -100], part: nil), body: body, world: world)
        t += dt
        guard case .dancing = m.activity else { break }
        let e = { (x: Mascot.Expression) in i.expressions[x.rawValue] }
        frames += 1
        if max(e(.browSerious), e(.browJoy)) > 0.3 { brows += 1 }
        if e(.smile) > 0.7, !laughing { laughs += 1 }
        laughing = e(.smile) > 0.7
        if e(.browDown) > 0.3, !down { downs += 1 }
        down = e(.browDown) > 0.3
    }
    let minutes = Float(frames) / 60 / 60
    print("brows \(Float(brows) / Float(frames)) laughs/min \(Float(laughs) / minutes) brow-downs/min \(Float(downs) / minutes)")
    #expect(Float(brows) / Float(frames) > 0.6)
    #expect(Float(laughs) / minutes >= 8)
    #expect(Float(downs) / minutes >= 15)
}

@Test func startsLivingOnAWindowAfterLandingOnIt() {
    let world = Mascot.World(surfaces: [.init(id: 7, minX: 80, maxX: 260, top: 60)], width: 300)
    for onLedge in [true, false] {
        let m = Mascot(random: { 0.5 })
        var body = Mascot.Body(root: [150, onLedge ? 60 : 0], grounded: true, height: 20, walkSpeed: 10)
        body.onLedge = onLedge
        m.activity = .dropping
        let i = m.update(dt: 1.0 / 30, pointer: pointer, body: body, world: world, agent: .init())
        if onLedge {
            #expect(m.perch?.surface == 7)
            if case let .stand(p) = i.drag { #expect(abs(p.y - 60) < 0.01) } else { Issue.record("not standing: \(i.drag)") }
        } else {
            #expect(m.perch == nil)
        }
    }
}

@MainActor @Test func angryGestureLooksAngry() {
    let m = Mascot()
    m.gestureNames = ["stomp:angry", "cry:sad"]
    var set: [Mascot.Expression: Float] = [:]
    m.libraryExpression(0) { set[$0] = $1 }
    #expect(set[.angry] != nil && set[.troubled] == nil)
    set = [:]
    m.libraryExpression(1) { set[$0] = $1 }
    #expect(set[.troubled] != nil)
}

@Test func onlyStandingOrSittingStillMayLowerFrameRate() {
    #expect(Activity.standing(left: 3).still)
    #expect(Activity.sitting(surface: 1, offset: 0, phase: .idle, left: 3).still)
    #expect(Activity.chair(phase: .idle, left: 3).still)
    #expect(!Activity.sitting(surface: 1, offset: 0, phase: .down, left: 3).still)
    #expect(!Activity.gesturing(index: 0, elapsed: 0).still)
    let m = mascot()
    var body = Mascot.Body(root: [20, 0], grounded: true, height: 20, walkSpeed: 10, seatHeight: 0)
    _ = run(m, seconds: 3, body: &body, world: .init(width: 300))
    m.state = .idle
    m.activity = .standing(left: 100)
    let intents = run(m, seconds: 1, body: &body, world: .init(width: 300))
    #expect(intents.contains { $0.frameRate == .still })
}

@Test func propRequestSwapsTheHeldProp() {
    let m = mascot()
    var body = Mascot.Body(root: [50, 0], grounded: true, height: 20)
    m.activity = .holding(prop: .balloon, left: 15)
    #expect(m.request(.prop(.umbrella)))
    _ = run(m, seconds: 0.2, body: &body, world: .init(width: 100))
    guard case .holding(.umbrella, _) = m.activity else { Issue.record("still \(m.activity)"); return }
}
