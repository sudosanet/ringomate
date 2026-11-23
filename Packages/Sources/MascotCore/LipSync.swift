import Accelerate
import Foundation

/// 声から口の形を出す（uLipSync と同じ考え方）。16kHz のモノラル、録音も保存もしない。
public struct LipSync: @unchecked Sendable {
    public static let rate = 16_000.0
    public static let window = 1024
    static let mels = 30
    static let coefficients = 12

    // templates[声][母音]: 声は Kyoko・Flo・Shelley・Eddy・Reed（say）、母音は あ・い・う・え・お
    static let templates: [[[Float]]] = [
        [
            [5.75, -23.18, 1.14, -15.47, 4.94, -5.30, 3.20, 7.04, 4.44, -6.00, 1.07, 0.84],
            [-17.61, 16.95, 36.58, -16.42, -2.63, 2.87, -7.12, -7.35, 3.41, -7.59, 1.09, -3.99],
            [20.39, -3.12, 21.39, -4.51, 4.12, -9.32, -7.85, -0.86, 2.50, -4.68, 1.58, 6.45],
            [-6.17, -8.87, 25.71, -23.82, -14.41, -4.70, -4.72, 0.41, -2.23, 0.84, -7.29, -6.11],
            [31.66, -0.01, -7.32, -37.76, 8.90, -4.25, -4.54, -3.27, -1.37, -7.03, -2.27, -5.15],
        ],
        [
            [50.05, -63.47, 26.96, -47.17, 34.68, -23.07, 14.94, -9.76, 9.58, 2.31, -10.02, 0.67],
            [31.54, -26.18, 70.27, -43.57, 31.17, -16.40, 17.67, -8.58, 3.25, 1.66, -1.10, 1.05],
            [58.41, -41.55, 40.50, -33.14, 31.69, -24.73, 7.74, -11.13, 5.01, 4.89, -9.23, 2.10],
            [42.14, -45.11, 58.25, -43.31, 21.40, -27.10, 18.69, -11.26, 2.00, 1.50, -1.97, 3.60],
            [79.74, -22.80, 26.22, -53.08, 19.55, -14.69, 13.60, -8.00, -0.08, 4.51, -9.28, 5.38],
        ],
        [
            [56.44, -53.49, 32.14, -45.80, 38.56, -21.65, 15.42, -7.09, 10.45, 0.10, -8.23, 5.21],
            [35.55, -16.13, 70.30, -45.35, 30.55, -15.65, 14.20, -7.52, 2.33, 2.89, -1.16, 1.89],
            [67.11, -31.74, 44.21, -31.00, 32.60, -21.65, 7.69, -7.44, 5.97, 2.87, -9.26, 5.95],
            [48.99, -34.97, 60.82, -44.11, 22.47, -24.65, 18.64, -9.47, 2.59, 2.94, -0.42, 4.60],
            [87.26, -14.09, 27.84, -52.80, 22.40, -11.48, 12.82, -5.89, 0.97, 3.88, -7.27, 8.71],
        ],
        [
            [65.78, -73.56, 39.15, -48.30, 21.99, -11.59, 2.28, -1.04, 1.92, 9.57, 2.40, -9.94],
            [38.80, -50.99, 86.17, -28.37, 18.97, -7.51, 7.74, 3.44, -3.56, -0.74, 2.58, 0.26],
            [73.56, -54.63, 54.62, -29.80, 27.12, -10.42, -4.38, -5.32, -6.62, 5.24, 0.00, -8.62],
            [52.33, -66.01, 67.93, -33.67, 13.53, -24.63, 0.42, 0.99, -4.55, -1.74, 1.10, 1.36],
            [88.63, -37.39, 44.09, -51.11, 6.70, -7.58, 4.13, 1.89, -9.60, 1.74, -0.70, -3.53],
        ],
        [
            [65.96, -73.19, 39.43, -47.72, 22.39, -11.26, 2.47, -0.77, 2.14, 9.66, 2.78, -9.71],
            [38.84, -51.21, 86.29, -28.36, 19.04, -7.61, 7.75, 3.55, -3.61, -0.56, 2.68, 0.54],
            [73.72, -54.18, 54.68, -29.47, 27.16, -10.18, -4.21, -5.18, -6.22, 5.38, 0.32, -8.18],
            [52.85, -65.50, 68.55, -33.19, 14.05, -24.33, 0.83, 1.16, -4.40, -1.62, 1.27, 1.50],
            [88.71, -37.58, 44.46, -51.09, 7.17, -7.42, 4.48, 1.91, -9.36, 1.75, -0.27, -3.23],
        ],
    ]

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let hann: [Float]
    private let filters: [[Float]]
    private let dct: [[Float]]
    private var peak: Float = 1e-4
    private var recent: Float?
    private var mean: [Float]?
    private static let centered: [[[Float]]] = {
        var out = [[[Float]]](repeating: [], count: 5)
        for voice in templates {
            let m = (0..<coefficients).map { c in voice.map { $0[c] }.reduce(0, +) / Float(voice.count) }
            for (k, v) in voice.enumerated() { out[k].append(vDSP.subtract(v, m)) }
        }
        return out
    }()

    public init() {
        fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self)!
        hann = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.window, isHalfWindow: false)
        let bins = Self.window / 2 + 1
        let hz2mel = { (f: Double) in 2595 * log10(1 + f / 700) }
        let mel2hz = { (m: Double) in 700 * (pow(10, m / 2595) - 1) }
        let (lo, hi) = (hz2mel(100), hz2mel(7600))
        let points = (0...Self.mels + 1).map { mel2hz(lo + (hi - lo) * Double($0) / Double(Self.mels + 1)) }
        filters = (0..<Self.mels).map { m in
            (0..<bins).map { k in
                let f = Double(k) * Self.rate / Double(Self.window)
                let (a, b, c) = (points[m], points[m + 1], points[m + 2])
                return Float(max(0, f < b ? (f - a) / (b - a) : (c - f) / (c - b)))
            }
        }
        dct = (1...Self.coefficients).map { c in
            (0..<Self.mels).map { m in Float(cos(Double.pi * Double(c) * (Double(m) + 0.5) / Double(Self.mels))) }
        }
    }

    func features(_ x: ArraySlice<Float>) -> (mfcc: [Float], rms: Float) {
        var frame = [Float](repeating: 0, count: Self.window)
        let xs = Array(x.suffix(Self.window))
        let offset = Self.window - xs.count
        for i in 0..<xs.count {
            frame[offset + i] = xs[i] - 0.97 * (i > 0 ? xs[i - 1] : 0)
        }
        let rms = sqrt(vDSP.meanSquare(xs.isEmpty ? [0] : xs))
        vDSP.multiply(frame, hann, result: &frame)
        let half = Self.window / 2
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half + 1)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                power[0] = rp[0] * rp[0]
                power[half] = ip[0] * ip[0]
                for k in 1..<half { power[k] = rp[k] * rp[k] + ip[k] * ip[k] }
            }
        }
        let logMel = filters.map { log(max(vDSP.dot($0, power), 1e-10)) }
        let mfcc = dct.map { vDSP.dot($0, logMel) }
        return (mfcc, rms)
    }

    /// 合計は開きの大きさ。
    public mutating func vowels(_ x: ArraySlice<Float>) -> [Float] {
        let (mfcc, rms) = features(x)
        peak = max(rms, peak * 0.996, 1e-4)
        let db = 20 * log10(max(rms, 1e-9) / peak)
        let level = max(0, min(1, (db + 22) / 22))
        recent = recent.map { $0 + (db - $0) * 0.03 } ?? db
        let open = level * max(0, min(1, 0.6 + (db - (recent ?? db)) / 12))
        guard open > 0 else { return [0, 0, 0, 0, 0] }
        let avg = mean.map { vDSP.add(vDSP.multiply(0.99, $0), vDSP.multiply(0.01, mfcc)) } ?? mfcc
        mean = avg
        let norm = { (v: [Float]) in vDSP.divide(v, max(sqrt(vDSP.sumOfSquares(v)), 1e-6)) }
        let m = norm(vDSP.subtract(mfcc, avg))
        let sims = Self.centered.map { $0.map { vDSP.dot(norm($0), m) }.max() ?? 0 }
        let top = sims.max() ?? 0
        let e = sims.map { exp(($0 - top) / 0.08) }
        let sum = e.reduce(0, +)
        return e.map { $0 / sum * open }
    }
}
