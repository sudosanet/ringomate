@testable import Engine
import Foundation
import ImageIO
import Testing

private func header(_ w: UInt32, _ h: UInt32, _ flags: UInt32, _ cc: String, _ bits: UInt32, _ masks: [UInt32]) -> [UInt8] {
    var b = [UInt8](repeating: 0, count: 128)
    func put(_ o: Int, _ v: UInt32) { for k in 0..<4 { b[o + k] = UInt8(v >> (8 * k) & 0xff) } }
    b.replaceSubrange(0..<4, with: Array("DDS ".utf8))
    put(4, 124); put(8, 0x1007); put(12, h); put(16, w); put(76, 32); put(80, flags); put(108, 0x1000)
    b.replaceSubrange(84..<88, with: Array(cc.utf8))
    put(88, bits)
    for (i, m) in masks.enumerated() { put(92 + i * 4, m) }
    return b
}

@Test func decodesBC1AndUncompressed() throws {
    func firstPixel(_ d: [UInt8]) throws -> [UInt8] {
        let png = try #require(DDS.png(d))
        let src = try #require(CGImageSourceCreateWithData(Data(png) as CFData, nil))
        let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var out = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let c = try #require(CGContext(data: &out, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return Array(out[0..<4])
    }
    #expect(try firstPixel(header(4, 4, 0x4, "DXT1", 0, [0, 0, 0, 0]) + [0x00, 0xF8, 0x1F, 0x00, 0, 0, 0, 0]) == [255, 0, 0, 255])
    #expect(try firstPixel(header(4, 4, 0x4, "DXT1", 0, [0, 0, 0, 0]) + [0x00, 0xF8, 0x1F, 0x00, 0x55, 0x55, 0x55, 0x55]) == [0, 0, 255, 255])
    let raw = header(1, 1, 0x41, "\0\0\0\0", 32, [0xFF0000, 0xFF00, 0xFF, 0xFF00_0000]) + [10, 20, 30, 255]
    #expect(try #require(DDS.decode(raw)).2 == [30, 20, 10, 255])
    #expect(try firstPixel(raw) == [30, 20, 10, 255])
    #expect(DDS.png(Array("not a dds".utf8)) == nil)
}
