import Foundation
import simd

struct Bust {
    struct Tuning {
        var frequency: Float = 2.2, damping: Float = 0.18, gravity: Float = 0.5, limit: Float = 0.6, strength: Float = 1

        static func fromEnvironment() -> Tuning {
            var t = Tuning()
            guard let v = Flags.value("MASCOT_BUST") else { return t }
            let fields = v.split(separator: ",", omittingEmptySubsequences: false)
            let paths: [WritableKeyPath<Tuning, Float>] = [\.frequency, \.damping, \.gravity, \.limit, \.strength]
            for (p, s) in zip(paths, fields) {
                if let x = Float(s.trimmingCharacters(in: .whitespaces)) { t[keyPath: p] = x }
            }
            return t
        }
    }

    struct Side {
        var bone: Int, parent: Int
        var center: SIMD3<Float>
        var limit: Float, peak: Float
        var pivot = SIMD3<Float>.zero
        var state: (SIMD3<Float>, SIMD3<Float>)?
        var target = SIMD3<Float>.zero
        var offset = SIMD3<Float>.zero
        var rotation = Math.identity
        var verts: [Int] = [], vweight: [Float] = [], rel: [SIMD3<Float>] = []
        var radius: Float = 1
        var inner: (SIMD3<Float>, SIMD3<Float>)?
        var wave = SIMD3<Float>.zero, stretch = SIMD3<Float>.zero
        var smooth: SIMD3<Float>?
    }

    static let swing: Float = 0.7

    static let gravity = SIMD3<Float>(0, -98, 0)

    var sides: [Side] = []
    var tuning = Tuning()

    init() {}

    init(_ pmx: inout PMXModel) {
        let tuning = Tuning.fromEnvironment()
        guard Optimize.enabled("bust"), tuning.strength > 0 else { return }
        let bones = pmx.bones
        let breast = bones.map { Self.isBreast($0.name) }
        let g = pmx.geometry
        var weight = [Float](repeating: 0, count: bones.count)
        var peak = [Float](repeating: 0, count: bones.count)
        var sum = [SIMD3<Float>](repeating: .zero, count: bones.count)
        let perVertex = max(g.skinIndices.count / max(g.positions.count / 3, 1), 1)
        func position(_ v: Int) -> SIMD3<Float> { SIMD3(g.positions[v * 3], g.positions[v * 3 + 1], g.positions[v * 3 + 2]) }
        for k in g.skinIndices.indices {
            let b = Int(g.skinIndices[k]), w = g.skinWeights[k]
            if w > 0, b < breast.count {
                let p = position(k / perVertex)
                weight[b] += w
                peak[b] = max(peak[b], w)
                sum[b] += p * w
            }
        }
        var chosen: [Bool: Int] = [:]
        for left in [true, false] {
            for i in bones.indices where breast[i] && weight[i] > 1 && Self.side(bones[i].name) == left {
                if chosen[left] == nil || weight[i] >= weight[chosen[left]!] { chosen[left] = i }
            }
        }
        if chosen.isEmpty, Optimize.analyzer("bust_detect"), let pair = BustDetect.pair(pmx, weight: weight, center: bones.indices.map { weight[$0] > 0 ? sum[$0] / weight[$0] : .zero },
                                                       height: Puppet.height(pmx)) {
            chosen = [true: pair.left, false: pair.right]
        }
        var sides: [Side] = []
        for left in [true, false] {
            guard let bone = chosen[left], bones[bone].parentIndex >= 0 else { continue }
            let parent = Int(bones[bone].parentIndex)
            let center = sum[bone] / weight[bone]
            var spread: Float = 0
            for k in g.skinIndices.indices where Int(g.skinIndices[k]) == bone && g.skinWeights[k] > 0 {
                let d = position(k / perVertex) - center
                spread += simd_dot(d, d) * g.skinWeights[k]
            }
            let size = (spread / weight[bone]).squareRoot()
            var side = Side(bone: bone, parent: parent, center: center - bones[parent].position, limit: size,
                            peak: max(peak[bone], 0.3), pivot: bones[bone].position - bones[parent].position)
            var vw: [Int: Float] = [:]
            for k in g.skinIndices.indices where Int(g.skinIndices[k]) == bone && g.skinWeights[k] > 0 { vw[k / perVertex, default: 0] += g.skinWeights[k] }
            let root = bones[bone].position
            let far = vw.keys.map { simd_distance(position($0), root) }.max() ?? 1
            side.radius = max(far, 1e-3)
            for v in vw.keys.sorted() {
                let tip = simd_distance(position(v), root) / side.radius
                side.verts.append(v)
                side.vweight.append(vw[v]! * pow(tip, 1.2))
                side.rel.append(position(v) - center)
            }
            sides.append(side)
        }
        if !sides.isEmpty {
            for i in pmx.rigidBodies.indices {
                let b = Int(pmx.rigidBodies[i].boneIndex)
                if b >= 0, b < breast.count, breast[b] || sides.contains(where: { $0.bone == b }), pmx.rigidBodies[i].mode != "static" {
                    pmx.rigidBodies[i].mode = "static"
                }
            }
        }
        for i in sides.indices { sides[i].limit *= tuning.limit }
        (self.sides, self.tuning) = (sides, tuning)
    }

    var bones: [Int] { sides.map(\.bone) }

    mutating func reset() {
        for i in sides.indices {
            sides[i].state = nil
            sides[i].offset = .zero
            sides[i].rotation = Math.identity
            sides[i].inner = nil
            sides[i].wave = .zero
            sides[i].stretch = .zero
            sides[i].smooth = nil
        }
    }

    /// `world` はモデル空間、`place` はモデル空間 → 画面の空間。
    mutating func advance(_ dt: Float, _ world: [simd_float4x4], _ place: simd_float4x4) {
        let t = tuning
        let up = Math.tau * t.frequency
        let placeRot = Math.rotationOf(place)
        for k in sides.indices {
            let omega0 = up * (1 + 0.04 * Float(k))
            let s = sides[k]
            guard s.parent < world.count else { continue }
            let parent = world[s.parent]
            let rot = Math.rotationOf(parent)
            let raw = Math.point(place, Math.point(parent, s.center))
            let target = s.smooth.map { $0 + (raw - $0) * (1 - exp(-dt * Math.tau * 12)) } ?? raw
            sides[k].smooth = target
            guard let st = s.state, dt > 0 else {
                sides[k].state = (target, .zero)
                sides[k].inner = (target, .zero)
                sides[k].target = target
                sides[k].offset = .zero
                sides[k].rotation = Math.identity
                (sides[k].wave, sides[k].stretch) = (.zero, .zero)
                continue
            }
            var (p, v) = st
            var (q, u) = s.inner ?? st
            let body = Math.mul(placeRot, rot)
            let toLocal = Math.inverse(body)
            let sag = (Self.gravity - Math.rotate(body, Self.gravity)) * t.gravity
            let n = Math.clamp((dt * 480).rounded(.up), 1, 32)
            let h = dt / n
            let targetVelocity = (target - s.target) / dt
            for i in 1...Int(n) {
                let goal = Math.lerp(s.target, target, Float(i) / n)
                // 胸の座標で x 左右・y 上下・z 前後（MMD の前は −z）
                let d = Math.rotate(toLocal, p - goal), dv = Math.rotate(toLocal, v - targetVelocity)
                let w = SIMD3<Float>(omega0 * 1.25, d.y > 0 ? omega0 : omega0 * 2.2, d.z > 0 ? omega0 * 2 : omega0 * 1.15)
                let zeta = SIMD3<Float>(t.damping * 1.4, d.y > 0 ? t.damping : t.damping * 0.6, t.damping)
                let stiffen = 1 + simd_length_squared(d) / max(2.25 * s.limit * s.limit, 1e-6)
                let thick = 1 + simd_length(dv) / max(omega0 * s.limit * 0.5, 1e-6)
                let a = -(d * w * w * stiffen) - dv * (2 * zeta * w * thick)
                v += (Math.rotate(body, a) + sag) * h
                p += v * h
                let di = Math.rotate(toLocal, q - goal), dvi = Math.rotate(toLocal, u - targetVelocity)
                let wi = w * 0.72, zi = zeta * 0.7
                let thicki = 1 + simd_length(dvi) / max(omega0 * s.limit * 0.5, 1e-6)
                let ai = -(di * wi * wi * (1 + simd_length_squared(di) / max(2.25 * s.limit * s.limit, 1e-6))) - dvi * (2 * zi * wi * thicki)
                u += (Math.rotate(body, ai) + sag) * h
                q += u * h
            }
            let finite = { (x: SIMD3<Float>) in x.x.isFinite && x.y.isFinite && x.z.isFinite }
            if !finite(p) || !finite(v) || !finite(q) || !finite(u) {
                sides[k].state = nil
                sides[k].offset = .zero
                sides[k].rotation = Math.identity
                (sides[k].wave, sides[k].stretch) = (.zero, .zero)
                continue
            }
            sides[k].state = (p, v)
            sides[k].inner = (q, u)
            sides[k].target = target
            let gain = t.strength / s.peak
            let lag = Math.rotate(toLocal, q - p) * gain, cap = s.radius * 0.25, len = simd_length(lag)
            sides[k].wave = len > 1e-6 ? lag * (cap * tanh(len / cap) / len) : .zero
            sides[k].stretch = Math.rotate(toLocal, p - target) * gain / s.radius
            let raw0 = Math.rotate(toLocal, p - target) * (t.strength / s.peak), top = s.radius * 0.4 * max(t.strength, 0.01)
            let len0 = simd_length(raw0)
            let d = len0 > 1e-6 ? raw0 * (top * tanh(len0 / top) / len0) : .zero
            let lever = s.center - s.pivot
            if simd_length(lever) > s.limit * 0.3 {
                sides[k].rotation = simd_quatf(from: simd_normalize(lever), to: simd_normalize(lever + d * Self.swing))
                sides[k].offset = d * (1 - Self.swing)
            } else {
                sides[k].rotation = Math.identity
                sides[k].offset = d
            }
        }
    }

    func apply(to out: UnsafeMutableBufferPointer<Float>) {
        for s in sides where !s.verts.isEmpty {
            let e = simd_length(s.stretch)
            let a = min(e, 0.3) * 0.6
            let dir = e > 1e-5 ? s.stretch / e : .zero
            for (i, v) in s.verts.enumerated() {
                let o = v * 3
                guard o + 2 < out.count else { continue }
                let r = s.rel[i]
                let along = dir * simd_dot(r, dir)
                let d = (s.wave + along * a - (r - along) * (a / 2)) * s.vweight[i]
                out[o] += d.x
                out[o + 1] += d.y
                out[o + 2] += d.z
            }
        }
    }

    var offsets: [(Int, SIMD3<Float>)] { sides.map { ($0.bone, $0.offset) } }
    var rotations: [(Int, simd_quatf)] { sides.map { ($0.bone, $0.rotation) } }

    static func isBreast(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["胸", "乳", "おっぱい", "bust", "breast", "oppai"].contains { Profile.contains(n, $0) }
            && !["上半身", "胸亲", "胸親", "chest", "upperchest", "decor", "飾", "ribbon", "リボン"].contains { Profile.contains(n, $0) }
    }

    static func side(_ name: String) -> Bool? {
        let n = name.lowercased()
        let c = { Profile.contains(n, $0) }
        if c("左") || n.hasSuffix("_l") || n.hasSuffix(".l") || c("_l_") || c("left") { return true }
        if c("右") || n.hasSuffix("_r") || n.hasSuffix(".r") || c("_r_") || c("right") { return false }
        return nil
    }
}
