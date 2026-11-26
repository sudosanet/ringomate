import simd

enum Activity: Equatable {
    case standing(left: Float)
    case walking(to: Float, then: Int?)
    // offset は縁の左端からの x
    case climbing(surface: Int, from: SIMD2<Float>, offset: Float, t: Float)
    case warping(to: SIMD2<Float>, surface: Int?, offset: Float, t: Float)
    case hopping(surface: Int, from: SIMD2<Float>, offset: Float, t: Float)
    case sitting(surface: Int, offset: Float, phase: SitPhase, left: Float)
    case dropping
    case gesturing(index: Int, elapsed: Float)
    case chair(phase: SitPhase, left: Float)
    case hugging(elapsed: Float, left: Float)
    case stretching(elapsed: Float, thenLie: Bool)
    case holding(prop: Mascot.Prop, left: Float)
    case dancing(move: Mascot.DanceMove, moveLeft: Float, left: Float)
    case announcing(app: String, elapsed: Float)
    case visiting(thing: Int, elapsed: Float)

    enum SitPhase: Equatable { case down, idle, up }

    var moving: Bool {
        switch self {
        case .walking, .climbing, .hopping, .dropping, .warping: true
        case let .sitting(_, _, phase, _), let .chair(phase, _): phase != .idle
        case let .hugging(elapsed, _): elapsed < 1.2
        case .standing, .gesturing, .stretching, .holding, .dancing, .announcing, .visiting: false
        }
    }

    /// 立っている・座っているだけ（フレームレートを下げてよい）。
    var still: Bool {
        switch self {
        case .standing: true
        case let .sitting(_, _, phase, _), let .chair(phase, _): phase == .idle
        default: false
        }
    }

    var holdsBody: Bool {
        switch self {
        case .climbing, .hopping, .sitting: true
        case let .warping(_, surface, _, _): surface != nil
        default: false
        }
    }

    /// 頼まれたことに切り替えられる（小物を持っているあいだは持ち替える）。
    var takesRequests: Bool {
        switch self {
        case .standing, .holding: true
        default: false
        }
    }

    var onGround: Bool {
        switch self {
        case .standing, .walking, .gesturing, .stretching, .holding, .dancing, .announcing, .visiting: true
        default: false
        }
    }
}

extension Mascot {
    static let climbSeconds: Float = 0.7
    static let warpVanish: Float = 0.35
    static let phoneMax: Float = 60
    static let warpAppear: Float = 0.75
    static let warpEnd: Float = 1.1

    func act(dt: Float, body: Body, world: World, agent: Agent, intent: inout Intent, target: inout [Float]) {
        let surfaces = world.surfaces.filter { $0.maxX - $0.minX > body.height }
        func surface(_ id: Int) -> Surface? { surfaces.first { $0.id == id } }
        func leavePerch() { self.leavePerch(intent: &intent) }
        if let p = perch, surface(p.surface) == nil {
            leavePerch()
            target[Expression.surprise.rawValue] = 1
            return
        }
        let canSit = body.seatHeight > 0
        let pinned = agent.surfaceID.flatMap { surface($0) }
        if time < dozeUntil { sleepiness = 1 }
        let sleepy = sleepiness > Self.sleepThreshold && !agent.state.needsUser
        let called = agent.calling
            && ((pinned != nil && canSit) || besideWindow(agent, body: body, world: world).map { abs($0 - body.root.x) > body.height * 0.5 } == true)

        let ctx = ActContext(dt: dt, body: body, world: world, agent: agent, surfaces: surfaces, canSit: canSit,
                             pinned: pinned, sleepy: sleepy, called: called)
        if case .walking = activity {} else { walkMotion = nil }
        if perch == nil, body.onLedge, activity.onGround || activity == .dropping,
           let s = surfaces.first(where: { $0.minX <= body.root.x && body.root.x <= $0.maxX && abs($0.top - body.root.y) < 0.5 }) {
            activity = landOn(s, x: body.root.x, ctx)
        }
        if sitRequested {
            sitRequested = false
            let near = surfaces.filter { $0.top > body.root.y + body.height * 0.3 }
                .min { abs(($0.minX + $0.maxX) / 2 - body.root.x) < abs(($1.minX + $1.maxX) / 2 - body.root.x) }
            if let near, canSit, activity.onGround { activity = route(to: near, surfaces: surfaces, body: body, world: world) }
        }
        if hugRequested {
            hugRequested = false
            if perch == nil, activity.onGround { activity = .hugging(elapsed: 0, left: 6) }
        }
        if let (r, at) = pendingRequest {
            if time - at > 10 {
                pendingRequest = nil
            } else if case let .standing(left) = activity, state != .idle || sleepy {
                activity = .standing(left: max(left, 0.5))
            } else if activity.takesRequests {
                pendingRequest = nil
                switch r {
                case let .gesture(name):
                    activity = .gesturing(index: pickGesture(contents: [name]), elapsed: 0)
                case let .prop(p):
                    activity = finish(.prop, body: body, surfaces: surfaces, world: world, prop: p, randomSurface: { nil })
                case .dance where world.env.beat != nil:
                    activity = finish(.dance, body: body, surfaces: surfaces, world: world, prop: .headphones, randomSurface: { nil })
                case .dance, .sit:
                    break
                }
            }
        }
        if let song = world.env.song, songDances[song.id] != nil, body.grounded || perch != nil {
            switch activity {
            case .standing, .holding, .walking, .chair, .hugging, .stretching, .visiting, .announcing,
                 .gesturing where !playingComposed:
                (danceFacing, danceTurn, danceLegs) = (0, nil, nil)
                activity = .dancing(move: .song, moveLeft: 0, left: 120)
            case let .dancing(move, _, left) where move != .song:
                (danceTurn, danceLegs) = (nil, nil)
                activity = .dancing(move: .song, moveLeft: 0, left: max(left, 30))
            default:
                break
            }
        }
        intent.beat = world.env.beat
        if let app = pendingNotice, activity.onGround {
            pendingNotice = nil
            noticeGesture = pickGesture(contents: ["call", "byebye", "wave"])
            activity = .announcing(app: app, elapsed: 0)
        }
        if case .standing = activity {} else { phoneTime = 0 }
        switch activity {
        case let .standing(left):
            actStanding(ctx, left: left, intent: &intent, target: &target)
        case let .dancing(move, moveLeft, left):
            actDancing(ctx, move: move, moveLeft: moveLeft, left: left, intent: &intent, target: &target)
        case let .announcing(app, elapsed):
            actAnnouncing(ctx, app: app, elapsed: elapsed, intent: &intent, target: &target)
        case let .holding(prop, left):
            actHolding(ctx, prop: prop, left: left, intent: &intent, target: &target)
        case let .gesturing(index, elapsed):
            actGesturing(ctx, index: index, elapsed: elapsed, intent: &intent, target: &target)
        case let .chair(phase, left):
            actChair(ctx, phase: phase, left: left, intent: &intent, target: &target)
        case let .hugging(elapsed, left):
            actHugging(ctx, elapsed: elapsed, left: left, intent: &intent, target: &target)
        case let .stretching(elapsed, thenLie):
            actStretching(ctx, elapsed: elapsed, thenLie: thenLie, intent: &intent, target: &target)
        case let .walking(x, then) where perch != nil:
            actWalkingPerched(ctx, x: x, then: then, intent: &intent, target: &target)
        case let .visiting(id, elapsed):
            actVisiting(ctx, id: id, elapsed: elapsed, intent: &intent, target: &target)
        case let .walking(x, then):
            actWalking(ctx, x: x, then: then, intent: &intent, target: &target)
        case let .climbing(id, from, offset, t):
            actClimbing(ctx, id: id, from: from, offset: offset, t: t, intent: &intent, target: &target)
        case let .sitting(id, offset, phase, left):
            actSitting(ctx, id: id, offset: offset, phase: phase, left: left, intent: &intent, target: &target)
        case let .hopping(id, from, offset, t):
            actHopping(ctx, id: id, from: from, offset: offset, t: t, intent: &intent, target: &target)
        case .dropping:
            actDropping(ctx, intent: &intent, target: &target)
        case let .warping(to, id, offset, t):
            actWarping(ctx, to: to, id: id, offset: offset, t: t, intent: &intent, target: &target)
        }
        if let p = perch, let s = surface(p.surface) {
            if intent.drag == .none { intent.drag = .stand(ctx.stand(s, p.x)) }
            intent.walkVelocity = 0
        }
    }

    func actStanding(_ c: ActContext, left: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body, world, agent, surfaces, canSit, pinned, sleepy, called) = (c.dt, c.body, c.world, c.agent, c.surfaces, c.canSit, c.pinned, c.sleepy, c.called)
        func surface(_ id: Int) -> Surface? { c.surface(id) }
        func leavePerch() { self.leavePerch(intent: &intent) }
        phoneLeft = agent.state.busy && agent.state != .thinking ? 4 : max(0, phoneLeft - dt)
        phoneTime += !sleepy && phoneLeft > 0 ? dt : 0
        let onPhone = !sleepy && phoneLeft > 0 && phoneTime < Self.phoneMax
        intent.motion = sleepy ? .idle : onPhone ? .idlePhone : idleMotion
        let remaining = onPhone ? max(left - dt, 1) : left - dt
        let corner = world.width - body.height * 0.6
        if let p = perch, let here = surface(p.surface) {
            if agent.calling, pinned?.id == here.id, canSit {
                sitT = 0
                activity = .sitting(surface: here.id, offset: p.x - here.minX, phase: .down, left: 20 + random() * 40)
            } else if world.keepToCorner || called {
                leavePerch()
            } else if remaining <= 0 {
                activity = choose(body: body, surfaces: canSit ? surfaces : [], world: world, sleepy: sleepy)
            } else {
                activity = .standing(left: remaining)
                if sleepy { doze(intent: &intent, target: &target, body: body) }
            }
        } else if world.keepToCorner {
            activity = abs(corner - body.root.x) > body.height * 0.3 ? .walking(to: corner, then: nil) : .standing(left: max(left, 1))
            if sleepy { doze(intent: &intent, target: &target, body: body) }
        } else if let pinned, canSit, agent.calling {
            activity = route(to: pinned, surfaces: surfaces, body: body, world: world)
        } else if agent.calling, let x = besideWindow(agent, body: body, world: world) {
            activity = abs(x - body.root.x) > body.height * 0.5 ? .walking(to: x, then: nil) : .standing(left: max(remaining, 1))
        } else if agent.state.needsUser || agent.state == .failed, pinned == nil {
            activity = .standing(left: max(remaining, 1))
        } else if remaining <= 0 {
            activity = choose(body: body, surfaces: canSit ? surfaces : [], world: world, sleepy: sleepy)
        } else {
            activity = .standing(left: remaining)
            if sleepy { doze(intent: &intent, target: &target, body: body) }
        }

    }

    func besideWindow(_ agent: Agent, body: Body, world: World) -> Float? {
        guard let w = agent.window else { return nil }
        let margin = body.height * 0.6
        let half = body.height / 2
        _ = shouldWaitForSpace(world)
        return [w.lowerBound - margin, w.upperBound + margin]
            .filter { $0 >= margin && $0 <= world.width - margin }
            .filter { x in !agent.blocked.contains { $0.overlaps(x - half...x + half) } }
            .filter { !isBusy($0, body: body, world: world) }
            .min { a, b in
                let (ba, bb) = (busyness(a, body: body, world: world), busyness(b, body: body, world: world))
                return ba != bb ? ba < bb : abs(a - body.root.x) < abs(b - body.root.x)
            }
    }

    func actAnnouncing(_ c: ActContext, app: String, elapsed: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body) = (c.dt, c.body)
        intent.facing = 0
        if elapsed == 0 { intent.hop = 12 }
        intent.motion = .gesture(UInt8(clamping: noticeGesture ?? 2))
        target[Expression.surprise.rawValue] = max(target[Expression.surprise.rawValue], elapsed < 0.6 ? 0.6 : 0)
        target[Expression.smile.rawValue] = max(target[Expression.smile.rawValue], 0.6)
        let t = elapsed + dt
        activity = (t > 0.5 && body.motionDone) || t > 6 ? .standing(left: 6 + random() * 6) : .announcing(app: app, elapsed: t)

    }

    func actHolding(_ c: ActContext, prop: Prop, left: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, sleepy) = (c.dt, c.sleepy)
        intent.motion = prop.motion
        intent.prop = prop
        intent.facing = 0
        if prop.motion == .holdFront { target[Expression.smile.rawValue] = max(target[Expression.smile.rawValue], 0.3) }
        if prop == .fan { target[Expression.troubled.rawValue] = max(target[Expression.troubled.rawValue], 0.3) }
        let remaining = left - dt
        activity = remaining <= 0 || sleepy && prop != .teddy ? .standing(left: 4 + random() * 6) : .holding(prop: prop, left: remaining)

    }

    func actGesturing(_ c: ActContext, index: Int, elapsed: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body) = (c.dt, c.body)
        intent.prop = gestureProp
        if gestureProp != .headphones { intent.beat = nil }
        intent.motion = index < 0 ? .composed : .gesture(UInt8(clamping: index))
        intent.facing = 0
        let t = elapsed + dt
        // 切り替え直後の motionDone は前のモーションの値なので 0.5 秒待つ
        if (t > 0.5 && body.motionDone) || t > (index < 0 ? 15 : 8) {
            gestureProp = nil
            activity = .standing(left: 8 + random() * 10)
        } else {
            activity = .gesturing(index: index, elapsed: t)
        }

    }

    func actStretching(_ c: ActContext, elapsed: Float, thenLie: Bool, intent: inout Intent, target: inout [Float]) {
        let (dt, body, called) = (c.dt, c.body, c.called)
        intent.motion = .stretch
        intent.facing = 0
        target[Expression.eyesClosed.rawValue] = 1
        target[Expression.mouthOpen.rawValue] = 0.6
        let t = elapsed + dt
        if (t > 0.5 && body.motionDone) || t > 6 {
            activity = thenLie && !called ? .hugging(elapsed: 0, left: 5) : .standing(left: 6 + random() * 8)
        } else {
            activity = .stretching(elapsed: t, thenLie: thenLie)
        }

    }
    enum Choice: CaseIterable { case stand, gesture, wander, sit, rest, seekAttention, prop, dance }

}

struct ActContext {
    let dt: Float
    let body: Mascot.Body
    let world: Mascot.World
    let agent: Mascot.Agent
    let surfaces: [Mascot.Surface]
    let canSit: Bool
    let pinned: Mascot.Surface?
    let sleepy: Bool
    let called: Bool

    func surface(_ id: Int) -> Mascot.Surface? { surfaces.first { $0.id == id } }
    func seat(_ s: Mascot.Surface, _ offset: Float) -> SIMD2<Float> {
        let margin = body.height * 0.3
        return [min(max(s.minX + offset, s.minX + margin), s.maxX - margin), s.top - body.seatHeight]
    }
    func stand(_ s: Mascot.Surface, _ x: Float) -> SIMD2<Float> {
        let margin = body.height * 0.3
        return [min(max(x, s.minX + margin), s.maxX - margin), s.top]
    }
}

extension Mascot {
    func landOn(_ s: Surface, x: Float, _ c: ActContext) -> Activity {
        perch = Perch(surface: s.id, x: c.stand(s, x).x)
        if perchSit {
            perchSit = false
            sitT = 0
            return .sitting(surface: s.id, offset: c.stand(s, x).x - s.minX, phase: .down, left: 20 + random() * 40)
        }
        return .standing(left: 6 + random() * 8)
    }

    func leavePerch(intent: inout Intent) {
        perch = nil
        perchSit = false
        activity = .dropping
        intent.drag = .release
    }
}
