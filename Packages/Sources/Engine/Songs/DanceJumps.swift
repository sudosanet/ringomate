import Foundation
import simd

public enum DanceJumps {
    public static let limit: Float = 10
    static var envLimit: Float { ProcessInfo.processInfo.environment["JUMPS_LIMIT"].flatMap(Float.init) ?? limit }
    static let spikeMax: Float = 0.4
    static let stepWindow: Float = 0.2

    public struct Jump: Sendable {
        public var frame: Int
        public var joint: String
        public var speed: Float
    }

    static func world(_ m: BVH.RawMotion, _ f: Int) -> [SIMD3<Float>] {
        var w = [simd_float4x4](repeating: matrix_identity_float4x4, count: m.names.count)
        for j in m.names.indices {
            let (t, r) = m.poses[f][j]
            let local = Math.matrix(r, t)
            w[j] = m.parents[j].map { Math.mul(w[$0], local) } ?? local
        }
        return w.map { $0.columns.3.xyz }
    }

    static func height(_ worlds: [[SIMD3<Float>]]) -> Float {
        let hs = worlds.map { w in (w.map(\.y).max() ?? -.greatestFiniteMagnitude) - (w.map(\.y).min() ?? .greatestFiniteMagnitude) }.sorted()
        return max(hs.isEmpty ? 1 : hs[hs.count / 2], 1e-6)
    }

    static func finger(_ name: String) -> Bool {
        ["thumb", "index", "middle", "ring", "pinky", "Thumb", "Index", "Middle", "Ring", "Pinky"].contains { name.contains($0) }
    }

    static func fastest(_ m: BVH.RawMotion, _ worlds: [[SIMD3<Float>]], _ a: Int, _ b: Int, _ h: Float) -> (Int, Float) {
        let dt = Float(b - a) / m.fps
        var speeds = m.names.indices.filter { !finger(m.names[$0]) }.map { j in (j, simd_length(worlds[a][j] - worlds[b][j]) / h / dt) }
        if speeds.isEmpty { return (0, 0) }
        let top = speeds.reduce((0, Float(0))) { $1.1 > $0.1 ? $1 : $0 }
        speeds.sort { $0.1 < $1.1 }
        return (top.0, speeds[speeds.count / 2].1)
    }

    public static func find(_ m: BVH.RawMotion) -> [Jump] {
        let worlds = m.poses.indices.map { world(m, $0) }
        let h = height(worlds), lim = envLimit
        return (1..<max(m.poses.count, 1)).compactMap { f in
            let (j, speed) = fastest(m, worlds, f - 1, f, h)
            return speed > lim ? Jump(frame: f, joint: m.names[j], speed: speed) : nil
        }
    }

    static func bridge(_ m: inout BVH.RawMotion, _ a: Int, _ b: Int) {
        let (pa, pb) = (m.poses[a], m.poses[b])
        for f in (a + 1)..<b {
            let t = Float(f - a) / Float(b - a)
            let s = t * t * (3 - 2 * t)
            m.poses[f] = zip(pa, pb).map { (Math.lerp($0.0, $1.0, s), simd_normalize(Math.slerp($0.1, $1.1, s))) }
        }
    }

    public static func repair(_ m: inout BVH.RawMotion) -> Int {
        let n = m.poses.count
        if n < 3 { return 0 }
        let spike = max(Int(spikeMax * m.fps), 1)
        let window = max(Int(stepWindow * m.fps), 1)
        var fixed = 0
        for _ in 0..<200 {
            let jumps = find(m)
            if jumps.isEmpty { break }
            var regions: [(Int, Int, Float)] = []
            for j in jumps {
                let d = j.speed / m.fps
                if let r = regions.last, j.frame <= r.1 + spike {
                    regions[regions.count - 1] = (r.0, j.frame, max(r.2, d))
                } else {
                    regions.append((j.frame - 1, j.frame, d))
                }
            }
            let worlds = (0..<n).map { world(m, $0) }
            let h = height(worlds)
            var nextFree = 0
            for (good, last, distance) in regions where good >= nextFree {
                let back = ((last + 1)..<max(min(last + spike, n), last + 1)).first { fastest(m, worlds, good, $0, h).1 < limit * 0.5 }
                if back == nil, let root = m.parents.firstIndex(where: { $0 == nil }) {
                    let delta = m.poses[last][root].0 - m.poses[good][root].0
                    if simd_length(delta) / h > 0.05 {
                        for f in last..<n { m.poses[f][root].0 -= delta }
                        fixed += 1
                        nextFree = n
                        continue
                    }
                }
                let need = Int((1.5 * distance * m.fps / (limit * 0.3) / 2).rounded(.up))
                let half = min(max(need, window), Int(m.fps))
                var (a, b) = back.map { (good, $0) } ?? (max(good - half, 0), min(last + half, n - 1))
                let cap = Int(m.fps)
                while fastest(m, worlds, a, b, h).1 * 1.5 > limit * 0.3 && (good - a < cap || b - last < cap) && (a > 0 || b < n - 1) {
                    a = max(a - (window / 2 + 1), 0)
                    b = min(b + window / 2 + 1, n - 1)
                }
                if b > a + 1 {
                    bridge(&m, a, b)
                    fixed += 1
                }
                nextFree = b + 1
            }
        }
        return fixed
    }
}
