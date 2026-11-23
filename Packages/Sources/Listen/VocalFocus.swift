import MascotCore
import Accelerate
import Foundation

// ponytail: 伴奏が真ん中にも多い曲では伴奏も残る。分けたいなら曲のパックの事前計算を使う
final class VocalFocus: @unchecked Sendable {
    static let inputRate = 24_000.0
    static let size = 1024
    static let hop = 256

    private let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window: [Float] = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false).map { sqrt($0) }
    private var left: [Float] = [], right: [Float] = []
    private var overlap = [Float](repeating: 0, count: size)
    private var history: [[Float]] = []
    private var phase = 0.0
    private var carry: [Float] = []

    init() {}

    func push(left l: [Float], right r: [Float]) -> [Float] {
        left += l
        right += r
        var voice: [Float] = []
        while left.count >= Self.size {
            voice += frame(Array(left[0..<Self.size]), Array(right[0..<Self.size]))
            left.removeFirst(Self.hop)
            right.removeFirst(Self.hop)
        }
        return resample(voice)
    }

    private func frame(_ l: [Float], _ r: [Float]) -> [Float] {
        let half = Self.size / 2
        let spec = { (x: [Float]) -> ([Float], [Float]) in
            var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
            let w = vDSP.multiply(x, self.window)
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var s = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    w.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &s, 1, vDSP_Length(half)) }
                    self.fft.forward(input: s, output: &s)
                }
            }
            return (re, im)
        }
        let (lr, li) = spec(l), (rr, ri) = spec(r)
        var mr = [Float](repeating: 0, count: half), mi = [Float](repeating: 0, count: half)
        var mag = [Float](repeating: 0, count: half)
        for k in 0..<half {
            let (sr, si) = ((lr[k] + rr[k]) * 0.5, (li[k] + ri[k]) * 0.5)
            let e = lr[k] * lr[k] + li[k] * li[k] + rr[k] * rr[k] + ri[k] * ri[k]
            let c = e > 1e-12 ? 2 * (sr * sr + si * si) / e : 0
            let center = max(0, min(1, (c - 0.7) / 0.3))
            (mr[k], mi[k]) = (sr * center, si * center)
            mag[k] = sqrt(mr[k] * mr[k] + mi[k] * mi[k])
        }
        history.append(mag)
        if history.count > 8 { history.removeFirst() }
        let binHz = Float(Self.inputRate) / Float(Self.size)
        for k in 0..<half {
            let f = Float(k) * binHz
            guard f >= 150, f <= 7600 else {
                (mr[k], mi[k]) = (0, 0)
                continue
            }
            let h = median(history.map { $0[k] })
            let p = median(Array(mag[max(0, k - 8)...min(half - 1, k + 8)]))
            let keep = h * h / max(h * h + p * p, 1e-12)
            mr[k] *= keep
            mi[k] *= keep
        }
        var out = [Float](repeating: 0, count: Self.size)
        mr.withUnsafeMutableBufferPointer { rp in
            mi.withUnsafeMutableBufferPointer { ip in
                var s = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                s.imagp[0] = 0
                fft.inverse(input: s, output: &s)
                out.withUnsafeMutableBytes { vDSP_ztoc(&s, 1, $0.bindMemory(to: DSPComplex.self).baseAddress!, 2, vDSP_Length(half)) }
            }
        }
        // vDSP の往復は 2N 倍になる
        out = vDSP.multiply(1 / Float(Self.size * 2 * 2), vDSP.multiply(out, window))
        overlap = vDSP.add(overlap, out)
        let done = Array(overlap[0..<Self.hop])
        overlap = Array(overlap[Self.hop...]) + [Float](repeating: 0, count: Self.hop)
        return done
    }

    private func median(_ v: [Float]) -> Float {
        let s = v.sorted()
        return s[s.count / 2]
    }

    private func resample(_ x: [Float]) -> [Float] {
        let input = carry + x
        var out: [Float] = []
        let step = Self.inputRate / LipSync.rate
        while phase + 1 < Double(input.count) {
            let i = Int(phase), f = Float(phase - Double(i))
            out.append(input[i] * (1 - f) + input[i + 1] * f)
            phase += step
        }
        let used = Int(phase)
        carry = Array(input[used...])
        phase -= Double(used)
        return out
    }
}
