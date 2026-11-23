@testable import Engine
import simd
import Testing

/// 太ももだけが骨の軸のまわりに 120° ねじれ、すねの向きは変わらない区間を作る（ひざの曲げ軸が太ももに対してずれる）。
private func legMotion(flip: Range<Int>) -> BVH.RawMotion {
    let names = ["Hips", "RightUpLeg", "RightLeg", "RightFoot"]
    let parents: [Int?] = [nil, 0, 1, 2]
    let offsets: [SIMD3<Float>] = [SIMD3(0, 10, 0), SIMD3(-1, 0, 0), SIMD3(0, -4, 0), SIMD3(0, -4, 0)]
    let id = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    let poses: [[BVH.Local]] = (0..<120).map { f in
        let swing = simd_quatf(angle: 0.6 * sin(Float(f) * 0.1), axis: SIMD3(1, 0, 0))
        let knee = simd_quatf(angle: 0.8 + 0.3 * sin(Float(f) * 0.13), axis: SIMD3(1, 0, 0))
        var thigh = swing, calf = knee
        if flip.contains(f) {
            let twist = simd_quatf(angle: 2.1, axis: SIMD3(0, -1, 0))
            thigh = swing * twist
            calf = twist.inverse * knee
        }
        return [(offsets[0], id), (offsets[1], thigh), (offsets[2], calf), (offsets[3], id)]
    }
    return BVH.RawMotion(names: names, parents: parents, offsets: offsets, fps: 30, poses: poses)
}

@Test func legTwistFlipIsFoundAndRepairedInPlace() {
    var m = legMotion(flip: 50..<56)
    let flips = DanceFlips.find(m)
    #expect(flips.count == 1)
    #expect(flips.first?.start == 50 && flips.first?.end == 56)
    let before = m
    #expect(DanceFlips.repair(&m) == 1)
    #expect(DanceFlips.find(m).isEmpty)
    for f in m.poses.indices where !(47..<59).contains(f) {
        for j in m.names.indices { #expect(m.poses[f][j].1.vector == before.poses[f][j].1.vector) }
    }
    // 関節の位置は変わらない（骨の軸のまわりの回転だけ）
    for f in 50..<56 {
        let (a, b) = (DanceFlips.worldRotations(m, f), DanceFlips.worldRotations(before, f))
        for j in m.names.indices { #expect(simd_distance(a[j].columns.3.xyz, b[j].columns.3.xyz) < 1e-3) }
    }
}

@Test func cleanLegMotionIsUntouched() {
    var m = legMotion(flip: 0..<0)
    #expect(DanceFlips.find(m).isEmpty)
    #expect(DanceFlips.repair(&m) == 0)
}
