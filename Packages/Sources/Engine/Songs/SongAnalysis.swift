import Foundation

public struct VersionAnalysis: Equatable, Sendable {
    public var name: String
    public var seconds: Float
    public var fingerprint: [UInt32]
    /// `onsetScale` で割って u8 に。100 フレーム/秒。
    public var onset: [UInt8]
    var onsetScale: Float
    public var toRef: TimeMap
    public var keyShift: UInt8

    func onsetValues() -> [Float] { onset.map { Float($0) * onsetScale } }
}

public struct SongAnalysis: Equatable, Sendable {
    /// 形を変えたら上げる。
    public static let schema: UInt32 = 1

    public var schema: UInt32
    public var key: UInt64
    public var versions: [VersionAnalysis]
    public var clip: ClipMap
    public var danceSeconds: Float

    public init?(postcard bytes: [UInt8]) {
        var r = Postcard.Reader(bytes: bytes)
        guard let a = try? r.analysis(), r.pos == bytes.count else { return nil }
        self = a
    }

    public init(schema: UInt32, key: UInt64, versions: [VersionAnalysis], clip: ClipMap, danceSeconds: Float) {
        (self.schema, self.key, self.versions, self.clip, self.danceSeconds) = (schema, key, versions, clip, danceSeconds)
    }

    func postcard() -> [UInt8] {
        var w = Postcard.Writer()
        w.varint(UInt64(schema))
        w.varint(key)
        w.varint(UInt64(versions.count))
        for v in versions {
            w.string(v.name)
            w.f32(v.seconds)
            w.varint(UInt64(v.fingerprint.count))
            v.fingerprint.forEach { w.varint(UInt64($0)) }
            w.varint(UInt64(v.onset.count))
            w.out += v.onset
            w.f32(v.onsetScale)
            w.pairs(v.toRef.points.map { ($0.x, $0.y) })
            w.out.append(v.keyShift)
        }
        w.varint(UInt64(clip.segments.count))
        for s in clip.segments { w.f32(s.from); w.f32(s.to); w.f32(s.clip) }
        w.f32(danceSeconds)
        return w.out
    }
}

/// postcard（serde）の形式: 整数は LEB128 の可変長、f32 は 4 バイトの LE、長さは可変長。
enum Postcard {
    struct Bad: Error {}

    struct Reader {
        let bytes: [UInt8]
        var pos = 0

        mutating func byte() throws -> UInt8 {
            guard pos < bytes.count else { throw Bad() }
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func varint(max bits: Int = 64) throws -> UInt64 {
            var v: UInt64 = 0
            for shift in stride(from: 0, to: bits + 7, by: 7) {
                let b = try byte()
                v |= UInt64(b & 0x7f) << UInt64(shift)
                if b & 0x80 == 0 { return v }
            }
            throw Bad()
        }

        mutating func u32() throws -> UInt32 {
            let v = try varint(max: 32)
            guard v <= UInt64(UInt32.max) else { throw Bad() }
            return UInt32(v)
        }

        mutating func len() throws -> Int {
            let n = try varint()
            guard n <= UInt64(bytes.count - pos) * 8 + 8 else { throw Bad() }
            return Int(n)
        }

        mutating func f32() throws -> Float {
            guard pos + 4 <= bytes.count else { throw Bad() }
            defer { pos += 4 }
            return Float(bitPattern: UInt32(bytes[pos]) | UInt32(bytes[pos + 1]) << 8 | UInt32(bytes[pos + 2]) << 16
                | UInt32(bytes[pos + 3]) << 24)
        }

        mutating func string() throws -> String {
            let n = try len()
            guard pos + n <= bytes.count, let s = String(validating: bytes[pos..<pos + n], as: UTF8.self) else { throw Bad() }
            pos += n
            return s
        }

        mutating func analysis() throws -> SongAnalysis {
            let schema = try u32(), key = try varint()
            var versions: [VersionAnalysis] = []
            for _ in 0..<(try len()) {
                let name = try string(), seconds = try f32()
                var fp: [UInt32] = []
                let n = try len()
                fp.reserveCapacity(n)
                for _ in 0..<n { fp.append(try u32()) }
                let m = try len()
                guard pos + m <= bytes.count else { throw Bad() }
                let onset = Array(bytes[pos..<pos + m])
                pos += m
                let scale = try f32()
                var points: [SIMD2<Float>] = []
                for _ in 0..<(try len()) { points.append(SIMD2(try f32(), try f32())) }
                versions.append(VersionAnalysis(name: name, seconds: seconds, fingerprint: fp, onset: onset, onsetScale: scale,
                                                toRef: TimeMap(points: points), keyShift: try byte()))
            }
            var segments: [ClipMap.Segment] = []
            for _ in 0..<(try len()) { segments.append(ClipMap.Segment(from: try f32(), to: try f32(), clip: try f32())) }
            return SongAnalysis(schema: schema, key: key, versions: versions, clip: ClipMap(segments: segments),
                                danceSeconds: try f32())
        }
    }

    struct Writer {
        var out: [UInt8] = []

        mutating func varint(_ v: UInt64) {
            var v = v
            while v >= 0x80 {
                out.append(UInt8(v & 0x7f) | 0x80)
                v >>= 7
            }
            out.append(UInt8(v))
        }

        mutating func f32(_ f: Float) {
            let b = f.bitPattern
            out += [UInt8(b & 0xff), UInt8(b >> 8 & 0xff), UInt8(b >> 16 & 0xff), UInt8(b >> 24)]
        }

        mutating func string(_ s: String) {
            varint(UInt64(s.utf8.count))
            out += Array(s.utf8)
        }

        mutating func pairs(_ p: [(Float, Float)]) {
            varint(UInt64(p.count))
            for (a, b) in p { f32(a); f32(b) }
        }
    }
}
