import simd

extension BakedClip {
    /// 足首の向きは FK で出すので、つま先 IK は切る。
    func apply(_ t: Float, _ pose: inout Pose, toeIKs: [Int]) {
        if let vmd { return vmd.apply(t, &pose) }  // VMD はつま先 IK も VMD のまま
        pose.resetLocal()
        guard !frames.isEmpty else { return }
        let x = min(max(t * fps, 0), Float(frames.count - 1))
        let i = Int(x.rounded(.down)), a = x - x.rounded(.down)
        let f0 = frames[i], f1 = frames[min(i + 1, frames.count - 1)]
        for ((bone, q0), (_, q1)) in zip(f0.rotations, f1.rotations) { pose.localRotations[bone] = Math.slerp(q0, q1, a) }
        if let (c, p0) = f0.center, let (_, p1) = f1.center { pose.localOffsets[c] = Math.lerp(p0, p1, a) }
        for ((k, p0), (_, p1)) in zip(f0.feet, f1.feet) { pose.localOffsets[k] = Math.lerp(p0, p1, a) }
        for k in toeIKs { pose.ikEnabled[k] = false }
    }
}

struct Player {
    var current: Slot = .idle
    var previous: Slot = .idle
    var time: Float = 0
    var from: Base?
    var fade: Float = 0
    var fadeLength: Float = 0
    var last: Base?

    struct Base {
        var rotations: [simd_quatf], offsets: [SIMD3<Float>], morphs: [Float]
        init(_ p: Pose) { (rotations, offsets, morphs) = (p.localRotations, p.localOffsets, p.morphWeights) }
    }

    /// それより後の番号は曲の踊り。
    static let builtDances = 23 * 22

    init() {}

    static func resolve(_ motions: [Slot: BakedClip], _ slot: Slot) -> BakedClip? {
        if let m = motions[slot] { return m }
        switch slot {
        case .walkCalm, .walkCarry: if let m = motions[.walk] { return m }
        case .sitRead, .sitSwing: if let m = motions[.sit] { return m }
        case .falling, .thrown: if let m = motions[.fall] { return m }
        default: break
        }
        return motions[.idle]
    }

    static func fadeSeconds(_ from: Slot, _ to: Slot) -> Float {
        switch (from, to) {
        case (_, .hug), (.hug, _): return 1.0
        case let (.dance(a), .dance(b)) where Int(max(a, b)) >= builtDances: return 0.9
        case (.dance, .dance): return 0.4
        case (_, .land), (.land, _): return 0.2
        case (_, .fall), (_, .falling), (_, .thrown), (.fall, _), (.falling, _), (.thrown, _): return 0.25
        case (.walk, .walk), (.walk, .walkCalm), (.walkCalm, .walk), (.walkCalm, .walkCalm): return 0.6
        case (_, .gesture), (_, .wave), (.gesture, _), (.wave, _): return 0.5
        case (_, .walk), (_, .walkCalm), (.walk, _), (.walkCalm, _): return 0.35
        default: return 0.45
        }
    }

    mutating func request(_ slot: Slot) {
        guard slot != current else { return }
        previous = current
        from = last
        fadeLength = Self.fadeSeconds(current, slot)
        current = slot
        time = 0
        fade = 0
    }

    mutating func restart() {
        from = last
        fadeLength = 0.45
        time = 0
        fade = 0
    }

    mutating func patchFrom(rotations: [(Int, simd_quatf)], offsets: [(Int, SIMD3<Float>)]) {
        guard from != nil else { return }
        for (b, q) in rotations where b < from!.rotations.count { from!.rotations[b] = q }
        for (b, o) in offsets where b < from!.offsets.count { from!.offsets[b] = o }
    }

    var fading: Bool { from != nil }

    /// ループで先頭に戻ったら true。
    @discardableResult
    mutating func advance(_ dt: Float, _ motions: [Slot: BakedClip]) -> Bool {
        time += dt
        var wrapped = false
        if let m = Self.resolve(motions, current) {
            let d = m.duration
            if d > 0 && time > d {
                if current.looping {
                    time = time.truncatingRemainder(dividingBy: d)
                    wrapped = true
                } else {
                    time = d
                }
            }
        }
        fade = min(fade + dt / max(fadeLength, 1e-3), 1)
        if fade >= 1 { from = nil }
        return wrapped
    }

    func finished(_ motions: [Slot: BakedClip]) -> Bool {
        guard !current.looping else { return false }
        return Self.resolve(motions, current).map { time >= $0.duration } ?? true
    }

    mutating func apply(_ motions: [Slot: BakedClip], _ pose: inout Pose, toeIKs: [Int]) {
        guard let cur = Self.resolve(motions, current) else {
            pose.resetLocal()
            return
        }
        let d = cur.duration
        cur.apply(current.looping && d > 0 ? time.truncatingRemainder(dividingBy: d) : min(time, d), &pose, toeIKs: toeIKs)
        if let from {
            let w = fade * fade * (3 - 2 * fade)
            for i in from.rotations.indices {
                pose.localRotations[i] = Math.slerp(from.rotations[i], pose.localRotations[i], w)
                pose.localOffsets[i] = Math.lerp(from.offsets[i], pose.localOffsets[i], w)
            }
            for i in from.morphs.indices { pose.morphWeights[i] = from.morphs[i] + (pose.morphWeights[i] - from.morphs[i]) * w }
        }
        last = Base(pose)
    }
}
