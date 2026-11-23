/// 点は (x: 元の秒, y: 写した先の秒)。
public struct TimeMap: Equatable, Sendable {
    public var points: [SIMD2<Float>]

    static let maxGap: Float = 2.5

    public init(points: [SIMD2<Float>] = []) { self.points = points }

    static func identity(_ seconds: Float) -> TimeMap { TimeMap(points: [SIMD2(0, 0), SIMD2(seconds, seconds)]) }

    public func map(_ t: Float) -> Float? {
        let p = points
        let i = p.partitionPoint { $0.x <= t }
        guard i > 0, i < p.count else { return nil }
        let (a, b) = (p[i - 1], p[i])
        if b.x - a.x > Self.maxGap && !(a.x == 0 && p.count == 2) { return nil }
        return a.y + (t - a.x) / max(b.x - a.x, 1e-6) * (b.y - a.y)
    }

    func slope(_ t: Float) -> Float? {
        let p = points
        let i = p.partitionPoint { $0.x <= t }
        guard i > 0, i < p.count else { return nil }
        return (p[i].y - p[i - 1].y) / max(p[i].x - p[i - 1].x, 1e-6)
    }
}

enum SongWarp {
    public static func align(_ v: [Chroma12], _ r: [Chroma12], _ vOnset: [Float], _ rOnset: [Float]) -> (TimeMap, Int) {
        let (n, m) = (v.count, r.count)
        if n == 0 || m == 0 { return (TimeMap(), 0) }
        func dot(_ a: Chroma12, _ b: Chroma12, _ rot: Int) -> Float {
            var s: Float = 0
            for k in 0..<12 { s += a[(k + rot) % 12] * b[k] }
            return s
        }
        func mean(_ c: [Chroma12]) -> Chroma12 {
            var m = Chroma12(repeating: 0, count: 12)
            for f in c { for k in 0..<12 { m[k] += f[k] } }
            return m
        }
        let (mv, mr) = (mean(v), mean(r))
        let rot = (0..<12).lastMax { dot(mv, mr, $0) < dot(mv, mr, $1) } ?? 0
        let skip: Float = 0.6
        var d = [Float](repeating: .infinity, count: (n + 1) * (m + 1))
        var step = [UInt8](repeating: 0, count: (n + 1) * (m + 1))
        func at(_ i: Int, _ j: Int) -> Int { i * (m + 1) + j }
        for j in 0...m { d[at(0, j)] = 0 }
        for i in 1...n {
            d[at(i, 0)] = Float(i) * skip
            for j in 1...m {
                let c = 1 - dot(v[i - 1], r[j - 1], rot)
                let diag = d[at(i - 1, j - 1)] + c, up = d[at(i - 1, j)] + skip, left = d[at(i, j - 1)] + skip
                let (best, s): (Float, UInt8) = diag <= up && diag <= left ? (diag, 0) : up <= left ? (up, 1) : (left, 2)
                d[at(i, j)] = best
                step[at(i, j)] = s
            }
        }
        // 同じ値なら先のもの
        var j = (1...m).min { d[at(n, $0)] < d[at(n, $1)] } ?? m
        var i = n
        var pairs: [(Int, Int)] = []
        while i > 0 && j > 0 {
            switch step[at(i, j)] {
            case 0: pairs.append((i - 1, j - 1)); i -= 1; j -= 1
            case 1: i -= 1
            default: j -= 1
            }
        }
        pairs.reverse()
        let sims = pairs.map { dot(v[$0.0], r[$0.1], rot) }
        func good(_ k: Int) -> Bool {
            let (a, b) = (max(k - 4, 0), min(k + 4, sims.count - 1))
            var s: Float = 0
            for q in a...b { s += sims[q] }
            return s / Float(b - a + 1) > 0.35
        }
        let fps = Float(SongFeatures.chromaFPS)
        var points = pairs.indices.filter { good($0) && $0 % 5 == 0 }
            .map { SIMD2(Float(pairs[$0].0) / fps, Float(pairs[$0].1) / fps) }
        refine(&points, vOnset, rOnset)
        return (TimeMap(points: points), rot)
    }

    static func refine(_ points: inout [SIMD2<Float>], _ v: [Float], _ r: [Float]) {
        if points.count < 3 || v.isEmpty || r.isEmpty { return }
        var s = zip(points, points.dropFirst()).filter { $1.x - $0.x < TimeMap.maxGap }.map { ($1.y - $0.y) / ($1.x - $0.x) }
        s.sort()
        if s.isEmpty || abs(s[s.count / 2] - 1) > 0.03 { return }
        let fps = Float(SongFeatures.onsetFPS)
        for k in points.indices {
            let (vc, rc) = (Int(points[k].x * fps), Int(points[k].y * fps))
            let (a, b) = (max(vc - 500, 0), min(vc + 500, v.count))
            if b <= a + 200 { continue }
            let win = Array(v[a..<b])
            let base = rc - (vc - a)
            if let k2 = (-15...15).lastMax(by: { SongFeatures.ncc(win, r, base + $0) < SongFeatures.ncc(win, r, base + $1) }),
               SongFeatures.ncc(win, r, base + k2) > 0.5 {
                points[k].y += Float(k2) / fps
            }
        }
        let offs = points.map { $0.y - $0.x }
        for k in points.indices {
            let near = offs[max(k - 2, 0)..<min(k + 3, offs.count)].sorted()
            let med = near[near.count / 2]
            if abs(offs[k] - med) > 0.1 { points[k].y = points[k].x + med }
        }
    }
}
