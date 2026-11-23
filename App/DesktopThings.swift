import AI
import AppKit
import Behavior
import MascotCore
import os
import Senses

/// 撮った絵は保存しない。
@MainActor
final class DesktopThings {
    private struct Found {
        var thing: Mascot.Thing
        var seat: Mascot.Surface?
        var rect: CGRect
    }

    private var found: [Found] = []
    private var scanned: (screen: CGDirectDisplayID, ppu: Float, at: Date)?
    private var scanning = false
    private(set) var color: SIMD3<Float>?
    var style = AIStyle()
    private let log = Logger(subsystem: "app.ringomate", category: "things")

    func tick(screen: NSScreen?, ppu: Float, findThings: Bool, allowed: () -> Bool) {
        guard !scanning, let screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        if let s = scanned, s.screen == id, s.ppu == ppu, Date().timeIntervalSince(s.at) < 600 { return }
        guard allowed() else {
            scanned = (id, ppu, Date())
            return
        }
        scanning = true
        scanned = (id, ppu, Date())
        let frame = screen.frame, mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        Task { [weak self] in
            defer { self?.scanning = false }
            guard let image = await captureDesktop(displayID: id) else {
                self?.log.info("things: no desktop image")
                return
            }
            self?.color = Self.averageColor(image)
            guard findThings else {
                self?.found = []
                return
            }
            let style = self?.style ?? AIStyle()
            var out: [Found] = []
            let objects = await findObjects(in: image)
            for (i, o) in objects.enumerated() {
                guard let crop = o.crop, let d = await ObjectNamer.describe(crop, style: style) else { continue }
                let (w, h) = (Float(frame.width), Float(frame.height))
                let point = SIMD2(Float(o.box.midX) * w, Float(o.box.midY) * h) / ppu
                let thingID = -1000 - i
                var seat: Mascot.Surface?
                if d.sittable, let s = o.seat {
                    seat = .init(id: thingID, minX: Float(s.minX) * w / ppu, maxX: Float(s.maxX) * w / ppu,
                                 top: Float(s.y) * h / ppu, bottom: Float(o.box.minY) * h / ppu)
                }
                let rect = CGRect(x: frame.minX + o.box.minX * frame.width,
                                  y: mainHeight - frame.minY - o.box.maxY * frame.height,
                                  width: o.box.width * frame.width, height: o.box.height * frame.height)
                out.append(Found(thing: .init(id: thingID, name: d.name, comment: d.comment, point: point), seat: seat, rect: rect))
            }
            self?.found = out
            self?.log.info("things (\(objects.count) candidates): \(out.map { "\($0.thing.name)\($0.seat == nil ? "" : "(seat)")" }.joined(separator: ", "), privacy: .private)")
        }
    }

    nonisolated static func averageColor(_ image: CGImage) -> SIMD3<Float>? {
        let (w, h) = (32, 18)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = SIMD3<Float>(repeating: 0)
        let rows = (h * 2 / 3)..<h
        for y in rows {
            for x in 0..<w {
                let i = (y * w + x) * 4
                sum += SIMD3(Float(px[i]), Float(px[i + 1]), Float(px[i + 2]))
            }
        }
        return sum / Float(rows.count * w * 255)
    }

    func apply(to world: inout Mascot.World, windows: [DesktopWindow]) {
        for f in found where !windows.contains(where: { $0.frame.intersects(f.rect) }) {
            world.things.append(f.thing)
            if let s = f.seat { world.surfaces.append(s) }
        }
    }
}
