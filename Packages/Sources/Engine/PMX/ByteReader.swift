enum FormatError: Error, Equatable, Sendable {
    case unexpectedEOF(Int)
    case invalidPMXMagic
    case unsupportedPMXVersion(Float)
    case invalidEncoding(UInt8)
    case invalidIndexSize(UInt8)
    case sectionOverflow
    case invalid(String)
}

/// リトルエンディアン。
struct ByteReader {
    let data: [UInt8]
    var pos = 0

    init(_ data: [UInt8], pos: Int = 0) {
        self.data = data
        self.pos = pos
    }

    var remaining: Int { max(data.count - pos, 0) }

    func require(_ n: Int) throws {
        guard n >= 0, remaining >= n else { throw FormatError.unexpectedEOF(max(n - remaining, 1)) }
    }

    mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
        try require(n)
        defer { pos += n }
        return data[pos..<pos + n]
    }

    mutating func skip(_ n: Int) throws {
        try require(n)
        pos += n
    }

    mutating func u8() throws -> UInt8 {
        try require(1)
        defer { pos += 1 }
        return data[pos]
    }

    mutating func u16() throws -> UInt16 {
        try require(2)
        defer { pos += 2 }
        return UInt16(data[pos]) | UInt16(data[pos + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        try require(4)
        defer { pos += 4 }
        return UInt32(data[pos]) | UInt32(data[pos + 1]) << 8 | UInt32(data[pos + 2]) << 16 | UInt32(data[pos + 3]) << 24
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func vec2() throws -> SIMD2<Float> { SIMD2(try f32(), try f32()) }
    mutating func vec3() throws -> SIMD3<Float> { SIMD3(try f32(), try f32(), try f32()) }
    mutating func vec4() throws -> SIMD4<Float> { SIMD4(try f32(), try f32(), try f32(), try f32()) }

    func requireRecords(_ count: Int, _ recordSize: Int) throws {
        let (bytes, overflow) = count.multipliedReportingOverflow(by: recordSize)
        guard !overflow else { throw FormatError.sectionOverflow }
        try require(bytes)
    }

    mutating func sizedIndex(_ size: UInt8) throws -> Int32 {
        switch size {
        case 1: Int32(Int8(bitPattern: try u8()))
        case 2: Int32(Int16(bitPattern: try u16()))
        case 4: try i32()
        default: throw FormatError.invalidIndexSize(size)
        }
    }

    /// 1・2 バイトは符号なし、4 バイトは負ならエラー。
    mutating func vertexIndex(_ size: UInt8) throws -> UInt32 {
        switch size {
        case 1: return UInt32(try u8())
        case 2: return UInt32(try u16())
        case 4:
            let raw = try i32()
            guard raw >= 0 else { throw FormatError.sectionOverflow }
            return UInt32(raw)
        default: throw FormatError.invalidIndexSize(size)
        }
    }

    /// 長さ（i32）つき。UTF-8 は最初の 0 まで、UTF-16LE は 0 の単位まで。
    mutating func string(utf16: Bool) throws -> String {
        let len = try i32()
        guard len > 0 else { return "" }
        let b = try bytes(Int(len))
        if utf16 {
            var units: [UInt16] = []
            units.reserveCapacity(b.count / 2)
            var i = b.startIndex
            while i + 1 < b.endIndex {
                let u = UInt16(b[i]) | UInt16(b[i + 1]) << 8
                if u == 0 { break }
                units.append(u)
                i += 2
            }
            return String(decoding: units, as: UTF16.self)
        }
        let end = b.firstIndex(of: 0) ?? b.endIndex
        return String(decoding: b[b.startIndex..<end], as: UTF8.self)
    }

    mutating func count() throws -> Int {
        let n = try i32()
        guard n >= 0 else { throw FormatError.sectionOverflow }
        return Int(n)
    }

    mutating func count(minRecord: Int, max: Int = .max) throws -> Int {
        let n = try count()
        guard n <= max else { throw FormatError.sectionOverflow }
        try requireRecords(n, minRecord)
        return n
    }
}

/// リトルエンディアン。
struct ByteWriter {
    var out: [UInt8] = []

    mutating func u8(_ v: UInt8) { out.append(v) }
    mutating func u16(_ v: UInt16) { out += [UInt8(v & 0xff), UInt8(v >> 8)] }
    mutating func u32(_ v: UInt32) {
        out += [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)]
    }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func vec<V: SIMD>(_ v: V) where V.Scalar == Float { for i in v.indices { f32(v[i]) } }
    mutating func floats<C: Collection>(_ v: C) where C.Element == Float { for x in v { f32(x) } }

    /// 範囲外はビットを切り詰める。
    mutating func sizedIndex(_ v: Int32, _ size: UInt8) {
        switch size {
        case 1: u8(UInt8(truncatingIfNeeded: v))
        case 2: u16(UInt16(truncatingIfNeeded: v))
        case 4: i32(v)
        default: break
        }
    }

    mutating func vertexIndex(_ v: UInt32, _ size: UInt8) {
        switch size {
        case 1: u8(UInt8(truncatingIfNeeded: v))
        case 2: u16(UInt16(truncatingIfNeeded: v))
        case 4: u32(v)
        default: break
        }
    }

    mutating func string(_ s: String, utf16: Bool) {
        if utf16 {
            let units = Array(s.utf16)
            i32(Int32(units.count * 2))
            for u in units { u16(u) }
        } else {
            let b = Array(s.utf8)
            i32(Int32(b.count))
            out += b
        }
    }
}
