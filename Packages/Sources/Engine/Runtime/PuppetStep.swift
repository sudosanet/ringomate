import Foundation
import simd

extension Puppet {
    /// 物理を `intent` の姿勢で初期化し直す。
    public func teleport(_ intent: Intent) {
        root = intent.root
        facing = intent.facing
        rootVelocity = nil
        bust.reset()
        eval.resetIKHistory()
        pose(intent, 0)
        if physics != nil {
            eval.evaluateBeforePhysics()
            resetPhysics()
        } else {
            eval.evaluate()
        }
    }

    static let builtDances = Dance.legs.count * Dance.arms.count

    func pose(_ intent: Intent, _ dt: Float) {
        let head = procedural.head.flatMap { $0 < eval.pose.world.count ? eval.pose.world[$0].columns.3.xyz : nil }
        let toLocal = Math.rotY(-intent.facing)
        let gaze = procedural.gaze(dt, head: head, target: intent.look.map { Math.rotate(toLocal, $0 - intent.root) })
        let grooveOK: Bool = switch intent.motion {
        case .idle, .idlePhone, .holdFront, .holdUp, .hugToy, .holdBoth, .fanSelf: true
        default: false
        }
        procedural.groove(dt, intent.beat.map { ($0.phase, $0.energy) }, on: grooveOK)
        let life = procedural.life()
        let morphs = procedural.morphWeights(intent.expressions)
        let offset = procedural.sway()
        let wrists = props.wristPositions(eval.pose.world)
        let rightKnuckles = props.rightKnuckles(eval.pose.world)
        let want: Float = intent.point != nil ? 1 : 0
        pointWeight += Math.clamp(want - pointWeight, -dt / 0.3, dt / 0.3)
        if let t = intent.point { pointTarget = Math.rotate(toLocal, t - intent.root) }
        let w = pointWeight * pointWeight * (3 - 2 * pointWeight)
        let point = w > 0 ? armIK("右", pointTarget, SIMD3(-0.5, -1, 0.3)) : nil
        player.apply(motions, &eval.pose, toeIKs: toeIKs)
        var handsOut: [([(Int, simd_quatf)], Float)] = []
        if case let .dance(i) = player.current, Int(i) >= Self.builtDances, Optimize.enabled("hands_out") { handsOut = keepHandsOut() }
        let base: Slot = switch player.current {
        case .dance, .beatStep, .beatClap, .beatPoint, .idlePhone, .holdFront, .holdUp, .fanSelf, .hugToy, .holdBoth: .idle
        case .sitRead, .sitSwing: .sit
        default: player.current
        }
        var level = headLevel[base] ?? Math.identity
        if player.current == .hug { level = Math.mul(Math.rotX(0.6 * (1 - procedural.drowsy)), level) }
        headCorrection = Math.slerp(headCorrection, level, 1 - exp(-dt * 3))
        if Self.fkLegs(player.current) {
            for k in legIKs { eval.pose.ikEnabled[k] = false }
        } else if case .dance = player.current {
            for (k, seed) in kneeSeeds { eval.pose.localRotations[k] = Math.mul(seed, eval.pose.localRotations[k]) }
        } else if player.fading {
            for (k, seed) in kneeSeeds { eval.pose.localRotations[k] = Math.mul(seed, eval.pose.localRotations[k]) }
        }
        if let h = procedural.head { eval.pose.localRotations[h] = Math.mul(headCorrection, eval.pose.localRotations[h]) }
        if let (b, down) = procedural.bounce(props.height) { eval.pose.localOffsets[b] += down }
        for (b, o) in procedural.kick() { eval.pose.localOffsets[b] += o }
        for r in procedural.roots { eval.pose.localOffsets[r] += offset }
        let dancing: Bool = switch player.current {
        case .dance, .beatStep, .beatClap, .beatPoint: true
        default: false
        }
        danceTime = dancing ? danceTime + dt : 0
        let fadeIn = min(danceTime / 1.5, 1)
        var wobble: [(Int, simd_quatf)] = []
        if dancing {
            let t = danceTime
            func wave(_ seed: Float) -> Float {
                let f: [Float] = [0.13, 0.31, 0.47, 0.71], ws: [Float] = [0.45, 0.3, 0.17, 0.08]
                var sum: Float = 0
                for i in 0..<4 { sum += ws[i] * sin(Math.tau * f[i] * t + seed * (1.7 + Float(i) * 2.3)) }
                return sum
            }
            wobble = danceWobble.map { b, amp, seed in
                let a = amp * fadeIn
                let q = Math.mul(Math.mul(Math.rotX(a.x * wave(seed)), Math.rotY(a.y * wave(seed + 11))), Math.rotZ(a.z * wave(seed + 23)))
                return (b, q)
            }
        }
        for (bone, extra) in gaze + life + wobble { eval.pose.localRotations[bone] = Math.mul(extra, eval.pose.localRotations[bone]) }
        for (r, k) in handsOut {
            for (bone, q) in r { eval.pose.localRotations[bone] = Math.slerp(eval.pose.localRotations[bone], q, k) }
        }
        for (bone, q) in point ?? [] { eval.pose.localRotations[bone] = Math.slerp(eval.pose.localRotations[bone], q, w) }
        for (bone, d) in bust.offsets { eval.pose.localOffsets[bone] += d }
        for (bone, r) in bust.rotations { eval.pose.localRotations[bone] = Math.mul(r, eval.pose.localRotations[bone]) }
        let request = PropPlacement.Request(slot: intent.motion, held: intent.held,
                                            puttingAwayPhone: player.previous == .idlePhone && player.fading,
                                            handProp: intent.prop, rightKnuckles: rightKnuckles)
        let newPuffs = props.place(request, wrists: wrists, head: head, pose: &eval.pose)
        let place = Math.matrix(Math.rotY(facing), root + SIMD3(0, 1, 0) * ground)
        puffs += newPuffs.map { p, size in
            let q = Math.point(place, p)
            return SIMD3(q.x, q.y, size)
        }
        let wantFace: Float = faceSlots.contains(player.current) ? 1 : 0
        clipFace += Math.clamp(wantFace - clipFace, -dt / 0.4, dt / 0.4)
        let keep = 1 - clipFace
        let mouth = mouthSlots.contains(player.current) ? [] : procedural.mouthMorphs()
        for (m, wt) in morphs {
            let k = mouth.contains(m) ? 1 : keep
            eval.pose.morphWeights[m] = max(eval.pose.morphWeights[m], wt * k)
        }
        eval.expandMorphs()
    }

    public func step(_ dt: Float, _ intent: Intent) {
        if intent.sleeping && settled >= Self.settleSeconds && intent.root == root { return }
        let wasFK = Self.fkLegs(player.current)
        player.request(intent.motion)
        if case .dance = player.current, let beat = intent.beat, let target = beat.clip, player.time == 0,
           let (tempo, mult, len) = clipBeats(beat.bpm) {
            player.time = Math.remEuclid(target, len) * 60 * mult / tempo
        }
        if case .dance = player.current, let song = intent.song {
            if player.time == 0 {
                player.time = max(song.clipTime, 0)
            } else if abs(song.clipTime - player.time) > 1 {
                player.restart()
                player.time = max(song.clipTime, 0)
            }
        }
        if wasFK != Self.fkLegs(player.current) { smoothLegIKSwitch(leavingFK: wasFK) }
        let want = beatRate(intent)
        rate += (want - rate) * (1 - exp(-dt * 4))
        let (slot0, time0) = (player.current, player.time)
        let wrapped = player.advance(dt * rate, motions)
        if wrapped { eval.resetIKHistory() }
        rootMotion = 0
        if let (track, fps) = rootTracks[slot0], !wrapped, dt > 0, player.current == slot0, !track.isEmpty {
            func at(_ t: Float) -> Float {
                let x = Math.clamp(t * fps, 0, Float(track.count - 1))
                let i = Int(x.rounded(.down)), f = Math.fract(x)
                return track[i] + (track[min(i + 1, track.count - 1)] - track[i]) * f
            }
            rootMotion = (at(player.time) - at(time0)) / dt * cos(intent.facing)
        }
        procedural.feel(dt, intent.expressions)
        let air: Air? = switch intent.motion {
        case .fall: .held
        case .falling: .falling
        case .thrown: .thrown
        default: nil
        }
        let velocity = Math.rotate(Math.rotY(-intent.facing), rootVelocity ?? .zero)
        procedural.advance(dt, idle: intent.motion == .idle, air: air, velocity: velocity)
        let onFloor: Bool = switch intent.motion {
        case .hug: true
        case .sitDown, .sit, .sitRead, .sitSwing, .standUp: !intent.held
        default: false
        }
        procedural.sitOnFloor(dt, onFloor)
        let accel = trackRoot(dt, intent.root)
        facing = intent.facing
        pose(intent, dt)
        stepPhysics(dt, accel: accel, surfaces: intent.surfaces)
        settleFeet(dt)
        bust.advance(dt, eval.pose.world, place())
        trackSettle(dt, intent.sleeping)
    }

    func trackSettle(_ dt: Float, _ sleeping: Bool) {
        guard sleeping else {
            settled = 0
            lastPositions = []
            return
        }
        let now = eval.pose.world.map { $0.columns.3.xyz }
        let still = lastPositions.count == now.count && zip(now, lastPositions).allSatisfy { simd_length($0 - $1) < Self.settleEpsilon }
        settled = still ? settled + dt : 0
        lastPositions = now
    }

    func trackRoot(_ dt: Float, _ r: SIMD3<Float>) -> SIMD3<Float> {
        guard dt > 0 else { return .zero }
        let v = (r - root) / dt
        let a = rootVelocity.map { (v - $0) / dt } ?? .zero
        root = r
        rootVelocity = v
        return Math.clampLengthMax(a, Self.maxRootAccel)
    }

    func tempo(of slot: Slot) -> Float? {
        if let t = tempos[slot] { return t }
        let t = motions[slot].flatMap(Self.clipTempo)
        tempos[slot] = .some(t)
        return t
    }

    static func multiple(_ bpm: Float, _ tempo: Float) -> Float {
        var best: Float = 0.5
        for m in [Float(1), 2] where abs(log(bpm * m / tempo)) < abs(log(bpm * best / tempo)) { best = m }
        return best
    }

    func clipBeats(_ bpm: Float) -> (Float, Float, Float)? {
        let slot = player.current
        guard let tempo = tempo(of: slot) else { return nil }
        let mult = Self.multiple(bpm, tempo)
        let len = duration(of: slot) * tempo / 60 / mult
        return len > 0.5 ? (tempo, mult, len) : nil
    }

    func beatRate(_ intent: Intent) -> Float {
        if case .dance = player.current, let song = intent.song {
            let error = Math.clamp(song.clipTime - player.time, -1, 1)
            return Math.clamp(song.rate * (1 + 0.5 * error), 0.5, 2)
        }
        guard let beat = intent.beat, beat.bpm > 0 else { return 1 }
        let slot = player.current
        switch slot {
        case .dance, .beatStep, .beatClap, .beatPoint: break
        default: return 1
        }
        guard let tempo = tempo(of: slot) else { return 1 }
        let mult = Self.multiple(beat.bpm, tempo)
        let rate = beat.bpm * mult / tempo
        let len = duration(of: slot) * tempo / 60 / mult
        let error: Float
        if let target = beat.clip, len > 0.5 {
            let now = player.time * tempo / 60 / mult
            error = Math.remEuclid(Math.remEuclid(target - now, len) + len / 2, len) - len / 2
        } else {
            let clipPhase = Math.fract(player.time * tempo / 60 / mult)
            error = Math.remEuclid(beat.phase - clipPhase + 1.5, 1) - 0.5
        }
        return Math.clamp(rate * (1 + 0.25 * Math.clamp(error, -1, 1)), 0.75, 1.35)
    }

    static func clipTempo(_ b: BakedClip) -> Float? {
        guard b.frames.count >= Int(b.fps * 2) else { return nil }
        let speed: [Float] = (1..<b.frames.count).map { k in
            let (w0, w1) = (b.frames[k - 1], b.frames[k])
            var turn: Float = 0
            for (bone, q) in w1.rotations {
                if let p = w0.rotations.first(where: { $0.0 == bone })?.1 { turn += Math.angleBetween(p, q) }
            }
            var bob: Float = 0
            if let (_, a) = w0.center, let (_, c) = w1.center { bob = abs(c.y - a.y) }
            return turn + bob
        }
        let half = Int(b.fps / 2)
        let x: [Float] = speed.indices.map { i in
            let (a, c) = (max(i - half, 0), min(i + half, speed.count - 1))
            var sum: Float = 0
            for j in a...c { sum += speed[j] }
            return speed[i] - sum / Float(c - a + 1)
        }
        var variance: Float = 0
        for v in x { variance += v * v }
        guard variance > 0 else { return nil }
        let (lo, hi) = (Int(b.fps * 60 / 180), Int(b.fps * 60 / 70))
        var best: (Int, Float)?
        let upper = min(hi, x.count / 2)
        guard max(lo, 1) <= upper else { return nil }
        for lag in max(lo, 1)...upper {
            var r: Float = 0
            for (a, c) in zip(x, x[lag...]) { r += a * c }
            if best == nil || r / variance >= best!.1 { best = (lag, r / variance) }
        }
        guard let best, best.1 > 0.25 else { return nil }
        return 60 * b.fps / Float(best.0)
    }
}
