import CoreGraphics
import Foundation
import ImageIO

/// ponytail: BC7（DX10 拡張ヘッダー）・BC4/5・キューブマップは ImageIO まかせ（読めなければ nil）。
enum DDS {
    static func isDDS(_ b: [UInt8]) -> Bool { b.count >= 4 && b[0..<4].elementsEqual("DDS ".utf8) }

    static func png(_ bytes: [UInt8]) -> [UInt8]? {
        if let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return pngData(image)
        }
        guard let (w, h, rgba) = decode(bytes),
              let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return pngData(image)
    }

    static func pngData(_ image: CGImage) -> [UInt8]? {
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, image, nil)
        return CGImageDestinationFinalize(dst) ? [UInt8](out as Data) : nil
    }

    static func u32(_ b: [UInt8], _ o: Int) -> UInt32? { o + 4 <= b.count ? le32(b, o) : nil }

    static func decode(_ b: [UInt8]) -> (Int, Int, [UInt8])? {
        guard isDDS(b), u32(b, 4) == 124, let h32 = u32(b, 12), let w32 = u32(b, 16) else { return nil }
        let (w, h) = (Int(w32), Int(h32))
        guard w > 0, h > 0, w <= 16384, h <= 16384, let flags = u32(b, 80), b.count >= 128 else { return nil }
        let data = Array(b[128...])
        if flags & 0x4 != 0 { return nil }
        guard let bits32 = u32(b, 88), let m0 = u32(b, 92), let m1 = u32(b, 96), let m2 = u32(b, 100), let m3 = u32(b, 104)
        else { return nil }
        let bits = Int(bits32)
        guard bits == 32 || bits == 24 else { return nil }
        let step = bits / 8
        guard data.count >= w * h * step else { return nil }
        func channel(_ v: UInt32, _ m: UInt32) -> UInt8 {
            if m == 0 { return 255 }
            let shift = UInt32(m.trailingZeroBitCount)
            let max = m >> shift
            return UInt8(truncatingIfNeeded: ((v & m) >> shift) &* 255 / max)
        }
        let alpha = flags & 0x1 != 0
        var out = [UInt8]()
        out.reserveCapacity(w * h * 4)
        for p in 0..<(w * h) {
            var v: UInt32 = 0
            for k in (0..<step).reversed() { v = v << 8 | UInt32(data[p * step + k]) }
            out += [channel(v, m0), channel(v, m1), channel(v, m2), alpha ? channel(v, m3) : 255]
        }
        return (w, h, out)
    }

}
