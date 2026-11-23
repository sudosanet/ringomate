import MascotCore
import Foundation

/// 形式: "LIPS"・版 u8・1 秒のコマ数 u16・コマ数 u32・コマごとに あいうえお の u8。
public struct LipsTrack: Sendable {
    public static let fps = 100
    let frames: [UInt8]

    public init(frames: [[Float]]) {
        self.frames = frames.flatMap { $0.map { UInt8(max(0, min(255, ($0 * 255).rounded()))) } }
    }

    public init?(url: URL) {
        guard let d = try? Data(contentsOf: url), d.count >= 11, d.prefix(4) == Data("LIPS".utf8) else { return nil }
        let count = d[7...10].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard d.count >= 11 + count * 5 else { return nil }
        frames = Array(d[11..<(11 + count * 5)])
    }

    public var data: Data {
        var d = Data("LIPS".utf8)
        d.append(1)
        d.append(contentsOf: [UInt8(Self.fps & 0xFF), UInt8(Self.fps >> 8)])
        let n = frames.count / 5
        d.append(contentsOf: (0..<4).map { UInt8((n >> (8 * $0)) & 0xFF) })
        d.append(contentsOf: frames)
        return d
    }

    /// 範囲の外は閉じた口。
    public func vowels(at seconds: Double) -> [Float] {
        let k = Int((seconds * Double(Self.fps)).rounded())
        guard k >= 0, k * 5 + 5 <= frames.count else { return [0, 0, 0, 0, 0] }
        return frames[(k * 5)..<(k * 5 + 5)].map { Float($0) / 255 }
    }
}
