import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// 足もとの帯の、列ごとのごちゃごちゃ度（0〜1）。文字・模様・動いているところが高い。
public enum FreeSpace {
    public static let columns = 64
    static let width = 256

    /// `band` はディスプレイの座標（ポイント、左上が原点）。`skip` に当たるアプリは撮らない。撮った絵は保存しない。
    public static func busyColumns(displayID: CGDirectDisplayID, band: CGRect, skip: @Sendable (String?) -> Bool) async -> [Float]? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let apps = content.applications.filter { $0.bundleIdentifier == "app.ringomate" || skip($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = band
        config.width = width
        config.height = max(Int(CGFloat(width) * band.height / max(band.width, 1)), 2)
        config.showsCursor = false
        guard let a = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        try? await Task.sleep(for: .milliseconds(500))
        guard let b = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        let (ga, gb) = (gray(a), gray(b))
        let edges = edgeColumns(gray: gb, width: b.width, height: b.height, columns: columns)
        let motion = ga.count == gb.count ? motionColumns(ga, gb, width: b.width, columns: columns) : []
        return edges.enumerated().map { i, e in max(e, motion.isEmpty ? 0 : motion[i]) }
    }

    static func gray(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: image.width * image.height)
        guard let ctx = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return px }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return px
    }

    /// 隣（左・上）との明るさの差が 20 を超える画素の割合。8 倍して 1 で切る（文字は 1 割強でふさがり）。
    static func edgeColumns(gray px: [UInt8], width w: Int, height h: Int, columns: Int) -> [Float] {
        var count = [Int](repeating: 0, count: columns)
        guard w > 1, h > 1, px.count >= w * h else { return [Float](repeating: 0, count: columns) }
        for y in 1..<h {
            for x in 1..<w {
                let v = Int(px[y * w + x])
                if abs(v - Int(px[y * w + x - 1])) > 20 || abs(v - Int(px[(y - 1) * w + x])) > 20 { count[x * columns / w] += 1 }
            }
        }
        let per = Float(w * h) / Float(columns)
        return count.map { min(Float($0) / per * 8, 1) }
    }

    /// 2 枚で明るさが 12 を超えて変わった画素がある列は 1。
    static func motionColumns(_ a: [UInt8], _ b: [UInt8], width w: Int, columns: Int) -> [Float] {
        var out = [Float](repeating: 0, count: columns)
        for i in 0..<min(a.count, b.count) where abs(Int(a[i]) - Int(b[i])) > 12 { out[(i % w) * columns / w] = 1 }
        return out
    }
}
