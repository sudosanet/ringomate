import simd

public struct Hold: Sendable {
    /// 身長に対する比（前・下は首の付け根から）。
    var spread: Float, forward: Float, down: Float
    public var tap: Bool
    var oneHand = false, toMouth = false, fan = false
    /// 1 で持ったものを見る、負で見上げる。
    public var look: Float = 1

    public static func both(_ spread: Float, _ forward: Float, _ down: Float, _ tap: Bool) -> Hold {
        Hold(spread: spread, forward: forward, down: down, tap: tap)
    }

    public static let phone = both(0.07, 0.13, 0.09, true)
    public static let book = both(0.11, 0.15, 0.13, false)
    public static let styles: [(Slot, Hold)] = {
        var front = both(0.06, 0.14, 0.12, false)
        (front.oneHand, front.toMouth, front.look) = (true, true, 0.6)
        var up = both(0.16, 0.08, -0.04, false)
        (up.oneHand, up.look) = (true, -0.5)
        var fan = both(0, 0.1, 0, false)
        (fan.oneHand, fan.fan, fan.look) = (true, true, 0.2)
        var toy = both(0.05, 0.09, 0.16, false)
        toy.look = 0.8
        var two = both(0.12, 0.17, 0.1, true)
        two.look = 0.5
        return [(.holdFront, front), (.holdUp, up), (.fanSelf, fan), (.hugToy, toy), (.holdBoth, two)]
    }()
}

struct BodyShape {
    var torso: Float, headOffset: SIMD3<Float>, head: Float, arm: Float
}

/// ponytail: 指の曲げ軸は親の Z 軸で近似（PMX のボーンは向きを持たない）。
extension Puppet {
    static let fingerNames = ["親指", "人指", "中指", "薬指", "小指"]

    func b(_ name: String) -> Int? { Retarget.bone(model.pmx, model.profile.aliases, [name]) }

    func world(_ b: Int) -> simd_float4x4 { eval.pose.world[b] }

    func eval(_ f: BakedClip.Frame) {
        eval.pose.resetLocal()
        for (b, q) in f.rotations { eval.pose.localRotations[b] = q }
        if let (c, p) = f.center { eval.pose.localOffsets[c] = p }
        for (b, p) in f.feet { eval.pose.localOffsets[b] = p }
        for k in toeIKs { eval.pose.ikEnabled[k] = false }
        if f.feet.isEmpty { for k in legIKs { eval.pose.ikEnabled[k] = false } }
        props.hide(&eval.pose)
        eval.evaluate()
    }

    func armIK(_ side: String, _ target: SIMD3<Float>, _ pole: SIMD3<Float>) -> [(Int, simd_quatf)]? {
        armIK(world: { self.world($0) }, side, target, pole)
    }

    func armIK(world: (Int) -> simd_float4x4, _ side: String, _ target: SIMD3<Float>, _ pole: SIMD3<Float>) -> [(Int, simd_quatf)]? {
        guard let sh = b("\(side)肩"), let up = b("\(side)腕"), let el = b("\(side)ひじ"), let wr = b("\(side)手首") else { return nil }
        func pos(_ i: Int) -> SIMD3<Float> { world(i).columns.3.xyz }
        func rot(_ i: Int) -> simd_quatf { Math.rotationOf(world(i)) }
        let (s, e, w) = (pos(up), pos(el), pos(wr))
        let (a, bl) = (simd_distance(s, e), simd_distance(e, w))
        let to = target - s
        let d = Math.clamp(simd_length(to), abs(a - bl) + 1e-3, a + bl - 1e-3)
        let dir = Math.normalize(to, or: SIMD3(0, -1, 0))
        let p0 = pole - dir * simd_dot(pole, dir)
        let p = Math.tryNormalize(p0) ?? SIMD3(0, -1, 0)
        let cos = Math.clamp((a * a + d * d - bl * bl) / (2 * a * d), -1, 1)
        let elbow = s + dir * (a * cos) + p * (a * (1 - cos * cos).squareRoot())
        let hand = s + dir * d
        let r1 = Math.rotationArc(Math.normalizeOrZero(e - s), Math.normalizeOrZero(elbow - s))
        let r2 = Math.rotationArc(Math.normalizeOrZero(Math.rotate(r1, w - e)), Math.normalizeOrZero(hand - elbow))
        let upperWorld = Math.mul(r1, rot(up))
        let foreWorld = Math.mul(Math.mul(r2, r1), rot(el))
        return [(up, simd_normalize(Math.mul(Math.inverse(rot(sh)), upperWorld))),
                (el, simd_normalize(Math.mul(Math.inverse(upperWorld), foreWorld)))]
    }

    func bodyShape() -> BodyShape? {
        let bones = model.pmx.bones, g = model.pmx.geometry
        func rest(_ i: Int) -> SIMD3<Float> { bones[i].position }
        guard let spine = b("上半身"), let neck = b("首"), let head = b("頭") else { return nil }
        let spine2 = b("上半身2")
        let arms: [(Int, Int)] = ["左", "右"].compactMap { s in b("\(s)ひじ").flatMap { e in b("\(s)手首").map { (e, $0) } } }
        let per = max(g.skinIndices.count / max(g.positions.count / 3, 1), 1)
        func seg(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ c: SIMD3<Float>) -> Float {
            let ab = c - a
            let t = Math.clamp(simd_dot(p - a, ab) / max(simd_dot(ab, ab), 1e-6), 0, 1)
            return simd_length(p - (a + ab * t))
        }
        var torso: [Float] = [], skull: [SIMD3<Float>] = [], arm: [Float] = []
        for k in g.skinIndices.indices where g.skinWeights[k] >= 0.5 {
            let bone = Int(g.skinIndices[k]), v = k / per
            let p = SIMD3(g.positions[v * 3], g.positions[v * 3 + 1], g.positions[v * 3 + 2])
            if bone == spine || bone == spine2 {
                torso.append(seg(p, rest(spine), rest(neck)))
            } else if bone == head {
                skull.append(p)
            } else if let (e, w) = arms.first(where: { bone == $0.0 || bone == $0.1 }) {
                arm.append(seg(p, rest(e), rest(w)))
            }
        }
        func pct(_ v: [Float], _ q: Float) -> Float? {
            let s = v.sorted()
            let i = Int((Float(s.count) - 1) * q)
            return s.isEmpty || i < 0 ? nil : s[i]
        }
        let center = skull.reduce(SIMD3<Float>.zero, +) / Float(max(skull.count, 1))
        guard let headR = pct(skull.map { simd_distance($0, center) }, 0.85), let t = pct(torso, 0.9) else { return nil }
        return BodyShape(torso: t, headOffset: center - rest(head), head: headR, arm: pct(arm, 0.8) ?? 0)
    }

    /// `stop` から上は前フレームの値を使う。
    func animatedWorld(_ b: Int, stop: Int) -> simd_float4x4 {
        let bones = model.pmx.bones
        let p = Int(bones[b].parentIndex)
        if b == stop || p < 0 || p >= bones.count { return world(b) }
        let offset = bones[b].position - bones[p].position + eval.pose.localOffsets[b]
        return Math.mul(animatedWorld(p, stop: stop), Math.matrix(eval.pose.localRotations[b], offset))
    }

    func keepHandsOut() -> [([(Int, simd_quatf)], Float)] {
        guard let shape = body, let spine = b("上半身"), let neck = b("首"), let head = b("頭") else { return [] }
        func pos(_ i: Int) -> SIMD3<Float> { world(i).columns.3.xyz }
        let (s, n) = (pos(spine), pos(neck))
        let headCenter = Math.point(world(head), shape.headOffset)
        let (torso, skull) = (shape.torso + shape.arm, shape.head + shape.arm)
        func inside(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let ab = n - s
            let t = Math.clamp(simd_dot(p - s, ab) / max(simd_dot(ab, ab), 1e-6), 0, 1)
            let c = s + ab * t
            return [(c, torso), (headCenter, skull)].map { center, radius in
                let d = p - center
                return (Math.tryNormalize(d) ?? .zero) * max(radius - simd_length(d), 0)
            }.reduce(SIMD3<Float>.zero, +)
        }
        let bones = model.pmx.bones
        var out: [([(Int, simd_quatf)], Float)] = []
        for (side, sign) in [("左", Float(1)), ("右", -1)] {
            guard let sh = b("\(side)肩"), let up = b("\(side)腕"), let el = b("\(side)ひじ"), let wrist = b("\(side)手首") else { continue }
            let stop = bones[sh].parentIndex >= 0 ? Int(bones[sh].parentIndex) : sh
            let world = { (i: Int) in self.animatedWorld(i, stop: stop) }
            func at(_ i: Int) -> SIMD3<Float> { world(i).columns.3.xyz }
            let w = at(wrist)
            let hand = b("\(side)中指１").map(at) ?? w
            let (pw, ph) = (inside(w), inside(hand))
            let depth = max(simd_length(pw), simd_length(ph))
            if depth <= 0 { continue }
            let away = Math.tryNormalize(pw + ph) ?? simd_normalize(SIMD3(sign, 0, -1))
            var strength = Math.clamp(depth / (min(skull, torso) * 0.3), 0, 1)
            strength = strength * strength * (3 - 2 * strength)
            let (su, e) = (at(up), at(el))
            let pole = e - (su + w) * 0.5
            if let r = armIK(world: world, side, w + away * depth, pole) { out.append((r, strength)) }
        }
        return out
    }

    func fingers(_ side: String, _ curl: Float, _ thumb: Float) -> [(Int, simd_quatf)] {
        let sign: Float = side == "左" ? -1 : 1
        var out: [(Int, simd_quatf)] = []
        for f in Self.fingerNames {
            let (angle, joints) = f == "親指" ? (thumb, ["０", "１", "２"]) : (curl, ["１", "２", "３"])
            for j in joints { if let bone = b("\(side)\(f)\(j)") { out.append((bone, Math.rotZ(sign * angle))) } }
        }
        return out
    }

    static func push(_ frame: inout BakedClip.Frame, _ b: Int?, _ q: simd_quatf) {
        guard let b else { return }
        if let i = frame.rotations.firstIndex(where: { $0.0 == b }) {
            frame.rotations[i].1 = Math.mul(q, frame.rotations[i].1)
        } else {
            frame.rotations.append((b, q))
        }
    }

    static func replace(_ frame: inout BakedClip.Frame, with extra: [(Int, simd_quatf)]) {
        frame.rotations.removeAll { r in extra.contains { $0.0 == r.0 } }
        frame.rotations += extra
    }

    /// 手首 → 中指の付け根を `dir` へ、小指 → 人差し指の付け根を `across` へ向ける手首の親ローカル回転。
    func gripWrist(_ side: String, _ dir: SIMD3<Float>, _ across: SIMD3<Float>) -> (Int, simd_quatf)? {
        guard let w = b("\(side)手首") else { return nil }
        func pos(_ n: String) -> SIMD3<Float>? { b("\(side)\(n)").map { world($0).columns.3.xyz } }
        let wrist = world(w)
        guard let m1 = pos("中指１"), let i1 = pos("人指１"), let p1 = pos("小指１") else { return nil }
        let hand = Math.normalizeOrZero(m1 - wrist.columns.3.xyz)
        var knuckles = i1 - p1
        knuckles = Math.normalizeOrZero(knuckles - hand * simd_dot(hand, knuckles))
        if hand == .zero || knuckles == .zero { return nil }
        func frame(_ x: SIMD3<Float>, _ y: SIMD3<Float>) -> simd_float3x3 { simd_float3x3(x, y, simd_cross(x, y)) }
        let turn = simd_normalize(simd_quatf(frame(dir, across) * frame(hand, knuckles).transpose))
        let parent = Int(model.pmx.bones[w].parentIndex)
        guard parent >= 0 else { return nil }
        let pr = Math.rotationOf(world(parent)), wr = Math.rotationOf(wrist)
        return (w, simd_normalize(Math.mul(Math.mul(Math.inverse(pr), turn), wr)))
    }

    /// 指のないクリップにふんわり曲げた指を足す。
    func relaxFingers() {
        let fingerBones = Set(["左", "右"].flatMap { fingers($0, 0, 0) }.map(\.0))
        for slot in Array(motions.keys) {
            let (curl, thumb): (Float, Float)
            switch slot {
            case .walk, .walkCalm: (curl, thumb) = (0.45, 0.25)
            case .wave, .stretch, .gesture: (curl, thumb) = (0.15, 0.1)
            default: continue
            }
            let extra = ["左", "右"].flatMap { fingers($0, curl, thumb) }
            guard var clip = motions[slot] else { continue }
            for i in clip.frames.indices where !clip.frames[i].rotations.contains(where: { fingerBones.contains($0.0) }) {
                clip.frames[i].rotations += extra
            }
            motions[slot] = clip
        }
    }

    func resetToIdle() {
        if let f = motions[.idle]?.frames.first { eval(f) }
    }
}
