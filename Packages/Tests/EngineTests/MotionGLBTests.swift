@testable import Engine
import Foundation
import simd
import Testing

/// 回転のいちばん大きいずれ（度）。
private func worstDegrees(_ a: BVH.RawMotion, _ b: BVH.RawMotion) -> Float {
    var worst: Float = 0
    for (p, q) in zip(a.poses, b.poses) {
        for (x, y) in zip(p, q) { worst = max(worst, 2 * acos(min(abs(simd_dot(x.1.vector, y.1.vector)), 1)) * 180 / .pi) }
    }
    return worst
}

@Test func motionGLBRoundTrips() throws {
    let names = ["Hips", "Spine", "Head"]
    let poses: [[BVH.Local]] = (0..<30).map { k in
        names.indices.map { j in
            (j == 0 ? SIMD3(Float(k), 90, 0) : .zero, simd_quatf(angle: Float(k + j) * 0.05, axis: simd_normalize(SIMD3(1, Float(j), 0.5))))
        }
    }
    let m = BVH.RawMotion(names: names, parents: [nil, 0, 1], offsets: [.zero, [0, 10, 0], [0, 20, 0]], fps: 30, poses: poses)
    let back = try BVH.readMotionGLB(BVH.writeMotionGLB(m))
    #expect(back.names == names && back.parents == m.parents && back.offsets == m.offsets && back.poses.count == 30)
    #expect(zip(back.poses, poses).allSatisfy { simd_distance($0[0].0, $1[0].0) < 1e-4 })
    #expect(worstDegrees(back, m) < 0.3)
}

