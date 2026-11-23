import Compression
import zlib
import Foundation

/// 保存（0）と deflate（8）だけ読む。
struct ZIPEntry: Sendable {
    let name: [UInt8]
    let utf8Flag: Bool
    let size: UInt64
    let compressedSize: UInt64
    let crc: UInt32
    let method: UInt16
    let flags: UInt16
    let localOffset: UInt64

    var isDirectory: Bool { name.last == UInt8(ascii: "/") || name.last == UInt8(ascii: "\\") }

    static func readDirectory(_ url: URL) throws -> [ZIPEntry] {
        guard let h = try? FileHandle(forReadingFrom: url) else { throw Archive.Failure.io("open \(url.path)") }
        defer { try? h.close() }
        let fileSize = try h.seekToEnd()
        // EOCD を後ろの 64KB + 22 バイトから探す
        let tail = min(fileSize, 65_535 + 22)
        try h.seek(toOffset: fileSize - tail)
        let buf = [UInt8](try h.read(upToCount: Int(tail)) ?? Data())
        guard let eocd = stride(from: buf.count - 22, through: 0, by: -1).first(where: { le32(buf, $0) == 0x0605_4b50 })
        else { throw Archive.Failure.zip("no end of central directory") }
        var count = UInt64(le16(buf, eocd + 10))
        var dirSize = UInt64(le32(buf, eocd + 12))
        var dirOffset = UInt64(le32(buf, eocd + 16))
        if eocd >= 20, le32(buf, eocd - 20) == 0x0706_4b50 {
            let at = le64(buf, eocd - 20 + 8)
            try h.seek(toOffset: at)
            let z = [UInt8](try h.read(upToCount: 56) ?? Data())
            guard z.count == 56, le32(z, 0) == 0x0606_4b50 else { throw Archive.Failure.zip("bad zip64 record") }
            count = le64(z, 32)
            dirSize = le64(z, 40)
            dirOffset = le64(z, 48)
        }
        guard dirSize <= fileSize, dirOffset <= fileSize - dirSize else { throw Archive.Failure.zip("central directory out of range") }
        try h.seek(toOffset: dirOffset)
        let dir = [UInt8](try h.read(upToCount: Int(dirSize)) ?? Data())
        var out: [ZIPEntry] = []
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= dir.count, le32(dir, p) == 0x0201_4b50 else { throw Archive.Failure.zip("bad central directory") }
            let flags = le16(dir, p + 8), method = le16(dir, p + 10)
            let crc = le32(dir, p + 16)
            var csize = UInt64(le32(dir, p + 20)), usize = UInt64(le32(dir, p + 24))
            let nameLen = Int(le16(dir, p + 28)), extraLen = Int(le16(dir, p + 30)), commentLen = Int(le16(dir, p + 32))
            var offset = UInt64(le32(dir, p + 42))
            guard p + 46 + nameLen + extraLen + commentLen <= dir.count else { throw Archive.Failure.zip("entry out of range") }
            var name = Array(dir[p + 46..<p + 46 + nameLen])
            var unicodeName = false
            // ZIP64 の追加情報は 0xFFFFFFFF の欄だけ、大きさ・圧縮後・位置の順
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = le16(dir, e), len = Int(le16(dir, e + 2))
                guard e + 4 + len <= extraEnd else { break }
                if id == 0x0001 {
                    var q = e + 4
                    if usize == 0xFFFF_FFFF, q + 8 <= e + 4 + len { usize = le64(dir, q); q += 8 }
                    if csize == 0xFFFF_FFFF, q + 8 <= e + 4 + len { csize = le64(dir, q); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= e + 4 + len { offset = le64(dir, q) }
                } else if id == 0x7075, len >= 5, dir[e + 4] == 1, le32(dir, e + 5) == crc32(name) {
                    // Info-ZIP の Unicode のファイル名は、元の名前の CRC が合えば使う
                    name = Array(dir[e + 9..<e + 4 + len])
                    unicodeName = true
                }
                e += 4 + len
            }
            let ascii = name.allSatisfy { $0 < 0x80 }
            let utf8 = ascii || ((flags & 0x0800 != 0 || unicodeName) && String(validating: name, as: UTF8.self) != nil)
            out.append(ZIPEntry(name: name, utf8Flag: utf8, size: usize, compressedSize: csize, crc: crc,
                                method: method, flags: flags, localOffset: offset))
            p += 46 + nameLen + extraLen + commentLen
        }
        return out
    }

    func read(_ url: URL) throws -> [UInt8] {
        guard flags & 1 == 0 else { throw Archive.Failure.zip("encrypted") }
        // ponytail: 1 ファイル 2 GiB まで（全部をメモリに読む）
        guard size <= 1 << 31, compressedSize <= 1 << 31 else { throw Archive.Failure.zip("entry too large") }
        guard let h = try? FileHandle(forReadingFrom: url) else { throw Archive.Failure.io("open \(url.path)") }
        defer { try? h.close() }
        try h.seek(toOffset: localOffset)
        let local = [UInt8](try h.read(upToCount: 30) ?? Data())
        guard local.count == 30, le32(local, 0) == 0x0403_4b50 else { throw Archive.Failure.zip("bad local header") }
        try h.seek(toOffset: localOffset + 30 + UInt64(le16(local, 26)) + UInt64(le16(local, 28)))
        let packed = [UInt8](try h.read(upToCount: Int(compressedSize)) ?? Data())
        guard packed.count == Int(compressedSize) else { throw Archive.Failure.zip("truncated") }
        switch method {
        case 0:
            return packed
        case 8:
            if size == 0 { return [] }
            var out = [UInt8](repeating: 0, count: Int(size))
            let n = out.withUnsafeMutableBufferPointer { dst in
                packed.withUnsafeBufferPointer { src in
                    compression_decode_buffer(dst.baseAddress!, dst.count, src.baseAddress!, src.count, nil,
                                              COMPRESSION_ZLIB)
                }
            }
            guard n == Int(size) else { throw Archive.Failure.zip("inflate failed") }
            guard crc32(out) == crc else { throw Archive.Failure.zip("crc mismatch") }
            return out
        default:
            throw Archive.Failure.zip("unsupported method \(method)")
        }
    }
}

func le16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}
func le64(_ b: [UInt8], _ i: Int) -> UInt64 { UInt64(le32(b, i)) | UInt64(le32(b, i + 4)) << 32 }

func crc32(_ data: [UInt8]) -> UInt32 {
    data.withUnsafeBufferPointer { UInt32(zlib.crc32(0, $0.baseAddress, uInt($0.count))) }
}
