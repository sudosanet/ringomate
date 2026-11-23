import MascotCore
import Accelerate
import CoreAI
import Foundation

/// 時刻はホストの時計の秒。
public struct BarGrid: Sendable, Equatable {
    public var period: Double
    public var lastBeat: Double
    public var lastDownbeat: Double
    public var meter: Int
    public var confidence: Float
    public var source: Source

    public enum Source: String, Sendable { case model, onsets }
}

// Beat This!（CPJKU/beat_this の small0、MIT）。
final class BeatModel: @unchecked Sendable {
    static let sampleRate = 22050.0
    static let fps = 50.0
    private static let nFFT = 1024, hop = 441, mels = 128

    private let loading: Task<InferenceFunction?, Never>
    private let frames: Int
    private let filters: [Float]
    private let window: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let lock = NSLock()
    private var grid: BarGrid?
    private var running = false

    private var samples: [Float] = []
    private var samplesStart = 0.0
    private var spect: [[Float]] = []
    private var spectTimes: [Double] = []
    private var lastInference = 0.0
    private var resamplePos = 0.0
    private var previousInput: Float = 0

    static var directory: URL { modelDirectory("beat_this", marker: "BeatThis.aimodel") }

    init?(directory: URL = BeatModel.directory) {
        let url = directory.appending(path: "BeatThis.aimodel")
        guard FileManager.default.fileExists(atPath: url.path),
              let meta = try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "meta.json"))) as? [String: Any],
              let frames = meta["frames"] as? Int,
              let mel = try? Data(contentsOf: directory.appending(path: "mel.bin")),
              mel.count == 513 * Self.mels * 4 else { return nil }
        guard let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        loading = Task(priority: .utility) {
            let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
            return try? await AIModel(contentsOf: url, options: options).loadFunction(named: "main")
        }
        self.frames = frames
        self.filters = mel.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        // torch.hann_window（periodic）と同じ
        self.window = (0..<Self.nFFT).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.nFFT))) }
        self.fft = fft
    }

    var current: BarGrid? {
        lock.lock()
        defer { lock.unlock() }
        return grid
    }

    var failed: Bool { lock.withLock { loadFailed } }
    private var loadFailed = false

    // 拍の推定と同じ直列のキューから呼ぶ
    @discardableResult
    func feed(_ input: [Float], rate: Double, end: Double) -> [[Float]] {
        guard !input.isEmpty else { return [] }
        var made: [[Float]] = []
        // ponytail: 線形補間、高い音の折り返しが気になったら FIR の間引きに
        let step = rate / Self.sampleRate
        let firstTime = end - Double(input.count) / rate
        if samples.isEmpty { samplesStart = firstTime }
        while resamplePos < Double(input.count) {
            let i = Int(resamplePos.rounded(.down))
            let f = Float(resamplePos - Double(i))
            let a = i == 0 ? previousInput : input[i - 1]
            let b = input[min(i, input.count - 1)]
            samples.append(a + (b - a) * f)
            resamplePos += step
        }
        resamplePos -= Double(input.count)
        previousInput = input[input.count - 1]
        while samples.count >= Self.nFFT {
            let row = melFrame(samples[0..<Self.nFFT])
            made.append(row)
            spect.append(row)
            spectTimes.append(samplesStart + Double(Self.nFFT / 2) / Self.sampleRate)
            samples.removeFirst(Self.hop)
            samplesStart += Double(Self.hop) / Self.sampleRate
        }
        if spect.count > frames {
            spect.removeFirst(spect.count - frames)
            spectTimes.removeFirst(spectTimes.count - frames)
        }
        guard spect.count >= Int(Self.fps * 5), let last = spectTimes.last, last - lastInference >= 2 else { return made }
        lock.lock()
        let busy = running
        if !busy { running = true }
        lock.unlock()
        guard !busy else { return made }
        lastInference = last
        let rows = spect, times = spectTimes
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let g = await self.infer(rows: rows, times: times)
            self.lock.withLock {
                if let g { self.grid = g }
                self.running = false
            }
        }
        return made
    }

    func reset() {
        samples.removeAll()
        spect.removeAll()
        spectTimes.removeAll()
        resamplePos = 0
        lastInference = 0
        lock.lock()
        grid = nil
        lock.unlock()
    }

    // torchaudio の MelSpectrogram（normalized="frame_length"・power 1）+ log1p(1000 x) と同じ
    func melFrame(_ x: ArraySlice<Float>) -> [Float] {
        let n = Self.nFFT
        var w = [Float](repeating: 0, count: n)
        vDSP.multiply(Array(x), window, result: &w)
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var mag = [Float](repeating: 0, count: n / 2 + 1)
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                w.withUnsafeBufferPointer { p in
                    p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                // vDSP の実 FFT は 2 倍の値で、DC と Nyquist は 0 番に入る
                let scale = 0.5 / Float(n).squareRoot()
                mag[0] = abs(r[0]) * scale
                mag[n / 2] = abs(im[0]) * scale
                for k in 1..<(n / 2) { mag[k] = (r[k] * r[k] + im[k] * im[k]).squareRoot() * scale }
            }
        }
        var out = [Float](repeating: 0, count: Self.mels)
        filters.withUnsafeBufferPointer { fb in
            mag.withUnsafeBufferPointer { m in
                vDSP_mmul(m.baseAddress!, 1, fb.baseAddress!, 1, &out, 1, 1, vDSP_Length(Self.mels), vDSP_Length(513))
            }
        }
        return out.map { log1p(1000 * $0) }
    }

    func infer(rows: [[Float]], times: [Double]) async -> BarGrid? {
        guard let model = await loading.value else {
            lock.withLock { loadFailed = true }
            return nil
        }
        let pad = frames - rows.count
        var flat = [Float](repeating: 0, count: pad * Self.mels)
        flat.reserveCapacity(frames * Self.mels)
        for r in rows { flat += r }
        // 入出力は fp16
        let input = NDArray(scalars: flat.map { Float16($0) }, shape: [1, frames, Self.mels])
        guard var out = try? await model.run(inputs: ["spect": input]),
              let beat = out.remove("beat")?.ndArray, let down = out.remove("downbeat")?.ndArray else { return nil }
        func values(_ a: NDArray) -> [Float] {
            func read<T: BinaryFloatingPoint & BitwiseCopyable>(_: T.Type) -> [Float] {
                a.view(as: T.self).withUnsafePointer { p, _, strides in (pad..<frames).map { Float(p[$0 * strides[strides.count - 1]]) } }
            }
            return a.scalarType == .float16 ? read(Float16.self) : read(Float.self)
        }
        return Self.grid(beat: values(beat), downbeat: values(down), times: times)
    }

    // 右の端の 6 フレームはモデルが学習していないので使わない
    static func grid(beat: [Float], downbeat: [Float], times: [Double]) -> BarGrid? {
        func peaks(_ x: [Float]) -> [Int] {
            var out: [Int] = []
            var i = 0
            let usable = x.count - 6
            while i < usable {
                let lo = max(0, i - 3), hi = min(x.count - 1, i + 3)
                if x[i] > 0, x[i] >= x[lo...hi].max()! {
                    var j = i
                    while j + 1 < usable, x[j + 1] == x[i] { j += 1 }
                    out.append((i + j) / 2)
                    i = j + 1
                } else {
                    i += 1
                }
            }
            return out
        }
        let beats = peaks(beat).map { times[$0] }
        guard beats.count >= 6 else { return nil }
        let downs = peaks(downbeat).compactMap { k -> Double? in
            let t = times[k]
            let near = beats.min { abs($0 - t) < abs($1 - t) }!
            return abs(near - t) < 0.08 ? near : nil
        }
        let gaps = zip(beats.dropFirst(), beats).map { $0 - $1 }.sorted()
        let rough = gaps[gaps.count / 2]
        guard rough > 0.25, rough < 1.2 else { return nil }
        var index = [Double](), time = [Double]()
        var n = 0.0
        for (i, t) in beats.enumerated() {
            if i > 0 { n += max(1, ((t - beats[i - 1]) / rough).rounded()) }
            index.append(n)
            time.append(t)
        }
        let mi = index.reduce(0, +) / Double(index.count), mt = time.reduce(0, +) / Double(time.count)
        let sxx = zip(index, index).map { ($0 - mi) * ($1 - mi) }.reduce(0, +)
        let sxy = zip(index, time).map { ($0 - mi) * ($1 - mt) }.reduce(0, +)
        let fitted = sxx > 0 ? sxy / sxx : rough
        let period = abs(fitted - rough) / rough < 0.05 ? fitted : rough
        let lastBeat = mt + (index.last! - mi) * period
        let steady = Float(gaps.filter { abs($0 - period) / period < 0.12 }.count) / Float(gaps.count)
        var counts = [Int: Int]()
        for (a, b) in zip(downs.dropFirst(), downs) {
            let n = Int(((a - b) / period).rounded())
            if (2...4).contains(n) { counts[n, default: 0] += 1 }
        }
        let meter = counts.max { $0.value < $1.value }?.key ?? 4
        guard let lastDown = downs.last else { return nil }
        let agree = Float(counts[meter] ?? 0) / Float(max(downs.count - 1, 1))
        let downOnLine = lastBeat - (((lastBeat - lastDown) / period).rounded()) * period
        return BarGrid(period: period, lastBeat: lastBeat, lastDownbeat: downOnLine, meter: meter,
                       confidence: min(1, steady * (0.4 + 0.6 * agree)), source: .model)
    }
}
