import MascotCore
import Accelerate
import CoreAI
import Foundation

/// 曲から歌声を分ける（Mel-Band RoFormer の Kim vocal、MIT、Core AI 版）。
public final class VocalSeparator: @unchecked Sendable {
    public static let rate = 44_100.0
    static let chunk = 352_800
    static let nFFT = 2048
    static let hop = 441
    static let pad = 1024
    static let frames = 801

    /// 同梱しない。
    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/ringomate/models/melband")
    }

    private let model: InferenceFunction
    private let norm: [Float]

    public init(directory: URL = VocalSeparator.directory) async throws {
        let options = SpecializationOptions(preferredComputeUnitKind: .gpu)
        guard let f = try await AIModel(contentsOf: directory.appending(path: "mbr_full_fp16.aimodel"), options: options)
            .loadFunction(named: "main") else { throw CocoaError(.fileReadCorruptFile) }
        model = f
        let win = (0..<Self.nFFT).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(Self.nFFT))) }
        var n = [Float](repeating: 0, count: Self.chunk + 2 * Self.pad)
        for f in 0..<Self.frames {
            for k in 0..<Self.nFFT { n[f * Self.hop + k] += win[k] * win[k] }
        }
        norm = n
    }

    func separateChunk(_ left: [Float], _ right: [Float]) async throws -> ([Float], [Float]) {
        let padded = [left, right].map { x -> [Float] in
            let head = (1...Self.pad).map { x[$0] }.reversed()
            let tail = (1...Self.pad).map { x[x.count - 1 - $0] }
            return Array(head) + x + tail
        }
        var flat = [Float16]()
        flat.reserveCapacity(2 * Self.frames * Self.nFFT)
        for ch in padded {
            for f in 0..<Self.frames {
                flat += ch[(f * Self.hop)..<(f * Self.hop + Self.nFFT)].map { Float16($0) }
            }
        }
        var out = try await model.run(inputs: ["frames": NDArray(scalars: flat, shape: [1, 2, Self.frames, Self.nFFT])])
        guard let recon = out.remove("recon")?.ndArray else { throw CocoaError(.fileReadCorruptFile) }
        func read<T: BinaryFloatingPoint & BitwiseCopyable>(_: T.Type) -> [[Float]] {
            recon.view(as: T.self).withUnsafePointer { p, _, strides in
                (0..<2).map { c in
                    var acc = [Float](repeating: 0, count: Self.chunk + 2 * Self.pad)
                    for f in 0..<Self.frames {
                        for k in 0..<Self.nFFT {
                            acc[f * Self.hop + k] += Float(p[c * strides[1] + f * strides[2] + k * strides[3]])
                        }
                    }
                    return (0..<Self.chunk).map { acc[$0 + Self.pad] / max(norm[$0 + Self.pad], 1e-8) }
                }
            }
        }
        let y = recon.scalarType == .float16 ? read(Float16.self) : read(Float.self)
        return (y[0], y[1])
    }

    public func separate(left: [Float], right: [Float]) async throws -> ([Float], [Float]) {
        let n = left.count
        let step = Self.chunk / 2
        var outL = [Float](repeating: 0, count: n), outR = [Float](repeating: 0, count: n)
        var weight = [Float](repeating: 0, count: n)
        let tri = (0..<Self.chunk).map { i in Float(min(i + 1, Self.chunk - i)) / Float(step) }
        var start = -step
        while start < n {
            let take = { (x: [Float]) in (0..<Self.chunk).map { i -> Float in
                let j = start + i
                return j >= 0 && j < n ? x[j] : 0
            } }
            let (vl, vr) = try await separateChunk(take(left), take(right))
            for i in 0..<Self.chunk {
                let j = start + i
                guard j >= 0, j < n else { continue }
                outL[j] += vl[i] * tri[i]
                outR[j] += vr[i] * tri[i]
                weight[j] += tri[i]
            }
            start += step
        }
        for j in 0..<n where weight[j] > 0 {
            outL[j] /= weight[j]
            outR[j] /= weight[j]
        }
        return (outL, outR)
    }
}
