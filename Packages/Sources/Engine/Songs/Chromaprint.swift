import Accelerate

/// Chromaprint の test2 の設定の移植。同梱の `analysis.bin` と同じ値にする。
public enum Chromaprint {
    static let sampleRate = 11025
    static let frameSize = 4096
    static let frameOverlap = frameSize - frameSize / 3
    static var samplesInItem: Int { frameSize - frameOverlap }
    static let filterCoefficients: [Double] = [0.25, 0.75, 1.0, 0.75, 0.25]
    static let maxFilterWidth = classifiers.map(\.width).max()!

    /// f32 で割ってから広げる（同梱の解析と合わせる）。
    static var itemSeconds: Double { Double(Float(samplesInItem) / Float(sampleRate)) }


    public static func fingerprint(_ samples: [Float], rate: Int) -> [UInt32] {
        if rate <= 1000 { return [] }
        let chunk = 1024 * 32
        var calc = Calculator()
        var resampler = rate == sampleRate ? nil : SincResampler(ratio: Double(sampleRate) / Double(rate), chunk: chunk)
        // i16 に量子化してから f64 へ（同梱の解析と同じ値にする）
        var input: [Double] = []
        func run(_ isEnd: Bool) {
            guard var r = resampler else {
                calc.consume(input)
                input.removeAll()
                return
            }
            var start = 0
            while start < input.count {
                if input.count - start < r.chunk {
                    if isEnd { r.chunk = input.count - start } else { break }
                }
                calc.consume(r.process(input[start...]))
                start += r.chunk
                if isEnd { r.chunk = r.chunkMax }
            }
            input.removeFirst(start)
            resampler = r
        }
        var pending = 0
        for s in samples {
            let c = s.isNaN ? 0 : min(max(s, -1), 1)
            input.append(Double(Int16(c * 32767)) / Double(Int16.max))
            pending += 1
            if pending == chunk {
                run(false)
                pending = 0
            }
        }
        if pending > 0 { run(true) }
        return calc.fingerprint
    }
}

extension Chromaprint {
    struct Calculator {
        var ring: [Double] = []
        let window: [Double] = (0..<frameSize).map { 0.54 - 0.46 * cos(2 * Double.pi * Double($0) / (Double(frameSize) - 1)) }
        let fft = DoubleFFT(frameSize)
        let notes: [Int]
        let minIndex: Int, maxIndex: Int
        var filterBuffer = [[Double]](repeating: [Double](repeating: 0, count: 12), count: 8)
        var filterOffset = 0, filterSize = 1
        var image = IntegralImage()
        var fingerprint: [UInt32] = []

        init() {
            func index(_ f: Double) -> Int { Int((Double(frameSize) * f / Double(sampleRate)).rounded()) }
            minIndex = max(index(28), 1)
            maxIndex = min(index(3520), frameSize / 2)
            var notes = [Int](repeating: 0, count: frameSize)
            for i in minIndex..<maxIndex {
                let freq = Double(i) * Double(sampleRate) / Double(frameSize)
                let octave = log2(freq / (440.0 / 16.0))
                notes[i] = Int((12 * (octave - octave.rounded(.down))).rounded(.down))
            }
            self.notes = notes
        }

        mutating func consume(_ data: [Double]) {
            ring += data
            var start = 0
            while ring.count - start >= frameSize {
                var frame = [Double](repeating: 0, count: frameSize)
                for i in 0..<frameSize { frame[i] = ring[start + i] * window[i] }
                let power = fft.powers(frame)
                var features = [Double](repeating: 0, count: 12)
                for i in minIndex..<maxIndex { features[notes[i]] += power[i] }
                filter(features)
                start += frameSize - frameOverlap
            }
            ring.removeFirst(start)
        }

        mutating func filter(_ features: [Double]) {
            filterBuffer[filterOffset] = features
            filterOffset = (filterOffset + 1) % 8
            guard filterSize >= filterCoefficients.count else {
                filterSize += 1
                return
            }
            let offset = (filterOffset + 8 - filterCoefficients.count) % 8
            var result = [Double](repeating: 0, count: 12)
            for i in 0..<12 {
                for j in filterCoefficients.indices { result[i] += filterBuffer[(offset + j) % 8][i] * filterCoefficients[j] }
            }
            var sq = 0.0
            for x in result { sq += x * x }
            let norm = sq.squareRoot()
            for i in 0..<12 { result[i] = norm < 0.01 ? 0 : result[i] / norm }
            image.add(result)
            if image.rows >= maxFilterWidth {
                let offset = image.rows - maxFilterWidth
                var bits: UInt32 = 0
                for c in classifiers { bits = (bits << 2) | [0, 1, 3, 2][c.classify(image, offset)] }
                fingerprint.append(bits)
            }
        }
    }

    struct IntegralImage {
        static let maxRows = 256
        var rows = 0
        var data = [Double](repeating: 0, count: maxRows * 12)

        mutating func add(_ row: [Double]) {
            let at = rows % Self.maxRows * 12, prev = (rows + Self.maxRows - 1) % Self.maxRows * 12
            var sum = 0.0
            for i in 0..<12 {
                sum += row[i]
                data[at + i] = sum
            }
            if rows > 0 { for i in 0..<12 { data[at + i] += data[prev + i] } }
            rows += 1
        }

        func row(_ i: Int) -> Int { i % Self.maxRows * 12 }

        func area(_ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) -> Double {
            if r1 == r2 || c1 == c2 { return 0 }
            let b = row(r2 - 1)
            if r1 == 0 { return c1 == 0 ? data[b + c2 - 1] : data[b + c2 - 1] - data[b + c1 - 1] }
            let a = row(r1 - 1)
            return c1 == 0 ? data[b + c2 - 1] - data[a + c2 - 1]
                : data[b + c2 - 1] - data[a + c2 - 1] - data[b + c1 - 1] + data[a + c1 - 1]
        }
    }

    struct Classifier {
        let kind: Int, y: Int, height: Int, width: Int
        let t0: Double, t1: Double, t2: Double

        func classify(_ img: IntegralImage, _ x: Int) -> Int {
            let (w, h) = (width, height)
            let (a, b): (Double, Double)
            switch kind {
            case 0: (a, b) = (img.area(x, y, x + w, y + h), 0)
            case 1: (a, b) = (img.area(x, y + h / 2, x + w, y + h), img.area(x, y, x + w, y + h / 2))
            case 2: (a, b) = (img.area(x + w / 2, y, x + w, y + h), img.area(x, y, x + w / 2, y + h))
            case 3:
                a = img.area(x, y + h / 2, x + w / 2, y + h) + img.area(x + w / 2, y, x + w, y + h / 2)
                b = img.area(x, y, x + w / 2, y + h / 2) + img.area(x + w / 2, y + h / 2, x + w, y + h)
            case 4:
                a = img.area(x, y + h / 3, x + w, y + 2 * (h / 3))
                b = img.area(x, y, x + w, y + h / 3) + img.area(x, y + 2 * (h / 3), x + w, y + h)
            default:
                a = img.area(x + w / 3, y, x + 2 * (w / 3), y + h)
                b = img.area(x, y, x + w / 3, y + h) + img.area(x + 2 * (w / 3), y, x + w, y + h)
            }
            let v = log((1 + a) / (1 + b))
            return v < t1 ? (v < t0 ? 0 : 1) : (v < t2 ? 2 : 3)
        }
    }

    static let classifiers: [Classifier] = [
        (0, 4, 3, 15, 1.98215, 2.35817, 2.63523), (4, 4, 6, 15, -1.03809, -0.651211, -0.282167),
        (1, 0, 4, 16, -0.298702, 0.119262, 0.558497), (3, 8, 2, 12, -0.105439, 0.0153946, 0.135898),
        (3, 4, 4, 8, -0.142891, 0.0258736, 0.200632), (4, 0, 3, 5, -0.826319, -0.590612, -0.368214),
        (1, 2, 2, 9, -0.557409, -0.233035, 0.0534525), (2, 7, 3, 4, -0.0646826, 0.00620476, 0.0784847),
        (2, 6, 2, 16, -0.192387, -0.029699, 0.215855), (2, 1, 3, 2, -0.0397818, -0.00568076, 0.0292026),
        (5, 10, 1, 15, -0.53823, -0.369934, -0.190235), (3, 6, 2, 10, -0.124877, 0.0296483, 0.139239),
        (2, 1, 1, 14, -0.101475, 0.0225617, 0.231971), (3, 5, 6, 4, -0.0799915, -0.00729616, 0.063262),
        (1, 9, 2, 12, -0.272556, 0.019424, 0.302559), (3, 4, 2, 14, -0.164292, -0.0321188, 0.0846339),
    ].map { Classifier(kind: $0.0, y: $0.1, height: $0.2, width: $0.3, t0: $0.4, t1: $0.5, t2: $0.6) }
}

final class DoubleFFT: @unchecked Sendable {
    let n: Int
    let log2n: vDSP_Length
    let setup: FFTSetupD

    init(_ n: Int) {
        self.n = n
        log2n = vDSP_Length(n.trailingZeroBitCount)
        setup = vDSP_create_fftsetupD(log2n, FFTRadix(kFFTRadix2))!
    }

    deinit { vDSP_destroy_fftsetupD(setup) }

    func powers(_ x: [Double]) -> [Double] {
        let h = n / 2
        var re = [Double](repeating: 0, count: h), im = re
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPDoubleSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                x.withUnsafeBytes {
                    vDSP_ctozD($0.bindMemory(to: DSPDoubleComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(h))
                }
                vDSP_fft_zripD(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        // zrip は 2 倍の値を返し、0 番目の虚部に n/2 の値を入れる
        var out = [Double](repeating: 0, count: h)
        out[0] = re[0] * re[0] / 4
        for k in 1..<h { out[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
        return out
    }
}
