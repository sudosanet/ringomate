import MascotCore
import CoreMedia
import Foundation

extension BeatTracker {
    func estimateTempo() -> Estimate? {
        let fr = Self.frameRate
        guard onsets.count > Int(fr * 4) else { return nil }
        let mean = onsets.reduce(0, +) / Float(onsets.count)
        let x = onsets.map { $0 - mean }
        let energy = x.reduce(0) { $0 + $1 * $1 }
        guard energy > 1e-6 else { return nil }
        let lo = Int(fr * 60 / 180), hi = Int(fr * 60 / 70)
        var ac = [Float](repeating: 0, count: hi + 2)
        for lag in lo...(hi + 1) {
            var r: Float = 0
            for i in lag..<x.count { r += x[i] * x[i - lag] }
            ac[lag] = r / energy
        }
        var best = (lag: lo, score: -Float.infinity)
        for lag in lo...hi {
            let bpm = Float(fr * 60) / Float(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 120) / 0.9, 2))
            let score = ac[lag] * (0.6 + 0.4 * prior)
            if score > best.score { best = (lag, score) }
        }
        func refine(_ l: Int) -> (lag: Float, peak: Float) {
            let (y0, y1, y2) = (ac[l - 1], ac[l], ac[l + 1])
            let denom = y0 - 2 * y1 + y2
            // 両側が平らだと分母が 0 に近く暴れるので ±0.5 まで
            let shift = abs(denom) > 1e-6 ? 0.5 * (y0 - y2) / denom : 0
            return (Float(l) + (shift.isFinite ? min(max(shift, -0.5), 0.5) : 0), y1)
        }
        var (lag, y1) = refine(best.lag)
        if let l = locked {
            let (a, b) = (max(lo, Int(l * 0.94)), min(hi, Int((l * 1.06).rounded(.up))))
            let near = a <= b ? (a...b).max { ac[$0] < ac[$1] } ?? best.lag : best.lag
            let ratio = lag / l
            let related = [0.5, 2.0, 1.5, 2.0 / 3.0, 1.0].contains { abs(ratio - $0) / $0 < 0.06 }
            if related {
                candidate = nil
                (lag, y1) = refine(near)
            } else if let c = candidate, abs(c.lag - lag) / lag < 0.04, c.count >= 3 {
                candidate = nil
            } else {
                candidate = (lag, (candidate.map { abs($0.lag - lag) / lag < 0.04 ? $0.count : 0 } ?? 0) + 1)
                (lag, y1) = refine(near)
            }
        }
        locked = lag
        let bpm = Float(fr * 60) / lag
        let period = Int(lag.rounded())
        let recent = Int(fr * 4)
        var bestOffset = (offset: 0, sum: -Float.infinity)
        for offset in 0..<period {
            var sum: Float = 0
            var i = onsets.count - 1 - offset
            while i >= onsets.count - recent, i >= 0 {
                sum += onsets[i]
                i -= period
            }
            if sum > bestOffset.sum { bestOffset = (offset, sum) }
        }
        let lastBeat = lastTime - Double(bestOffset.offset + 1) / fr
        onsetGrid = Self.accentGrid(low: lowOnsets, onsets: onsets, lastIndex: onsets.count - 1 - bestOffset.offset,
                                    lag: lag, lastBeat: lastBeat, frameRate: fr)
        let loudness = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
        return Estimate(bpm: bpm, lastBeat: lastBeat, confidence: min(1, max(0, y1 * 2)), loudness: loudness)
    }

    func stabilize(_ new: BarGrid?) -> BarGrid? {
        guard var g = new else { return stableGrid.flatMap { lastTime - $0.lastBeat < 20 ? $0 : nil } }
        if g.meter == 2 { g.meter = 4 }
        guard g.lastBeat != lastRawBeat else { return stableGrid ?? g }
        lastRawBeat = g.lastBeat
        guard let s = stableGrid else {
            stableGrid = g
            return g
        }
        if g.meter != s.meter {
            let count = pendingMeter?.meter == g.meter ? pendingMeter!.count + 1 : 1
            pendingMeter = (g.meter, count)
            if count < 3 { g.meter = s.meter } else { pendingMeter = nil }
        } else {
            pendingMeter = nil
        }
        let shift = ((Int(((g.lastDownbeat - s.lastDownbeat) / g.period).rounded()) % g.meter) + g.meter) % g.meter
        if shift != 0 {
            let count = pendingShift?.beats == shift ? pendingShift!.count + 1 : 1
            pendingShift = (shift, count)
            if count < 3 { g.lastDownbeat -= Double(shift) * g.period } else { pendingShift = nil }
        } else {
            pendingShift = nil
        }
        stableGrid = g
        return g
    }

    static func accentGrid(low: [Float], onsets: [Float], lastIndex: Int, lag: Float, lastBeat: Double, frameRate fr: Double) -> BarGrid? {
        guard low.count == onsets.count, lag > 1 else { return nil }
        var strengths: [Float] = []
        var k = 0
        let reach = max(1, Int(0.12 * fr))
        while true {
            let i = Int((Float(lastIndex) - Float(k) * lag).rounded())
            guard i - reach >= 0 else { break }
            strengths.append(low[(i - reach)...min(low.count - 1, i + reach)].max() ?? 0)
            k += 1
        }
        guard strengths.count >= 12 else { return nil }
        var best: (meter: Int, offset: Int, contrast: Float) = (4, 0, 0)
        for meter in [4, 3] {
            var sums = [Float](repeating: 0, count: meter), counts = [Float](repeating: 0, count: meter)
            for (k, v) in strengths.enumerated() { sums[k % meter] += v; counts[k % meter] += 1 }
            let means = zip(sums, counts).map { $0 / max($1, 1) }
            guard let top = means.indices.max(by: { means[$0] < means[$1] }) else { continue }
            let others = means.enumerated().filter { $0.offset != top }.map(\.element)
            let rest = others.reduce(0, +) / Float(max(others.count, 1))
            let contrast = (means[top] - rest) / max(means[top], 1e-4)
            if contrast * (meter == 4 ? 1.15 : 1) > best.contrast { best = (meter, top, contrast * (meter == 4 ? 1.15 : 1)) }
        }
        let period = Double(lag) / fr
        let meter = best.contrast > 0.2 ? best.meter : 4
        return BarGrid(period: period, lastBeat: lastBeat, lastDownbeat: lastBeat - Double(best.offset) * period,
                       meter: meter, confidence: min(1, best.contrast), source: .onsets)
    }

    static func mono(_ buffer: CMSampleBuffer) -> [Float]? {
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            buffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr
        else { return nil }
        return mixDown(UnsafeMutableAudioBufferListPointer(listPointer))
    }

    static func mixDown(_ buffers: UnsafeMutableAudioBufferListPointer) -> [Float]? {
        guard let first = buffers.first, first.mData != nil else { return nil }
        let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size / max(Int(first.mNumberChannels), 1)
        var out = [Float](repeating: 0, count: frames)
        var channels = 0
        for b in buffers {
            guard let data = b.mData else { continue }
            let n = max(Int(b.mNumberChannels), 1)
            let p = data.assumingMemoryBound(to: Float.self)
            let count = min(frames, Int(b.mDataByteSize) / MemoryLayout<Float>.size / n)
            for i in 0..<count {
                var sum: Float = 0
                for c in 0..<n { sum += p[i * n + c] }
                out[i] += sum
            }
            channels += n
        }
        if channels > 1 {
            let k = 1 / Float(channels)
            for i in out.indices { out[i] *= k }
        }
        return out
    }
}
