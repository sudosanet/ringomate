import MascotCore
import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// 座標は絵の左下を原点にした 0〜1（Vision と同じ）。
public struct FoundObject: Sendable {
    public var box: CGRect
    /// 上の縁のほぼ平らな区間。
    public var seat: (minX: Double, maxX: Double, y: Double)?
    public var crop: CGImage?
}

/// 絵の中の目立つ物を大きい順に切り抜く（Vision、端末内）。
public func findObjects(in image: CGImage, limit: Int = 3, seatWidth: Double = 0.04) async -> [FoundObject] {
    let all = await salientBoxes(in: image)
    let sized: [CGRect] = all.filter { r in r.width * r.height > 0.002 && r.width * r.height < 0.5 }
    let boxes = sized.sorted { a, b in a.width * a.height > b.width * b.height }.prefix(limit)
    var out: [FoundObject] = []
    for box in boxes {
        let request = GenerateIterativeSegmentationRequest(seedBox: NormalizedRect(normalizedRect: box))
        request.qualityLevel = GenerateIterativeSegmentationRequest.QualityLevel.balanced
        if case .notReady = await request.assetStatus { try? await request.downloadAssets() }
        var object = FoundObject(box: box, seat: nil, crop: image.cropping(to: pixelRect(box, image)))
        let result: PixelBufferObservation?? = try? await request.perform(on: image)
        if let observation = result ?? nil, let read = observation.pixelBuffer.withUnsafeBuffer({ readMask($0) }) {
            let (mask, w, h) = read
            if let s = seat(mask: mask, width: w, height: h, minWidth: Int(seatWidth * Double(w))) {
                object.seat = (Double(s.minX) / Double(w), Double(s.maxX) / Double(w), 1 - Double(s.y) / Double(h))
            }
        }
        out.append(object)
    }
    return out
}

/// 0〜1、左下原点。
public func salientBoxes(in image: CGImage) async -> [CGRect] {
    func rects(_ objects: [RectangleObservation]) -> [CGRect] {
        objects.map { CGRect(origin: $0.boundingBox.origin, size: CGSize(width: $0.boundingBox.width, height: $0.boundingBox.height)) }
    }
    let objectness = (try? await GenerateObjectnessBasedSaliencyImageRequest().perform(on: image)).map { rects($0.salientObjects) } ?? []
    if !objectness.isEmpty { return objectness }
    return (try? await GenerateAttentionBasedSaliencyImageRequest().perform(on: image)).map { rects($0.salientObjects) } ?? []
}

private func pixelRect(_ box: CGRect, _ image: CGImage) -> CGRect {
    let w = CGFloat(image.width), h = CGFloat(image.height)
    return CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h).integral
}

private func readMask(_ pb: CVPixelBuffer) -> ([UInt8], Int, Int)? {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
    var out = [UInt8](repeating: 0, count: w * h)
    switch CVPixelBufferGetPixelFormatType(pb) {
    case kCVPixelFormatType_OneComponent8:
        for y in 0..<h { for x in 0..<w { out[y * w + x] = base.load(fromByteOffset: y * row + x, as: UInt8.self) } }
    case kCVPixelFormatType_OneComponent16Half:
        for y in 0..<h {
            for x in 0..<w {
                out[y * w + x] = UInt8(min(max(Float(base.load(fromByteOffset: y * row + x * 2, as: Float16.self)), 0), 1) * 255)
            }
        }
    case kCVPixelFormatType_OneComponent32Float:
        for y in 0..<h {
            for x in 0..<w { out[y * w + x] = UInt8(min(max(base.load(fromByteOffset: y * row + x * 4, as: Float.self), 0), 1) * 255) }
        }
    default:
        return nil
    }
    return (out, w, h)
}

func seat(mask: [UInt8], width: Int, height: Int, minWidth: Int) -> (minX: Int, maxX: Int, y: Int)? {
    let top: [Int?] = (0..<width).map { x in (0..<height).first { mask[$0 * width + x] >= 128 } }
    let tolerance = max(1, height / 50)
    var best: (Int, Int)?
    var start = 0
    while start < width {
        guard let t0 = top[start] else { start += 1; continue }
        var end = start
        while end + 1 < width, let t = top[end + 1], abs(t - t0) <= tolerance { end += 1 }
        if end - start + 1 >= max(minWidth, 1), best.map({ end - start > $0.1 - $0.0 }) ?? true { best = (start, end) }
        start = end + 1
    }
    guard let (a, b) = best else { return nil }
    let ys = top[a...b].compactMap { $0 }.sorted()
    return (a, b, ys[ys.count / 2])
}
