import CoreGraphics
import Testing
@testable import Senses
import MascotCore

@Test func seatIsTheFlatTopOfTheMask() {
    let w = 100, h = 80
    var mask = [UInt8](repeating: 0, count: w * h)
    for y in 30..<h { for x in 20..<80 { mask[y * w + x] = 255 } }
    let s = seat(mask: mask, width: w, height: h, minWidth: 10)
    #expect(s?.minX == 20 && s?.maxX == 79 && s?.y == 30)
    var peak = [UInt8](repeating: 0, count: w * h)
    for x in 0..<w { for y in (abs(x - 50) + 10)..<h { peak[y * w + x] = 255 } }
    #expect(seat(mask: peak, width: w, height: h, minWidth: 10) == nil)
}

@Test func findsAnObjectInAPicture() async throws {
    let ctx = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    ctx.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)); ctx.fill(CGRect(x: 120, y: 40, width: 160, height: 120))
    let found = await findObjects(in: try #require(ctx.makeImage()))
    print("FOUND:", found.map { ($0.box, $0.seat as Any) })
    let box = try #require(found.first?.box)
    #expect(abs(box.midX - 0.5) < 0.1)
    if let s = found.first?.seat { #expect(abs(s.y - 160.0 / 300) < 0.05) }
}
