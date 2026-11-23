import MascotCore
import Accelerate
import CoreAI
import Foundation

// LAION-CLAP の音楽版（重み Apache-2.0、アプリに同梱）。
final class MusicMoodModel: @unchecked Sendable {
    static let samples = 480_000
    static let nFFT = 1024
    static let hop = 480
    static let mels = 64
    static let frames = 1 + samples / hop

    static var directory: URL { modelDirectory("clap", marker: "meta.json") }

    private let chunks: Task<[(InferenceFunction, input: String, output: String)]?, Never>
    private let filters: [Float]
    private let window: [Float]
    private let fft: vDSP.FFT<DSPSplitComplex>
    let labels: [String]
    private let labelEmbeddings: [Float]

    init?(directory: URL = MusicMoodModel.directory) {
        struct Meta: Decodable {
            struct Chunk: Decodable { let file: String; let input: String; let output: String }
            let chunks: [Chunk]
        }
        struct Labels: Decodable {
            struct Label: Decodable { let name: String }
            let labels: [Label]
            let dim: Int
        }
        let data = { (name: String) in try? Data(contentsOf: directory.appending(path: name)) }
        guard let metaData = data("meta.json"), let meta = try? JSONDecoder().decode(Meta.self, from: metaData),
              let labelData = data("labels.json"), let l = try? JSONDecoder().decode(Labels.self, from: labelData),
              let mel = data("mel.bin"), mel.count == (Self.nFFT / 2 + 1) * Self.mels * 4,
              let emb = data("labels.bin"), emb.count == l.labels.count * l.dim * 4,
              meta.chunks.allSatisfy({ FileManager.default.fileExists(atPath: directory.appending(path: $0.file).path) }),
              let fft = vDSP.FFT(log2n: 10, radix: .radix2, ofType: DSPSplitComplex.self) else { return nil }
        filters = mel.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        labelEmbeddings = emb.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        labels = l.labels.map(\.name)
        // torch.hann_window（periodic）と同じ
        window = (0..<Self.nFFT).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.nFFT))) }
        self.fft = fft
        chunks = Task(priority: .utility) {
            var out: [(InferenceFunction, input: String, output: String)] = []
            for c in meta.chunks {
                let options = SpecializationOptions(preferredComputeUnitKind: .neuralEngine)
                guard let f = try? await AIModel(contentsOf: directory.appending(path: c.file), options: options)
                    .loadFunction(named: "main") else { return nil }
                out.append((f, c.input, c.output))
            }
            return out
        }
    }

    // n_fft 1024・hop 480・reflect・パワー、Slaney のメル 64 本（50〜14000Hz）、10 log10(max(x, 1e-10))
    func logMel(_ wave: [Float]) -> [Float] {
        let n = Self.nFFT, half = n / 2
        var padded = [Float](repeating: 0, count: wave.count + n)
        for i in 0..<half {
            padded[half - 1 - i] = wave[i + 1]
            padded[half + wave.count + i] = wave[wave.count - 2 - i]
        }
        padded.replaceSubrange(half..<(half + wave.count), with: wave)
        var out = [Float](repeating: 0, count: Self.frames * Self.mels)
        var w = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half + 1)
        var row = [Float](repeating: 0, count: Self.mels)
        for f in 0..<Self.frames {
            padded.withUnsafeBufferPointer { p in
                vDSP.multiply(UnsafeBufferPointer(rebasing: p[(f * Self.hop)..<(f * Self.hop + n)]), window, result: &w)
            }
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    w.withUnsafeBufferPointer { p in
                        p.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    fft.forward(input: split, output: &split)
                    // vDSP の実 FFT は 2 倍の値で、DC と Nyquist は 0 番に入る
                    power[0] = r[0] * r[0] / 4
                    power[half] = im[0] * im[0] / 4
                    for k in 1..<half { power[k] = (r[k] * r[k] + im[k] * im[k]) / 4 }
                }
            }
            filters.withUnsafeBufferPointer { fb in
                vDSP_mmul(power, 1, fb.baseAddress!, 1, &row, 1, 1, vDSP_Length(Self.mels), vDSP_Length(half + 1))
            }
            for m in 0..<Self.mels { out[f * Self.mels + m] = 10 * log10(max(row[m], 1e-10)) }
        }
        return out
    }

    func embed(logMel: [Float]) async -> [Float]? {
        guard let chunks = await chunks.value else { return nil }
        return try? await Self.run(chunks, NDArray(scalars: logMel.map { Float16($0) }, shape: [1, Self.frames, Self.mels]))
    }

    private static func run(_ chunks: [(InferenceFunction, input: String, output: String)], _ mel: consuming NDArray) async throws -> [Float] {
        var x = mel
        for (f, input, output) in chunks {
            var r = try await f.run(inputs: [input: x])
            guard let y = r.remove(output)?.ndArray else { throw CocoaError(.fileReadCorruptFile) }
            x = y
        }
        return x.view(as: Float16.self).withUnsafePointer { p, shape, strides in
            (0..<shape[shape.count - 1]).map { Float(p[$0 * strides[strides.count - 1]]) }
        }
    }

    func cosines(_ embedding: [Float]) -> [Float] {
        let d = embedding.count
        return labels.indices.map { i in vDSP.dot(embedding, Array(labelEmbeddings[(i * d)..<((i + 1) * d)])) }
    }
}
