import MascotCore
import Foundation
import simd

extension Mascot {
    var isDragging: Bool {
        if case .dragging = state { return true }
        return false
    }

    var isReacting: Bool {
        if case .reacting = state { return true }
        return false
    }

    func targetFacing(_ intent: Intent) -> Float {
        intent.walkVelocity > 0 ? -.pi / 2 : (intent.walkVelocity < 0 ? .pi / 2 : intent.facing)
    }

    func react(pointer: Pointer, moved: SIMD2<Float>, body: Body, intent: inout Intent, target: inout [Float]) {
        switch state {
        case .idle, .reacting:
            if pointer.pressed && pointer.released, let part = pointer.part {
                startClickReaction(part, intent: &intent)
            } else if pointer.pressed, let part = pointer.part {
                state = .pressing(start: pointer.location, part: part, grab: pointer.location - body.root)
            } else if pointer.part == .head, detectStroke(moved.x) {
                state = .reacting(.petted, left: 0.8)
                needs.record(.petted)
            }
        case let .pressing(start, part, grab):
            if pointer.released {
                startClickReaction(part, intent: &intent)
            } else if simd_length(pointer.location - start) > Self.dragThreshold {
                state = .dragging(grab: grab)
                needs.record(.touched)
                intent.drag = .hold(pointer.location - grab)
            }
        case let .dragging(grab):
            if pointer.released {
                intent.drag = .release
                draggedAway = true
                state = .falling
                releaseY = body.root.y
            } else {
                intent.drag = .hold(pointer.location - grab)
            }
        case .falling:
            if body.grounded {
                state = .reacting(.landed, left: 0.6)
                if let y = releaseY, y - body.root.y > body.height { needs.record(.dropped) }
                releaseY = nil
            }
        }

        if case let .reacting(reaction, _) = state {
            switch reaction {
            case .giggle:
                target[Expression.smile.rawValue] = 1
                target[Expression.blush.rawValue] = 0.6
                target[Expression.mouthOpen.rawValue] = 0.4
            case .surprised:
                target[Expression.surprise.rawValue] = 1
                target[Expression.mouthOpen.rawValue] = 0.5
            case .petted:
                target[Expression.calm.rawValue] = 1
                target[Expression.blush.rawValue] = 0.5
            case .landed:
                target[Expression.smile.rawValue] = 0.4
                if needs.mood < Needs.baselineMood - 0.15 { target[Expression.angry.rawValue] = 0.7 }
            case .waving:
                target[Expression.smile.rawValue] = 0.8
                target[Expression.mouthOpen.rawValue] = 0.2
            }
        }
        if case .dragging = state {
            if simd_length(moved) / max(1e-3, Self.frameDt) > body.height * 2 {
                target[Expression.surprise.rawValue] = 0.7
                target[Expression.mouthOpen.rawValue] = 0.45
            } else {
                target[Expression.blush.rawValue] = 0.45
                target[Expression.smile.rawValue] = 0.3
                target[Expression.mouthOpen.rawValue] = 0.1
            }
        }
        if case .falling = state {
            let thrown = (lastRootSpeed ?? 0) > 45
            target[Expression.surprise.rawValue] = thrown ? 1 : 0.7
            target[Expression.mouthOpen.rawValue] = thrown ? 0.7 : 0.45
        }
    }

    func tickReaction(dt: Float) {
        if case let .reacting(reaction, left) = state {
            state = left - dt > 0 ? .reacting(reaction, left: left - dt) : .idle
        }
    }

    func startClickReaction(_ part: Part, intent: inout Intent) {
        intent.clicked = true
        if part == .head {
            state = .reacting(.giggle, left: 1.4)
            needs.record(.giggled)
            if activity.onGround { intent.hop = 18 }
        } else if part == .hand, activity.onGround, !activity.moving {
            state = .reacting(.waving, left: Self.waveSeconds)
            activity = .standing(left: Self.waveSeconds + 1)
            needs.record(.waved)
        } else {
            state = .reacting(.surprised, left: 1.0)
            needs.record(.touched)
            if activity.onGround { intent.hop = 9 }
        }
    }

    func expressMood(dt: Float, pointer: Pointer, body: Body, target: inout [Float]) {
        guard !intentSleepy else { return }
        var base = [Float](repeating: 0, count: Expression.allCases.count)
        func set(_ e: Expression, _ w: Float) { base[e.rawValue] = max(base[e.rawValue], w) }
        if needs.mood > 0.4 { set(.mouthOpen, 0.1) }
        if simd_length(pointer.location - (body.root + [0, body.height * 0.7])) < body.height * 1.5 {
            set(.blush, 0.25)
            set(.mouthOpen, 0.15)
        }
        switch activity {
        case .walking where needs.cheerful:
            set(.mouthOpen, 0.18)
            set(.blush, 0.15)
        case let .gesturing(index, _) where index >= Self.gestureCount:
            libraryExpression(index, set: set)
        case let .gesturing(index, _) where index >= 0:
            switch index % Self.gestureCount {
            case 0: set(.smile, 0.85); set(.mouthOpen, 0.3)
            case 1: set(.calm, 0.7); set(.smile, 0.4)
            case 2: set(.mouthOpen, 0.6); set(.smile, 0.3)
            case 3: set(.smile, 0.6); set(.mouthOpen, 0.4)
            case 4: set(.smile, 0.9); set(.blush, 0.3); set(.mouthOpen, 0.3)
            case 5: set(.smile, 1); set(.mouthOpen, 0.5)
            case 7: set(.smile, 0.6); set(.mouthOpen, 0.15)
            default: set(.smile, 0.8); set(.mouthOpen, 0.2)
            }
        default:
            break
        }
        if pendingGesture != nil {
            set(.mouthOpen, 0.25)
            set(.blush, 0.3)
        }
        if var a = acting {
            a.left -= dt
            acting = a.left > 0 ? a : nil
            for (i, w) in a.weights.enumerated() where w > 0 {
                set(Expression(rawValue: i)!, w * min(1, a.left / 0.3))
            }
        }
        if var f = flicker {
            f.left -= dt
            flicker = f.left > 0 ? f : nil
            set(f.expression, f.weight * min(1, f.left * 3))
        } else if time >= nextFlicker {
            if case .standing = activity, !intentSleepy {
                let choices: [(Expression, Float)] = [(.smile, 0.6), (.blush, 0.6), (.mouthOpen, 0.4), (.wink, 1)]
                let c = choices[min(Int(random() * Float(choices.count)), choices.count - 1)]
                flicker = (c.0, c.1, 0.8 + random() * 0.8)
            }
            nextFlicker = time + 9 + random() * 9
        }
        for i in target.indices { target[i] = max(target[i], base[i]) }
    }

    var intentSleepy: Bool { sleepiness > Self.sleepThreshold }

    func greet(body: Body) {
        let asleep = sleepiness > Self.sleepThreshold
        defer { wasAsleep = asleep }
        guard state == .idle, body.grounded, case .standing = activity else { return }
        if !greeted || (wasAsleep && !asleep) {
            greeted = true
            state = .reacting(.waving, left: Self.waveSeconds)
        }
    }

    func detectStroke(_ dx: Float) -> Bool {
        guard abs(dx) > 0.05 else { return false }
        let direction: Float = dx > 0 ? 1 : -1
        if direction != lastStrokeDirection {
            lastStrokeDirection = direction
            strokes.append(time)
        }
        strokes.removeAll { time - $0 > Self.strokeWindow }
        if strokes.count >= Self.strokesToPet {
            strokes.removeAll()
            return true
        }
        return false
    }

    func updateDesires(dt: Float, world: World, touched: Bool) {
        needs.update(dt: dt, activity: activity, world: world, touched: touched)
        userActive = world.userIdleSeconds < 30
    }

    func expressAgent(dt: Float, agent: Agent, body: Body, intent: inout Intent, target: inout [Float]) {
        let entered = agent.state != lastAgent
        lastAgent = agent.state
        agentTimer = entered ? 0 : agentTimer + dt
        guard state == .idle || isReacting else { return }
        switch agent.state {
        case .waitingPermission:
            intent.bubble = permissionLine ?? String(localized: "Waiting for your approval!", bundle: #bundle)
            intent.sleeping = false
            target[Expression.surprise.rawValue] = max(target[Expression.surprise.rawValue], 0.4)
            if entered && activity.onGround { intent.hop = 14 }
        case .waitingInput:
            if agentTimer.truncatingRemainder(dividingBy: 4) < 1 { intent.look = intent.look ?? body.root + [0, body.height] }
        case .failed:
            target[Expression.troubled.rawValue] = max(target[Expression.troubled.rawValue], 0.8)
            target[Expression.surprise.rawValue] = max(target[Expression.surprise.rawValue], 0.3)
            target[Expression.mouthOpen.rawValue] = max(target[Expression.mouthOpen.rawValue], 0.2)
        case .done where agentTimer < 2.5:
            target[Expression.smile.rawValue] = 1
            if entered && activity.onGround { intent.hop = 14 }
        case .reading, .writing, .running, .working:
            if case .sitting = activity { intent.look = body.root + [0, -body.height * 0.5] }
        case .thinking:
            if entered, activity.onGround, case .standing = activity { activity = .gesturing(index: 7, elapsed: 0) }
            intent.look = intent.look ?? body.root + [0, body.height]
        case .delegating:
            if entered, activity.onGround, case .standing = activity { state = .reacting(.waving, left: Self.waveSeconds) }
        case .compacting:
            if entered, activity.onGround, case .standing = activity { activity = .stretching(elapsed: 0, thenLie: false) }
        default:
            break
        }
    }

    func unlessDismissed(_ agent: Agent) -> Agent {
        if draggedAway {
            draggedAway = false
            if agent.calling { dismissedCall = agent.state }
        }
        if dismissedCall != agent.state { dismissedCall = nil }
        guard dismissedCall != nil else { return agent }
        var agent = agent
        (agent.window, agent.surfaceID) = (nil, nil)
        return agent
    }
}
