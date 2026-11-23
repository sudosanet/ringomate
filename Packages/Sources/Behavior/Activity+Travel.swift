import simd

extension Mascot {
    func actWalkingPerched(_ c: ActContext, x: Float, then: Int?, intent: inout Intent, target: inout [Float]) {
        let (dt, body) = (c.dt, c.body)
        func surface(_ id: Int) -> Surface? { c.surface(id) }
        func stand(_ s: Surface, _ x: Float) -> SIMD2<Float> { c.stand(s, x) }
        guard let p = perch, let here = surface(p.surface) else { return }
        let goal = stand(here, x).x
        let dx = goal - p.x
        let speed = body.calmWalkSpeed > 0 ? body.calmWalkSpeed : body.walkSpeed
        if abs(dx) < 0.3 || speed <= 0 {
            activity = .standing(left: 6 + random() * 8)
        } else {
            perch?.x = p.x + max(-speed * dt, min(speed * dt, dx))
            intent.motion = body.calmWalkSpeed > 0 ? .walkCalm : .walk
            intent.facing = dx > 0 ? -.pi / 2 : .pi / 2
            _ = then
        }

    }

    func actVisiting(_ c: ActContext, id: Int, elapsed: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, world) = (c.dt, c.world)
        guard let thing = world.things.first(where: { $0.id == id }) else {
            activity = .standing(left: 4)
            return
        }
        if elapsed == 0, canSpeak { say(thing.comment) }
        intent.look = thing.point
        if elapsed > 0.3, elapsed < 2.8 { intent.point = thing.point }
        target[Expression.smile.rawValue] = 0.7
        activity = elapsed + dt > 3.4 ? .standing(left: 6 + random() * 6) : .visiting(thing: id, elapsed: elapsed + dt)

    }

    func actWalking(_ c: ActContext, x: Float, then: Int?, intent: inout Intent, target: inout [Float]) {
        let (body, world) = (c.body, c.world)
        func surface(_ id: Int) -> Surface? { c.surface(id) }
        func stand(_ s: Surface, _ x: Float) -> SIMD2<Float> { c.stand(s, x) }
        let dx = x - body.root.x
        if then != nil { perchSit = true }
        if x >= 0, x <= world.width, body.grounded, tooFarToWalk(dx, body: body, world: world) {
            walkMotion = nil
            if let then, let s = surface(then) {
                let offset = (s.maxX - s.minX) * (0.3 + 0.4 * random())
                activity = .warping(to: stand(s, s.minX + offset), surface: s.id, offset: offset, t: 0)
            } else {
                activity = .warping(to: [x, body.root.y], surface: nil, offset: 0, t: 0)
            }
            return
        }
        if x > world.width, world.exitRight, body.root.x > world.width - body.height * 0.4 { intent.crossScreen = 1 }
        if x < 0, world.exitLeft, body.root.x < body.height * 0.4 { intent.crossScreen = -1 }
        if abs(dx) < 0.6 || body.walkSpeed <= 0 {
            walkMotion = nil
            if let then, let s = surface(then) {
                let offset = body.root.x < s.minX ? 0 : body.root.x > s.maxX ? s.maxX - s.minX : body.root.x - s.minX
                activity = .climbing(surface: s.id, from: body.root, offset: offset, t: 0)
            } else if let v = pendingVisit {
                pendingVisit = nil
                activity = .visiting(thing: v, elapsed: 0)
            } else if let g = pendingGesture {
                pendingGesture = nil
                activity = .gesturing(index: g, elapsed: 0)
            } else {
                activity = .standing(left: 8 + random() * 10)
            }
        } else {
            let motion = walkMotion ?? (needs.cheerful || body.calmWalkSpeed <= 0 ? .walk : .walkCalm)
            walkMotion = motion
            let speed = switch motion {
            case .walkCalm: body.calmWalkSpeed
            case .walkCarry: body.carryWalkSpeed
            default: body.walkSpeed
            }
            intent.motion = motion
            intent.walkVelocity = (dx > 0 ? 1 : -1) * speed
            intent.facing = dx > 0 ? -.pi / 2 : .pi / 2
        }

    }

    func actClimbing(_ c: ActContext, id: Int, from: SIMD2<Float>, offset: Float, t: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body) = (c.dt, c.body)
        func surface(_ id: Int) -> Surface? { c.surface(id) }
        func stand(_ s: Surface, _ x: Float) -> SIMD2<Float> { c.stand(s, x) }
        func land(on s: Surface, x: Float) -> Activity { landOn(s, x: x, c) }
        guard let s = surface(id) else {
            activity = .dropping
            intent.drag = .release
            return
        }
        let to = stand(s, s.minX + offset)
        let side: Float = from.x < s.minX - 0.5 ? 1 : from.x > s.maxX + 0.5 ? -1 : 0
        var done: Bool
        if side != 0 {
            let speed = body.height * 0.6
            let hang = s.top - body.height * 0.35
            let start = min(max(from.y, s.bottom), hang)
            let jump: Float = start > from.y + body.height * 0.05 ? 0.35 : 0
            let rise = max(0, (hang - start) / speed)
            intent.motion = .climb
            intent.facing = side > 0 ? -.pi / 2 : .pi / 2
            if t < jump {
                let u = t / jump
                intent.drag = .hold([from.x, from.y + (start - from.y) * sin(u * .pi / 2)])
                done = false
            } else if t < jump + rise {
                intent.drag = .hold([from.x, start + speed * (t - jump)])
                done = false
            } else {
                intent.motion = .mantle
                let u = min((t - jump - rise) / Self.mantleSeconds, 1)
                let lift = sin(u * .pi) * body.height * 0.15
                intent.drag = .hold([from.x + (to.x - from.x) * u, hang + (to.y - hang) * u + lift])
                done = u >= 1
            }
        } else if s.top - from.y <= jumpReach(body: body) {
            let u = min(t / Self.climbSeconds, 1)
            let apex = max(from.y, to.y) + body.height * 0.2
            let y = (1 - u) * (1 - u) * from.y + 2 * (1 - u) * u * (2 * apex - (from.y + to.y) / 2) + u * u * to.y
            intent.drag = .hold([from.x + (to.x - from.x) * u, y])
            intent.motion = .idle
            done = u >= 1
        } else {
            routeNext = nil
            activity = .warping(to: to, surface: id, offset: offset, t: 0)
            return
        }
        if done, let next = routeNext.flatMap({ surface($0) }), hopTarget(from: s, among: [next], body: body) != nil {
            routeNext = nil
            let land = next.minX > s.maxX ? body.height * 0.5 : next.maxX - next.minX - body.height * 0.5
            activity = .hopping(surface: next.id, from: to, offset: land, t: 0)
        } else if done {
            routeNext = nil
            activity = land(on: s, x: to.x)
        } else {
            activity = .climbing(surface: id, from: from, offset: offset, t: t + dt)
        }

    }

    func actHopping(_ c: ActContext, id: Int, from: SIMD2<Float>, offset: Float, t: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body) = (c.dt, c.body)
        func surface(_ id: Int) -> Surface? { c.surface(id) }
        func stand(_ s: Surface, _ x: Float) -> SIMD2<Float> { c.stand(s, x) }
        func land(on s: Surface, x: Float) -> Activity { landOn(s, x: x, c) }
        guard let s = surface(id) else {
            activity = .dropping
            intent.drag = .release
            return
        }
        let to = stand(s, s.minX + offset)
        let u = min(t / Self.hopSeconds, 1)
        let apex = max(from.y, to.y) + body.height * 0.3
        let y = (1 - u) * (1 - u) * from.y + 2 * (1 - u) * u * (2 * apex - (from.y + to.y) / 2) + u * u * to.y
        intent.drag = .hold([from.x + (to.x - from.x) * u, y])
        intent.motion = .idle
        intent.facing = to.x > from.x ? -.pi / 2 : .pi / 2
        target[Expression.mouthOpen.rawValue] = max(target[Expression.mouthOpen.rawValue], 0.4)
        activity = u >= 1 ? land(on: s, x: to.x) : .hopping(surface: id, from: from, offset: offset, t: t + dt)

    }

    func actDropping(_ c: ActContext, intent: inout Intent, target: inout [Float]) {
        let body = c.body
        intent.motion = .idle
        if body.grounded { activity = .standing(left: 2 + random() * 3) }

    }

    func actWarping(_ c: ActContext, to: SIMD2<Float>, id: Int?, offset: Float, t: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body) = (c.dt, c.body)
        func surface(_ id: Int) -> Surface? { c.surface(id) }
        func land(on s: Surface, x: Float) -> Activity { landOn(s, x: x, c) }
        let s = id.flatMap { surface($0) }
        if id != nil, s == nil {
            activity = .standing(left: 2)
            return
        }
        let next = t + dt
        intent.facing = 0
        intent.motion = .idle
        if t == 0 { intent.hop = 14 }
        if t < Self.warpVanish {
            target[Expression.smile.rawValue] = 1
            target[Expression.wink.rawValue] = 1
        }
        if t < Self.warpVanish, next >= Self.warpVanish {
            intent.puffs.append(SIMD3(body.root.x, body.root.y + body.height * 0.5, body.height * 0.75))
        }
        intent.hidden = next >= Self.warpVanish && next < Self.warpAppear
        if t < Self.warpVanish + 0.1, next >= Self.warpVanish + 0.1 { intent.warp = to }
        if next >= Self.warpVanish + 0.1, s != nil { intent.drag = .hold(to) }
        if t < Self.warpAppear, next >= Self.warpAppear {
            intent.puffs.append(SIMD3(to.x, to.y + body.height * 0.5, body.height * 0.75))
        }
        if next >= Self.warpAppear {
            target[Expression.smile.rawValue] = 1
            target[Expression.mouthOpen.rawValue] = 0.4
        }
        if next < Self.warpEnd {
            activity = .warping(to: to, surface: id, offset: offset, t: next)
        } else if let s {
            activity = land(on: s, x: to.x)
        } else {
            activity = .gesturing(index: pickGesture(contents: ["byebye", "bye", "wave", "call"]), elapsed: 0)
        }
    }
}
