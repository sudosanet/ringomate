import simd

/// 脚のねじれの裏返り（太ももとすねが骨の軸のまわりに 1 コマで大きく回る）を見つけて直す。
/// ひざの曲げ軸は太ももに対して決まっているので、曲げ軸がその向きからずれたコマを骨の軸のまわりに回して戻す。
/// 骨の軸のまわりの回転なので関節の位置は変わらない。ずれの小さいコマには触らない。
public enum DanceFlips {
    /// これより大きい曲げ軸のずれを裏返りとみなす。
    static let flipDegrees: Float = 45
    /// これより曲がっているときだけ曲げ軸が決まる。
    static let bentDegrees: Float = 15
    /// 区間の前後で補正を 0 から 1 へ寄せるコマ数。
    static let blendFrames = 3

    public struct Flip: Sendable {
        public var limb: String
        public var start: Int, end: Int
        public var degrees: Float
    }

    struct Limb {
        var name: String
        var upper: Int, lower: Int, end: Int
    }

    static func limbs(_ m: BVH.RawMotion) -> [Limb] {
        func index(_ n: String) -> Int? { m.names.firstIndex(of: n) }
        return ["Left", "Right"].compactMap { side in
            guard let u = index("\(side)UpLeg"), let l = index("\(side)Leg"), let e = index("\(side)Foot") else { return nil }
            return Limb(name: "\(side)Leg", upper: u, lower: l, end: e)
        }
    }

    static func worldRotations(_ m: BVH.RawMotion, _ f: Int) -> [simd_float4x4] {
        var w = [simd_float4x4](repeating: matrix_identity_float4x4, count: m.names.count)
        for j in m.names.indices {
            let (t, r) = m.poses[f][j]
            let local = Math.matrix(r, t)
            w[j] = m.parents[j].map { Math.mul(w[$0], local) } ?? local
        }
        return w
    }

    /// コマごとの、骨の軸のまわりのずれ（ラジアン、曲げ軸が決まらないコマは前後から補間）。
    static func twistErrors(_ limb: Limb, _ worlds: [[simd_float4x4]], bone: Int) -> [Float] {
        let n = worlds.count
        var hinge = [SIMD3<Float>?](repeating: nil, count: n)
        var axis = [SIMD3<Float>](repeating: .zero, count: n)
        for f in 0..<n {
            let w = worlds[f]
            let (p0, p1, p2) = (w[limb.upper].columns.3.xyz, w[limb.lower].columns.3.xyz, w[limb.end].columns.3.xyz)
            let a = simd_normalize(p1 - p0), b = simd_normalize(p2 - p1)
            let inv = Math.rotationOf(w[bone]).inverse
            axis[f] = simd_normalize(inv.act(bone == limb.upper ? a : b))
            let c = simd_cross(a, b)
            if simd_length(c) > sin(bentDegrees * .pi / 180) { hinge[f] = simd_normalize(inv.act(simd_normalize(c))) }
        }
        let bent = hinge.compactMap { $0 }
        guard bent.count >= 10 else { return [Float](repeating: 0, count: n) }
        func median(_ x: [Float]) -> Float { x.sorted()[x.count / 2] }
        let ref = simd_normalize(SIMD3(median(bent.map(\.x)), median(bent.map(\.y)), median(bent.map(\.z))))
        var err = [Float?](repeating: nil, count: n)
        for f in 0..<n {
            guard let h = hinge[f] else { continue }
            let ax = axis[f]
            let r = simd_normalize(ref - ax * simd_dot(ref, ax)), q = simd_normalize(h - ax * simd_dot(h, ax))
            err[f] = atan2(simd_dot(simd_cross(r, q), ax), simd_dot(r, q))
        }
        // 曲げ軸が決まらないコマは前後の値を補間（角度は前から連続になるように）
        var out = [Float](repeating: 0, count: n)
        var last: (Int, Float)?
        var f = 0
        while f < n {
            if let e = err[f] {
                out[f] = e
                last = (f, e)
                f += 1
                continue
            }
            var g = f
            while g < n && err[g] == nil { g += 1 }
            let next = g < n ? err[g] : nil
            for k in f..<g {
                switch (last, next) {
                case let ((i, a)?, b?):
                    var d = b - a
                    d = atan2(sin(d), cos(d))
                    out[k] = a + d * Float(k - i) / Float(g - i)
                case let ((_, a)?, nil): out[k] = a
                case let (nil, b?): out[k] = b
                default: out[k] = 0
                }
            }
            f = g
        }
        return out
    }

    static func regions(_ err: [Float]) -> [(Int, Int, Float)] {
        let limit = flipDegrees * .pi / 180
        var out: [(Int, Int, Float)] = []
        var f = 0
        while f < err.count {
            guard abs(err[f]) > limit else { f += 1; continue }
            var g = f, worst: Float = 0
            while g < err.count && abs(err[g]) > limit {
                worst = max(worst, abs(err[g]))
                g += 1
            }
            out.append((f, g, worst * 180 / .pi))
            f = g
        }
        return out
    }

    public static func find(_ m: BVH.RawMotion) -> [Flip] {
        let worlds = m.poses.indices.map { worldRotations(m, $0) }
        return limbs(m).flatMap { limb in
            let err = twistErrors(limb, worlds, bone: limb.upper)
            return regions(err).map { Flip(limb: limb.name, start: $0.0, end: $0.1, degrees: $0.2) }
        }
    }

    /// 直した区間の数。
    @discardableResult
    public static func repair(_ m: inout BVH.RawMotion) -> Int {
        var fixed = 0
        for limb in limbs(m) {
            let worlds = m.poses.indices.map { worldRotations(m, $0) }
            let upper = twistErrors(limb, worlds, bone: limb.upper)
            let found = regions(upper)
            guard !found.isEmpty else { continue }
            var weight = [Float](repeating: 0, count: m.poses.count)
            for (s, e, _) in found {
                for f in max(s - blendFrames, 0)..<min(e + blendFrames, m.poses.count) {
                    let ramp = f < s ? Float(f - (s - blendFrames)) / Float(blendFrames + 1)
                        : f >= e ? Float(e + blendFrames - f) / Float(blendFrames + 1) : 1
                    weight[f] = max(weight[f], ramp)
                }
            }
            let lower = twistErrors(limb, worlds, bone: limb.lower)
            for f in m.poses.indices where weight[f] > 0 {
                let w = worlds[f]
                let parent = m.parents[limb.upper].map { Math.rotationOf(w[$0]) } ?? Math.identity
                var wu = Math.rotationOf(w[limb.upper]), wl = Math.rotationOf(w[limb.lower])
                let we = Math.rotationOf(w[limb.end])
                let a = simd_normalize(w[limb.lower].columns.3.xyz - w[limb.upper].columns.3.xyz)
                let b = simd_normalize(w[limb.end].columns.3.xyz - w[limb.lower].columns.3.xyz)
                wu = simd_normalize(simd_quatf(angle: upper[f] * weight[f], axis: a) * wu)
                // すねは太ももと同じだけ回すと曲げ軸が保たれる（すね自身のずれが小さければそのまま）
                let lowerFix = abs(lower[f]) > flipDegrees * .pi / 180 ? lower[f] : upper[f]
                wl = simd_normalize(simd_quatf(angle: lowerFix * weight[f], axis: b) * wl)
                m.poses[f][limb.upper].1 = simd_normalize(parent.inverse * wu)
                m.poses[f][limb.lower].1 = simd_normalize(wu.inverse * wl)
                m.poses[f][limb.end].1 = simd_normalize(wl.inverse * we)
            }
            fixed += found.count
        }
        return fixed
    }
}
