public enum SongAlign {
    public static func video(_ video: [Float], _ version: [Float], rate: Int, span: (Double, Double)) -> (map: TimeMap, score: Float, agree: Float)? {
        let r = Double(rate)
        func cut(_ s: [Float], _ a: Double, _ b: Double) -> [Float] {
            Array(s[min(Int(a * r), s.count)..<min(Int(b * r), s.count)])
        }
        let (lo, hi) = (max(span.0, 0), min(span.1, Double(video.count) / r))
        var index = SongIndex()
        index.add(0, Chromaprint.fingerprint(version, rate: rate))
        index.finish()
        var offsets: [Double] = []
        var t = lo
        while t + 10 <= hi {
            if let h = index.lookup(Chromaprint.fingerprint(cut(video, t, t + 10), rate: rate), minVotes: 8).first {
                offsets.append(h.offset - t)
            }
            t += 5
        }
        if offsets.isEmpty {
            let part = cut(video, lo, hi)
            let (map, _) = SongWarp.align(SongFeatures.chroma(part, rate: rate), SongFeatures.chroma(version, rate: rate),
                                          SongFeatures.onset(part), SongFeatures.onset(version))
            guard Double(map.points.count) >= hi - lo else { return nil }
            return (TimeMap(points: map.points.map { SIMD2($0.x + Float(lo), $0.y) }), 0, 1)
        }
        offsets.sort()
        let coarse = offsets[offsets.count / 2]
        let fps = SongFeatures.onsetFPS
        let (vo, ro) = (SongFeatures.onset(video), SongFeatures.onset(version))
        var pts: [(t: Double, lag: Double, c: Float)] = []
        var tried = 0
        t = lo + 4
        while t + 4 <= hi {
            tried += 1
            let (a, b) = (Int((t - 4) * fps), min(Int((t + 4) * fps), vo.count))
            if b > a + 200 {
                let win = Array(vo[a..<b])
                let center = Int(((t - 4 + coarse) * fps).rounded())
                // 同じ値なら後のもの
                var best: (Int, Float)?
                for k in -50...50 {
                    let c = SongFeatures.ncc(win, ro, center + k)
                    if best == nil || c >= best!.1 { best = (k, c) }
                }
                if let (k, c) = best, c > 0.3 { pts.append((t, coarse + Double(k) / fps, c)) }
            }
            t += 4
        }
        guard pts.count >= 2 else {
            return (TimeMap(points: [SIMD2(Float(lo), Float(lo + coarse)), SIMD2(Float(hi), Float(hi + coarse))]), 0, 0)
        }
        let lags = pts.map(\.lag)
        let keep = pts.enumerated().filter { i, p in
            let near = lags[max(i - 2, 0)..<min(i + 3, lags.count)].sorted()
            return abs(p.lag - near[near.count / 2]) < 0.1
        }.map(\.1)
        guard let first = keep.first, let last = keep.last else { return nil }
        let agree = Float(keep.count) / Float(tried)
        let scores = keep.map(\.c).sorted()
        var points = [SIMD2(Float(lo), Float(lo + first.lag))]
        points += keep.map { SIMD2(Float($0.t), Float($0.t + $0.lag)) }
        points.append(SIMD2(Float(hi), Float(hi + last.lag)))
        return (TimeMap(points: points), scores[scores.count / 2], agree)
    }
}
