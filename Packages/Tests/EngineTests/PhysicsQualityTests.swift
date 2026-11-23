@testable import Engine
import Foundation
import simd
import Testing

@Test func floorFollowsTheSurfaceUnderFoot() throws {
    let scene = Scene()
    _ = try scene.load(model: Assets.model, library: Assets.library)
    scene.commitLoad()
    let c = scene.character!
    guard let w = c.physics, let i = w.floorIndex else {
        Issue.record("no floor body")
        return
    }
    var intent = Intent()
    intent.root = SIMD3(5, 2, 0)
    intent.facing = 0.5
    intent.surfaces = [SIMD3(-10, 30, 2), SIMD3(-1.0e4, 1.0e4, 0)]
    for _ in 0..<10 { c.step(1.0 / 60, intent) }
    let (p, q) = w.engine.transform(i)
    let center = Math.rotate(Math.rotY(-0.5), SIMD3(10, 2 - 2, 0) - SIMD3(5, 2, 0) - SIMD3(0, c.ground - c.drop, 0))
    #expect(simd_distance(p, center) < 0.01, "floor at \(p), expected \(center)")
    #expect(abs(w.floorHalf.x - 20) < 1e-4)
    #expect(abs(simd_dot(q.vector, Math.rotY(-0.5).vector)) > 0.9999)
}
