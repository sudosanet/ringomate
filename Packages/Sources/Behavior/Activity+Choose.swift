import MascotCore
import simd

extension Mascot {
    func pickProp(world: World) -> (Prop, Float) {
        let env = world.env, hour = world.hour
        var candidates: [(Prop, Float)] = []
        if env.heated { candidates.append((.fan, 0.9)) }
        if env.music { candidates.append((.headphones, 0.7)) }
        if env.app == .game { candidates.append((.controller, 0.7)) }
        if env.app == .dev || env.typingHard { candidates.append((.mug, 0.4)) }
        if env.app == .browser || env.app == .office { candidates.append((.magnifier, 0.25)) }
        if env.app == .design { candidates.append((.paintbrush, 0.5)) }
        if (6...10).contains(hour) { candidates.append((.mug, 0.45)) }
        if (11...13).contains(hour) || (15...16).contains(hour) { candidates += [(.onigiri, 0.35), (.iceCream, 0.25)] }
        if hour >= 21 || hour < 6 || env.dark { candidates.append((.teddy, 0.35)) }
        if !env.online { candidates.append((.umbrella, 0.3)) }
        if env.lowBattery { candidates.append((.bottle, 0.3)) }
        candidates += [
            (.flower, 0.1), (.lollipop, 0.1), (.balloon, needs.cheerful ? 0.3 : 0.05), (.iceCream, 0.08),
            (.camera, 0.08), (.magnifier, 0.06), (.umbrella, 0.04), (.paintbrush, 0.05),
        ]
        let pool = candidates.filter { $0.0 != lastProp }
        let total = pool.reduce(0) { $0 + $1.1 }
        var r = random() * total
        for (p, w) in pool {
            r -= w
            if r <= 0 { return (p, w) }
        }
        return pool.last ?? (.flower, 0.1)
    }

    func utility(_ c: Choice, canSit: Bool) -> Float {
        let n = needs
        switch c {
        case .stand: return 0.4 + (1 - n.energy) * 0.1
        case .gesture: return 0.05 + n.boredom * 0.25 + max(n.mood, 0) * 0.15 + n.attention * 0.1
        case .wander: return n.boredom * 0.8 * (0.4 + n.energy) + (n.cheerful ? 0.1 : 0)
        case .sit: return canSit ? 0.3 + (1 - n.energy) * 0.5 + n.boredom * 0.4 : -1
        case .rest: return (canSit ? 0.05 : 0.15) + (1 - n.energy) * 0.5 + n.boredom * 0.2
        case .seekAttention: return userActive && lastPointer != nil ? (n.attention - 0.3) * 2 : -1
        case .prop: return 0.2 + n.boredom * 0.2
        case .dance: return -1
        }
    }

    func choose(body: Body, surfaces: [Surface], world: World, sleepy: Bool) -> Activity {
        idleMotion = .idle
        let reachable = surfaces.filter { $0.top > body.root.y + body.height * 0.3 }
        func randomSurface() -> Surface? {
            reachable.isEmpty ? nil : reachable[min(Int(random() * Float(reachable.count)), reachable.count - 1)]
        }
        if perch == nil, !sleepy {
            if shouldWaitForSpace(world) { return .standing(left: 0.7) }
            let here = busyness(body.root.x, body: body, world: world)
            if here > Self.busyThreshold, let x = freestX(groundCandidates(body: body, world: world), body: body, world: world),
               busyness(x, body: body, world: world) < here {
                return .walking(to: x, then: nil)
            }
        }
        if perch == nil, !sleepy, time - lastVisit > 120, random() < 0.25,
           let thing = world.things.filter({ !visited.contains($0.id) }).first ?? world.things.first {
            lastVisit = time
            visited.insert(thing.id)
            if visited.count >= world.things.count { visited.removeAll() }
            if let seat = surfaces.first(where: { $0.id == thing.id }), random() < 0.4 {
                return route(to: seat, surfaces: surfaces, body: body, world: world)
            }
            let side: Float = thing.point.x > body.root.x ? -1 : 1
            pendingVisit = thing.id
            return .walking(to: min(max(thing.point.x + side * body.height * 0.7, body.height), world.width - body.height), then: nil)
        }
        if let p = perch, let here = world.surfaces.first(where: { $0.id == p.surface }) {
            if sleepy {
                return random() < 0.5 ? .hugging(elapsed: 0, left: 5) : sitHere(here, p)
            }
            switch choosePerchedChoice(world: world) {
            case .sit: return sitHere(here, p)
            case .rest: return random() < 0.5 ? .hugging(elapsed: 0, left: 8 + random() * 10) : sitHere(here, p)
            case .wander:
                needs.boredom = 0
                if random() < 0.3 {
                    if let next = hopTarget(from: here, among: surfaces, body: body) {
                        let land = next.minX > here.minX ? body.height * 0.5 : next.maxX - next.minX - body.height * 0.5
                        perch = nil
                        return .hopping(surface: next.id, from: [p.x, here.top], offset: land, t: 0)
                    }
                    perch = nil
                    return .dropping
                }
                guard here.maxX - here.minX > body.height * 2 else { return sitHere(here, p) }
                let x = here.minX + body.height * 0.3 + random() * (here.maxX - here.minX - body.height * 0.6)
                return .walking(to: x, then: nil)
            case let c:
                return finish(c, body: body, surfaces: surfaces, world: world, prop: pickProp(world: world).0,
                              randomSurface: randomSurface)
            }
        }
        if sleepy {
            if let s = randomSurface() { return route(to: s, surfaces: surfaces, body: body, world: world) }
            return .stretching(elapsed: 0, thenLie: true)
        }
        let (prop, propBonus) = pickProp(world: world)
        let choice = bestChoice(world: world, reachable: reachable, propBonus: propBonus)
        return finish(choice, body: body, surfaces: surfaces, world: world, prop: prop, randomSurface: randomSurface)
    }

    func sitHere(_ s: Surface, _ p: Perch) -> Activity {
        needs.boredom = 0
        sitT = 0
        return .sitting(surface: s.id, offset: p.x - s.minX, phase: .down, left: 15 + random() * 30)
    }

    func choosePerchedChoice(world: World) -> Choice {
        let (_, propBonus) = pickProp(world: world)
        return bestChoice(world: world, reachable: [], propBonus: propBonus, perched: true)
    }

    func bestChoice(world: World, reachable: [Surface], propBonus: Float, perched: Bool = false) -> Choice {
        let env = world.env
        let scored = Choice.allCases.map { c -> (Choice, Float) in
            var u = utility(c, canSit: perched || !reachable.isEmpty) + random() * 0.15
            if perched, c == .seekAttention { u = -1 }
            switch c {
            case .prop: u += propBonus * 0.5
            case .wander, .seekAttention: if env.typingHard { u -= 0.5 }
            case .sit, .rest: if env.lowBattery || env.heated { u += 0.2 }
            case .dance: if let beat = env.beat { u = 0.9 + beat.energy * 0.4 + needs.energy * 0.2 + max(needs.mood, 0) * 0.2 }
            default: break
            }
            return (c, u)
        }
        return scored.max { $0.1 < $1.1 }?.0 ?? .stand
    }

    func finish(_ choice: Choice, body: Body, surfaces: [Surface], world: World, prop: Prop,
                        randomSurface: () -> Surface?) -> Activity {
        let margin = body.height
        switch choice {
        case .stand:
            if random() < 0.4 { return .gesturing(index: pickGesture(), elapsed: 0) }
            idleMotion = random() > (world.env.app == .chat ? 0.4 : 0.75) ? .idlePhone : .idle
            return .standing(left: (8 + random() * 12) * restScale)
        case .rest:
            guard body.seatHeight > 0 else { return .standing(left: 8) }
            needs.boredom *= 0.3
            return .chair(phase: .down, left: 20 + random() * 30)
        case .gesture:
            needs.boredom *= 0.5
            return .gesturing(index: pickGesture(), elapsed: 0)
        case .wander:
            needs.boredom = 0
            if body.carryWalkSpeed > 0 && random() > 0.8 { walkMotion = .walkCarry }
            let exits = [world.exitLeft ? -1 : 0, world.exitRight ? 1 : 0].filter { $0 != 0 }
            if !exits.isEmpty, random() < 0.3 {
                let dir = exits[min(Int(random() * Float(exits.count)), exits.count - 1)]
                return .walking(to: dir > 0 ? world.width + body.height : -body.height, then: nil)
            }
            let span = max(world.width - 2 * margin, 1)
            var x = margin + random() * span
            if abs(x - body.root.x) < body.height * 2 {
                x = body.root.x + (body.root.x - margin > span / 2 ? -1 : 1) * body.height * 2
                x = min(max(x, margin), margin + span)
            }
            if !world.busy.isEmpty, let best = freestX(groundCandidates(body: body, world: world), body: body, world: world),
               busyness(best, body: body, world: world) < busyness(x, body: body, world: world) {
                x = best
            }
            return .walking(to: x, then: nil)
        case .sit:
            needs.boredom = 0
            guard let s = randomSurface() else { return .standing(left: 4) }
            return route(to: s, surfaces: surfaces, body: body, world: world)
        case .dance:
            needs.boredom = 0
            danceLegs = nil
            (danceFacing, danceTurn) = (0, nil)
            danceSection = world.env.beat?.section ?? 0
            (sectionChanged, phraseBars) = (false, 0)
            if world.env.beat?.beatInBar != nil { return .dancing(move: .waiting, moveLeft: 0, left: 60 + random() * 60) }
            return nextDance(world: world, left: 60 + random() * 60)
        case .prop:
            lastProp = prop
            needs.boredom *= 0.5
            if prop == .headphones {
                gestureProp = .headphones
                return .gesturing(index: pickGesture(contents: Self.inPlaceDances), elapsed: 0)
            }
            return .holding(prop: prop, left: 8 + random() * 10)
        case .seekAttention:
            let cursor = lastPointer?.x ?? body.root.x
            let side: Float = cursor > body.root.x ? -1 : 1
            let x = min(max(cursor + side * body.height * 0.5, margin), max(world.width - margin, margin))
            pendingGesture = 0
            needs.attention -= 0.3
            if abs(x - body.root.x) < body.height * 1.5 {
                pendingGesture = nil
                return .gesturing(index: pickGesture(contents: ["byebye", "bye", "wave", "call"]), elapsed: 0)
            }
            return .walking(to: x, then: nil)
        }
    }

    func doze(intent: inout Intent, target: inout [Float], body: Body) {
        intent.sleeping = true
        intent.look = body.root + [0, body.height * 0.3]
        target[Expression.eyesClosed.rawValue] = 1
    }
}
