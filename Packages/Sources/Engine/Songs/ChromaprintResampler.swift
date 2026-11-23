import Foundation

/// 同梱の `analysis.bin` と同じ指紋になるよう、arm64 の NEON の積和（2 本ずつ 4 組の FMA）の順まで同じにする。
struct SincResampler {
    static let sincLen = 16, factor = 128
    let chunkMax: Int
    var chunk: Int
    let ratio: Double
    var lastIndex = -Double(sincLen / 2)
    var buffer: [Double]
    /// sincs[subindex][0..<16]
    let sincs: [[Double]]

    init(ratio: Double, chunk: Int) {
        self.ratio = ratio
        chunkMax = chunk
        self.chunk = chunk
        buffer = [Double](repeating: 0, count: chunk + 2 * Self.sincLen)
        let cutoff: Float = ratio >= 1 ? 0.8 : 0.8 * Float(ratio)
        sincs = Self.makeSincs(Self.sincLen, Self.factor, Double(cutoff))
    }

    static func makeSincs(_ npoints: Int, _ factor: Int, _ cutoff: Double) -> [[Double]] {
        let total = npoints * factor
        let (pi2, pi4, np) = (2.0 * Double.pi, 4.0 * Double.pi, Double(total))
        var y: [Double] = []
        var sum = 0.0
        for x in 0..<total {
            let xf = Double(x)
            let w = 0.42 - 0.5 * cos(pi2 * xf / np) + 0.08 * cos(pi4 * xf / np)
            let v = (xf - Double(total / 2)) * cutoff / Double(factor)
            let s = v == 0 ? 1 : sin(v * Double.pi) / (v * Double.pi)
            let val = w * s
            sum += val
            y.append(val)
        }
        sum /= Double(factor)
        var sincs = [[Double]](repeating: [Double](repeating: 0, count: npoints), count: factor)
        for p in 0..<npoints {
            for n in 0..<factor { sincs[factor - n - 1][p] = y[factor * p + n] / sum }
        }
        return sincs
    }

    var outputFramesNext: Int { Int(Double(chunk) * (0.5 * ratio + 0.5 * ratio) + 10) }

    mutating func process(_ input: ArraySlice<Double>) -> [Double] {
        let len = Self.sincLen
        var tRatio = 1 / ratio
        let tRatioEnd = 1 / ratio
        let approx = Double(chunk) * (0.5 * ratio + 0.5 * ratio)
        let increment = (tRatioEnd - tRatio) / approx
        let endIdx = Double(chunk - (len + 1) - Int(tRatioEnd.rounded(.up)))
        for i in 0..<(2 * len) { buffer[i] = buffer[chunk + i] }
        for i in 0..<chunk { buffer[2 * len + i] = input[input.startIndex + i] }
        var idx = lastIndex
        var out: [Double] = []
        out.reserveCapacity(outputFramesNext)
        buffer.withUnsafeBufferPointer { buf in
            while idx < endIdx {
                tRatio += increment
                idx += tRatio
                var index = Int(idx.rounded(.down))
                var sub = Int(((idx - idx.rounded(.down)) * Double(Self.factor)).rounded())
                if sub >= Self.factor {
                    sub -= Self.factor
                    index += 1
                }
                out.append(Self.dot(buf, index + 2 * len, sincs[sub]))
            }
        }
        lastIndex = idx - Double(chunk)
        return out
    }

    /// NEON の f64 版と同じ順の積和（レーン k は要素 k, k+8 を FMA で足す）。
    static func dot(_ w: UnsafeBufferPointer<Double>, _ at: Int, _ s: [Double]) -> Double {
        var acc = SIMD8<Double>(repeating: 0)
        for base in stride(from: 0, to: sincLen, by: 8) {
            let wv = SIMD8<Double>(UnsafeBufferPointer(rebasing: w[(at + base)..<(at + base + 8)]))
            let sv = SIMD8<Double>(s[base..<(base + 8)])
            acc = acc.addingProduct(wv, sv)
        }
        // (acc0 + acc1) + (acc2 + acc3)（2 レーンずつ）、最後にレーン 0 + レーン 1
        let lane0 = (acc[0] + acc[2]) + (acc[4] + acc[6])
        let lane1 = (acc[1] + acc[3]) + (acc[5] + acc[7])
        return lane0 + lane1
    }
}
