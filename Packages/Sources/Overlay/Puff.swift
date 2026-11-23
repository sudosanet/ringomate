import AppKit

extension CALayer {
    @MainActor func addPuff(at center: CGPoint, size: CGFloat) {
        let emitter = CAEmitterLayer()
        emitter.frame = bounds
        emitter.emitterPosition = center
        emitter.emitterShape = .circle
        emitter.emitterMode = .volume
        emitter.emitterSize = CGSize(width: size * 0.35, height: size * 0.35)
        emitter.renderMode = .unordered
        emitter.beginTime = CACurrentMediaTime()

        let cell = CAEmitterCell()
        cell.contents = Self.puffImage
        cell.birthRate = 260
        cell.lifetime = 0.85
        cell.lifetimeRange = 0.3
        cell.velocity = size * 0.9
        cell.velocityRange = size * 0.5
        cell.emissionRange = .pi * 2
        cell.yAcceleration = size * 1.2
        cell.scale = size / 64 * 0.45
        cell.scaleRange = size / 64 * 0.2
        cell.scaleSpeed = size / 64 * 0.7
        cell.alphaSpeed = -1.1
        cell.spin = 0.6
        cell.spinRange = 2
        cell.color = NSColor(white: 1, alpha: 0.9).cgColor
        cell.redRange = 0.04
        cell.greenRange = 0.04
        cell.blueRange = 0.06
        emitter.emitterCells = [cell]
        addSublayer(emitter)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            emitter.birthRate = 0
            try? await Task.sleep(for: .milliseconds(1300))
            emitter.removeFromSuperlayer()
        }
    }

    private static let puffImage: CGImage? = {
        let n = 64
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.93, alpha: 0.85), CGColor(gray: 0.85, alpha: 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors,
                                        locations: [0, 0.55, 1]) else { return nil }
        let c = CGPoint(x: CGFloat(n) / 2, y: CGFloat(n) / 2)
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: c.x - 6, y: c.y + 6), startRadius: 0,
                               endCenter: c, endRadius: CGFloat(n) / 2, options: [])
        return ctx.makeImage()
    }()
}
