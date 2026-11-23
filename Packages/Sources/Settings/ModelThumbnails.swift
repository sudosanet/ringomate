import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

public enum ModelThumbnails {
    public static let didSave = Notification.Name("app.ringomate.thumbnailSaved")
    static let size = 256

    static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "app.ringomate/thumbnails")
    }

    static func file(for path: String) -> URL? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (a[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(path)|\(size)|\(mtime)|face".utf8))
        return folder.appending(path: digest.prefix(12).map { String(format: "%02x", $0) }.joined() + ".png")
    }

    public static func image(for path: String) -> NSImage? {
        guard let url = file(for: path) else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 顔の画像がなければ全身。
    public static func face(for path: String) -> NSImage? {
        file(for: path).flatMap { NSImage(contentsOf: faceFile($0)) } ?? image(for: path)
    }

    /// `face` は `image` のピクセルの矩形（上が 0）。
    public static func save(_ image: CGImage, for path: String, face: CGRect? = nil) {
        guard let url = file(for: path), let cropped = crop(image), let small = shrink(cropped) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let rect = face?.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)),
           let head = image.cropping(to: rect).flatMap(shrink) {
            write(head, to: faceFile(url))
        }
        if write(small, to: url) { NotificationCenter.default.post(name: didSave, object: path) }
    }

    private static func faceFile(_ url: URL) -> URL { url.deletingPathExtension().appendingPathExtension("face.png") }

    private static func write(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }

    static func crop(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        let pad = max(maxX - minX, maxY - minY) / 20
        let rect = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + 1 + pad * 2, height: maxY - minY + 1 + pad * 2)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        return image.cropping(to: rect)
    }

    static func shrink(_ image: CGImage) -> CGImage? {
        let scale = min(1, Double(size) / Double(max(image.width, image.height)))
        let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (size - w) / 2, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
