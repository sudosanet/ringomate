import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Senses

/// 足もとの帯（Retina 3420x720）: 左 1/4 に文字、次に何もない黒、グラデーション、右 1/4 に模様。
private func band() -> CGImage {
    let (w, h) = (3420, 720)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let font = CTFontCreateWithName("Menlo" as CFString, 26, nil)
    for row in 0..<24 {
        let s = NSAttributedString(string: "let value = compute(42) // \(row) more text here and there",
                                   attributes: [.font: font, .foregroundColor: CGColor(gray: 0.85, alpha: 1)])
        ctx.textPosition = CGPoint(x: 10, y: 10 + row * 30)
        CTLineDraw(CTLineCreateWithAttributedString(s), ctx)
    }
    for x in (w / 2)..<(w * 3 / 4) {
        ctx.setFillColor(CGColor(red: Double(x - w / 2) / Double(w / 4), green: 0.3, blue: 0.6, alpha: 1))
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
    }
    var seed: UInt64 = 7
    func next() -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int(seed >> 33) }
    for _ in 0..<4000 {
        let c = Double(next() % 60 + 20) / 100
        ctx.setFillColor(CGColor(red: c, green: c * 0.9, blue: c * 0.7, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w * 3 / 4 + next() % (w / 4), y: next() % h, width: next() % 50 + 10, height: next() % 50 + 10))
    }
    return ctx.makeImage()!
}

private func shrink(_ image: CGImage, width: Int) -> CGImage {
    let h = image.height * width / image.width
    let ctx = CGContext(data: nil, width: width, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: h))
    return ctx.makeImage()!
}

@Test func textAndPatternsAreBusyEmptyAndGradientsAreNot() {
    let img = shrink(band(), width: 256)
    let c = FreeSpace.edgeColumns(gray: FreeSpace.gray(img), width: img.width, height: img.height, columns: 64)
    #expect(c[0..<8].allSatisfy { $0 > 0.3 }, "\(c)")
    #expect(c[20..<31].allSatisfy { $0 < 0.05 }, "\(c)")
    #expect(c[33..<48].allSatisfy { $0 < 0.05 }, "\(c)")
    #expect(c[49..<64].allSatisfy { $0 > 0.3 }, "\(c)")
}

@Test func motionMarksOnlyChangedColumns() {
    let a = [UInt8](repeating: 10, count: 64 * 4)
    var b = a
    b[2 * 64 + 40] = 200
    let m = FreeSpace.motionColumns(a, b, width: 64, columns: 16)
    #expect(m == (0..<16).map { $0 == 10 ? 1 : 0 })
}
