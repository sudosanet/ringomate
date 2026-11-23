import CoreGraphics
import Foundation
import ImageIO

/// 中身は乗算済み（premultiplied）のアルファで持つ。
enum TextureCache {
    enum Alpha: Int { case opaque = 0, cutout = 1, translucent = 2 }

    struct Levels {
        var width: Int
        var height: Int
        var alpha: Alpha
        var payloads: [Data]
    }

    static let version = 4
    private static let magic: UInt32 = 0x58544D41

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "app.ringomate/textures")
    }

    static func key(_ source: String, maxSize: Int) -> String {
        "\(source)-\(maxSize)-v\(version)"
    }

    static func purgeOldVersions() {
        let suffix = "-v\(version)"
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for f in files where !f.lastPathComponent.hasSuffix(suffix) { try? FileManager.default.removeItem(at: f) }
    }

    static func load(_ key: String) -> Levels? {
        guard let d = try? Data(contentsOf: directory.appending(path: key)), d.count >= 24 else { return nil }
        func u32(_ o: Int) -> Int { Int(d.subdata(in: o..<o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
        guard u32(0) == Int(magic) else { return nil }
        let (w, h, n, a) = (u32(4), u32(8), u32(12), u32(16))
        var o = 20
        var payloads: [Data] = []
        for _ in 0..<n {
            guard o + 4 <= d.count else { return nil }
            let len = u32(o)
            o += 4
            guard o + len <= d.count else { return nil }
            payloads.append(d.subdata(in: o..<o + len))
            o += len
        }
        return Levels(width: w, height: h, alpha: Alpha(rawValue: a) ?? .opaque, payloads: payloads)
    }

    static func store(_ levels: Levels, key: String) {
        var d = Data()
        func put(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        put(Int(magic)); put(levels.width); put(levels.height); put(levels.payloads.count); put(levels.alpha.rawValue)
        for p in levels.payloads {
            put(p.count)
            d.append(p)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? d.write(to: directory.appending(path: key), options: .atomic)
    }

    static func encode(_ image: CGImage, maxSize: Int) -> Levels? {
        var (w, h) = (image.width, image.height)
        while max(w, h) > maxSize { (w, h) = (max(w / 2, 1), max(h / 2, 1)) }
        let (w0, h0) = (w, h)
        var payloads: [Data] = []
        var alpha = Alpha.opaque
        while true {
            // ImageIO の ASTC は画像の下の行からブロックを書く（Metal は先頭を上として読む）ので、上下を反転して渡す
            guard let level = resized(image, w, h, flipped: true), let astc = astc(level) else { return nil }
            if payloads.isEmpty { alpha = classify(level) }
            payloads.append(astc)
            if w == 1 && h == 1 { break }
            (w, h) = (max(w / 2, 1), max(h / 2, 1))
        }
        return Levels(width: w0, height: h0, alpha: alpha, payloads: payloads)
    }

    static func classify(_ image: CGImage) -> Alpha {
        guard let data = image.dataProvider?.data as Data?, image.bitsPerPixel == 32 else { return .opaque }
        let bpr = image.bytesPerRow
        var (visible, soft, holes) = (0, 0, 0)
        data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in stride(from: 0, to: image.height, by: 2) {
                for x in stride(from: 0, to: image.width, by: 2) {
                    let a = Int(p[y * bpr + x * 4 + 3])
                    if a < 5 { holes += 1; continue }
                    visible += 1
                    if a > 25 && a < 230 { soft += 1 }
                }
            }
        }
        if visible > 0 && soft * 20 > visible { return .translucent }
        return holes > 0 ? .cutout : .opaque
    }

    static func resized(_ image: CGImage, _ w: Int, _ h: Int, flipped: Bool = false) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        if flipped {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard flipped else { return ctx.makeImage() }
        // ASTC 用: 乗算済みの画素を、乗算前（.last）と申告した画像にする（ImageIO に値を変えさせない）
        guard let data = ctx.data, let provider = CGDataProvider(data: Data(bytes: data, count: ctx.bytesPerRow * h) as CFData)
        else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ctx.bytesPerRow,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func astc(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "org.khronos.astc" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyASTCBlockSize: kCGImagePropertyASTCBlockSize4x4] as CFDictionary)
        guard CGImageDestinationFinalize(dest), out.length > 16 else { return nil }
        let d = out as Data
        let blocks = ((image.width + 3) / 4) * ((image.height + 3) / 4) * 16
        guard d.count - 16 == blocks else { return nil }
        return d.subdata(in: 16..<d.count)
    }
}
