public struct ClipMap: Equatable, Sendable {
    /// `[from, to)` の基準の秒を、クリップの `clip + (t - from)` 秒へ写す区間。
    public struct Segment: Equatable, Sendable {
        public var from: Float
        public var to: Float
        public var clip: Float
    }

    public var segments: [Segment]

    public init(segments: [Segment] = []) { self.segments = segments }

    public static func single(offset: Float, length: Float) -> ClipMap {
        ClipMap(segments: [Segment(from: max(offset, 0), to: offset + length, clip: max(-offset, 0))])
    }

    public func map(_ t: Float) -> Float? {
        let s = segments
        let i = s.partitionPoint { $0.from <= t }
        return i > 0 && t < s[i - 1].to ? s[i - 1].clip + (t - s[i - 1].from) : nil
    }

    public static func fill(_ chroma: [Chroma12], _ base: ClipMap) -> ClipMap {
        let win = 40
        let top: Float = 0.97
        let jump: Float = 0.5
        let minRunFrames = 80
        let minMean: Float = 0.02
        let fps = Float(SongFeatures.chromaFPS)
        let n = chroma.count
        func t(_ k: Int) -> Float { Float(k) / fps }
        let src = (0..<n).filter { base.map(t($0)) != nil }
        let todo = (0..<n).filter { base.map(t($0)) == nil }
        if src.isEmpty || todo.isEmpty { return base }
        func sim(_ k: Int, _ j: Int) -> Float {
            let h = win / 2
            var (s, c): (Float, Int) = (0, 0)
            for w in 0..<win {
                let (a, b) = (k + w - h, j + w - h)
                if a >= 0, b >= 0, a < n, b < n {
                    var d: Float = 0
                    for q in 0..<12 { d += chroma[a][q] * chroma[b][q] }
                    s += d
                    c += 1
                }
            }
            return s / Float(max(c, 1))
        }
        let thr: [Float] = (0..<n).map { k in
            var v = stride(from: 0, to: n, by: 2).filter { abs($0 - k) > win }.map { sim(k, $0) }
            if v.isEmpty { return 1 }
            v.sort()
            return v[Int(Float(v.count - 1) * top)]
        }
        func scoreAt(_ k: Int, _ j: Int) -> Float { sim(k, j) - thr[k] }
        let minRun = min(minRunFrames, src.count * 9 / 10)
        let next: [Int?] = src.indices.map { $0 + 1 < src.count && src[$0 + 1] == src[$0] + 1 ? $0 + 1 : nil }
        var extra: [Segment] = []
        var runs: [(Int, Int)] = []
        var start = todo[0]
        for (a, b) in zip(todo, todo.dropFirst()) where b != a + 1 {
            runs.append((start, a + 1))
            start = b
        }
        runs.append((start, todo[todo.count - 1] + 1))
        let m = src.count
        for (a, b) in runs {
            var score = src.map { scoreAt(a, $0) } + [0]
            var back: [[Int]] = []
            for k in (a + 1)..<max(b, a + 1) {
                let best = (0...m).lastMax { score[$0] < score[$1] } ?? m
                var nxt = [Float](repeating: -.infinity, count: m + 1)
                var from = [Int](repeating: m, count: m + 1)
                for i in 0..<m {
                    if let j = next[i], score[i] > nxt[j] { nxt[j] = score[i]; from[j] = i }
                }
                if score[m] > nxt[m] { nxt[m] = score[m]; from[m] = m }
                for i in 0...m {
                    if score[best] - jump > nxt[i] { nxt[i] = score[best] - jump; from[i] = best }
                    nxt[i] += i < m ? scoreAt(k, src[i]) : 0
                }
                score = nxt
                back.append(from)
            }
            var state = (0...m).lastMax { score[$0] < score[$1] } ?? m
            var path = [state]
            for f in back.reversed() {
                state = f[state]
                path.append(state)
            }
            path.reverse()
            var k = 0
            while k < path.count {
                if path[k] == m { k += 1; continue }
                var e = k + 1
                while e < path.count && path[e] != m && src[path[e]] == src[path[e - 1]] + 1 { e += 1 }
                var sum: Float = 0
                for q in k..<e { sum += scoreAt(a + q, src[path[q]]) }
                if e - k >= minRun, sum / Float(e - k) >= minMean, let clip = base.map(t(src[path[k]])) {
                    extra.append(Segment(from: t(a + k), to: t(a + e), clip: clip))
                }
                k = e
            }
        }
        var segments = base.segments + extra
        // from の順、同じなら元の順
        segments = segments.enumerated().sorted { ($0.element.from, $0.offset) < ($1.element.from, $1.offset) }.map(\.element)
        return ClipMap(segments: segments)
    }
}
