import CoreGraphics
import Foundation
import Metal
import os
import QuartzCore
import simd

extension Renderer {
    public func snapshot(
        size: CGSize, scale: Int = 2, placement: Placement,
        update: (_ skin: UnsafeMutableRawBufferPointer, _ positions: UnsafeMutableRawBufferPointer) -> Void = { _, _ in }
    ) -> CGImage? {
        guard waitIdle(), let model else { return nil }
        update(UnsafeMutableRawBufferPointer(start: model.skin.contents(), count: model.skin.length),
               UnsafeMutableRawBufferPointer(start: model.positions.contents(), count: model.positions.length))
        let (w, h) = (Int(size.width) * scale, Int(size.height) * scale)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else { return nil }
        residency.addAllocation(target)
        residency.commit()
        defer { residency.removeAllocation(target); residency.commit() }
        submit(target: target, model: model, placement: placement, size: size)
        guard waitIdle() else { return nil }

        return Self.image(target)
    }

    static func image(_ target: MTLTexture) -> CGImage? {
        let (w, h) = (target.width, target.height)
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func normalizedTint(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let luma = simd_dot(c, SIMD3(0.299, 0.587, 0.114))
        guard luma > 0.02 else { return SIMD3(repeating: 1) }
        return simd_clamp(c / luma, SIMD3(repeating: 0.6), SIMD3(repeating: 1.4))
    }

    static func viewProj(_ placement: Placement, size: CGSize) -> simd_float4x4 {
        let (w, h) = (Float(size.width), Float(size.height))
        let s = placement.pointsPerUnit
        return simd_float4x4(columns: (
            SIMD4(2 * s / w, 0, 0, 0),
            SIMD4(0, 2 * s / h, 0, 0),
            SIMD4(0, 0, 0.01, 0),
            SIMD4(2 * placement.anchor.x / w - 1, 2 * placement.anchor.y / h - 1, 0.5, 1)
        ))
    }
}
