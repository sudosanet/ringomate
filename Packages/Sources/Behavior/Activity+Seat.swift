import MascotCore
import simd

extension Mascot {
    func actChair(_ c: ActContext, phase: Activity.SitPhase, left: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body, world, agent, sleepy, called) = (c.dt, c.body, c.world, c.agent, c.sleepy, c.called)
        intent.facing = body.root.x > world.width / 2 ? 0.5 : -0.5
        switch phase {
        case .down:
            intent.motion = .sitDown
            if body.motionDone {
                activity = .chair(phase: .idle, left: left)
                sitMotion = random() > 0.6 ? .sitRead : .sit
            }
        case .idle:
            intent.motion = sleepy ? .sit : agent.state == .reading ? .sitRead : sitMotion
            let remaining = left - dt
            if remaining <= 0 || sleepy || called { activity = .chair(phase: .up, left: 0) } else { activity = .chair(phase: .idle, left: remaining) }
        case .up:
            intent.motion = .standUp
            if body.motionDone { activity = sleepy && !called ? .stretching(elapsed: 0, thenLie: true) : .standing(left: 6 + random() * 8) }
        }

    }

    func actHugging(_ c: ActContext, elapsed: Float, left: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body, world, sleepy, called) = (c.dt, c.body, c.world, c.sleepy, c.called)
        intent.motion = .hug
        intent.facing = body.root.x > world.width / 2 ? 0.4 : -0.4
        if sleepy { doze(intent: &intent, target: &target, body: body) }
        let remaining = sleepy ? left : left - dt
        activity = remaining <= 0 || called
            ? (called ? .standing(left: 6) : .stretching(elapsed: 0, thenLie: false))
            : .hugging(elapsed: elapsed + dt, left: remaining)

    }

    func actSitting(_ c: ActContext, id: Int, offset: Float, phase: Activity.SitPhase, left: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body, agent, surfaces, pinned, sleepy) = (c.dt, c.body, c.agent, c.surfaces, c.pinned, c.sleepy)
        func surface(_ id: Int) -> Surface? { c.surface(id) }
        func seat(_ s: Surface, _ offset: Float) -> SIMD2<Float> { c.seat(s, offset) }
        func stand(_ s: Surface, _ x: Float) -> SIMD2<Float> { c.stand(s, x) }
        func leavePerch() { self.leavePerch(intent: &intent) }
        guard let s = surface(id) else {
            perch = nil
            activity = .dropping
            intent.drag = .release
            target[Expression.surprise.rawValue] = 1
            return
        }
        let x = seat(s, offset).x
        sitT += dt
        let u = min(sitT / 0.9, 1)
        let ease = u * u * (3 - 2 * u)
        switch phase {
        case .down:
            intent.motion = .sitDown
            intent.drag = .hold([x, s.top - body.seatHeight * (perch != nil ? ease : 1)])
            if body.motionDone {
                activity = .sitting(surface: id, offset: offset, phase: .idle, left: left)
                let r = random()
                sitMotion = r < 0.35 ? .sitSwing : r < 0.6 ? .sitRead : .sit
            }
        case .idle:
            intent.drag = .hold(seat(s, offset))
            intent.motion = sleepy ? .sit : agent.state == .reading ? .sitRead : sitMotion
            let stays = sleepy || pinned?.id == id
            if sleepy { doze(intent: &intent, target: &target, body: body) }
            let remaining = stays ? left : left - dt
            let song = !sleepy && pinned == nil && c.world.env.song.map { songDances[$0.id] != nil } == true
            if remaining <= 0 || song || (pinned != nil && pinned?.id != id) {
                sitT = 0
                activity = .sitting(surface: id, offset: offset, phase: .up, left: 0)
            } else {
                activity = .sitting(surface: id, offset: offset, phase: .idle, left: remaining)
            }
        case .up:
            intent.motion = .standUp
            intent.drag = .hold([x, s.top - body.seatHeight * (1 - ease)])
            if body.motionDone {
                let song = c.world.env.song.map { songDances[$0.id] != nil } == true
                if pinned == nil, !sleepy, !song, random() < Self.hopChance,
                   let next = hopTarget(from: s, among: surfaces, body: body) {
                    let right = next.minX > s.minX
                    let land = right ? body.height * 0.5 : next.maxX - next.minX - body.height * 0.5
                    perch = nil
                    perchSit = true
                    activity = .hopping(surface: next.id, from: stand(s, x), offset: land, t: 0)
                } else if pinned != nil && pinned?.id != id {
                    leavePerch()
                } else {
                    perch = Perch(surface: id, x: x)
                    activity = .standing(left: 4 + random() * 6)
                }
            }
        }

    }
}
