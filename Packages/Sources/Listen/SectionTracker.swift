import MascotCore
import Foundation

struct SectionTracker {
    private(set) var index = 0
    private(set) var intensity: Float = 0.5
    private(set) var barsSince = 0
    private(set) var lastNovelty: Float = 0
    private(set) var lastUsual: Float = 0
    private var frame: [Float] = []
    private var frameCount = 0
    private var bars: [[Float]] = []
    private var loudness: [Float] = []
    private var novelty: [Float] = []
    private var nextDownbeat: Double?

    mutating func push(_ f: [Float], loud: Float) {
        if frame.count != f.count + 1 { frame = [Float](repeating: 0, count: f.count + 1); frameCount = 0 }
        for i in f.indices { frame[i] += f[i] }
        frame[f.count] += loud
        frameCount += 1
    }

    @discardableResult
    mutating func update(grid: BarGrid?, now: Double) -> Bool {
        guard let g = grid else { return false }
        let bar = g.period * Double(g.meter)
        if nextDownbeat == nil || abs((nextDownbeat ?? 0) - now) > bar * 4 {
            let k = ((now - g.lastDownbeat) / bar).rounded(.up)
            nextDownbeat = g.lastDownbeat + k * bar
            frame = frame.map { _ in 0 }
            frameCount = 0
            return false
        }
        guard let next = nextDownbeat, now >= next, frameCount > 0 else { return false }
        let k = ((next - g.lastDownbeat) / bar).rounded()
        nextDownbeat = g.lastDownbeat + (k + 1) * bar
        let mean = frame.map { $0 / Float(frameCount) }
        frame = frame.map { _ in 0 }
        frameCount = 0
        let loud = mean.last ?? 0
        bars.append(Array(mean.dropLast()))
        loudness.append(loud)
        if bars.count > 64 { bars.removeFirst(); loudness.removeFirst() }
        barsSince += 1
        let recent = loudness.suffix(32)
        if let lo = recent.min(), let hi = recent.max(), hi - lo > 1e-3 {
            intensity = (loud - lo) / (hi - lo)
        }
        guard bars.count >= 6 else { return true }
        func average(_ rows: ArraySlice<[Float]>) -> [Float] {
            var s = [Float](repeating: 0, count: rows.first!.count)
            for r in rows { for i in r.indices { s[i] += r[i] } }
            return s.map { $0 / Float(rows.count) }
        }
        let a = average(bars.suffix(2)), b = average(bars.suffix(6).prefix(4))
        let d = (zip(a, b).map { ($0 - $1) * ($0 - $1) }.reduce(0, +) / Float(a.count)).squareRoot()
        let usual = novelty.sorted().dropFirst(novelty.count / 2).first ?? d
        (lastNovelty, lastUsual) = (d, usual)
        novelty.append(d)
        if novelty.count > 32 { novelty.removeFirst() }
        let gain: Float = barsSince % 8 == 0 ? 1.35 : barsSince % 4 == 0 ? 1.6 : 2.2
        let recentLoud = loudness.suffix(2).reduce(0, +) / 2
        let beforeLoud = loudness.suffix(6).prefix(4).reduce(0, +) / 4
        let range = max((loudness.suffix(32).max() ?? 0) - (loudness.suffix(32).min() ?? 0), 1e-3)
        let lift = (recentLoud - beforeLoud) / range
        if novelty.count >= 4, barsSince >= 4, (d > usual * gain && d > 0.05) || (lift > 0.35 && barsSince % 4 == 0) {
            index += 1
            barsSince = 0
        }
        return true
    }

    mutating func reset() { self = SectionTracker() }
}
