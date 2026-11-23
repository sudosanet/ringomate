import CoreBridge
import Foundation
import Render
import Testing

/// GPU がない・仮想の GPU で Metal 4 の準備ができない環境（CI）では何もしない。
@MainActor @Test func partIDsMatchWithAndWithoutMSAA() throws {
    guard let renderer = try? Renderer() else { return }
    let core = Core()
    let model = try core.load(model: Bundled.model, library: Bundled.library)
    try renderer.load(MeshInput(model, core: core))
    try core.setStage(width: 50, ground: 2)
    let height = renderer.modelHeight ?? 20
    let size = CGSize(width: 200, height: 240)
    let ppu = 220 / height
    var root = SIMD2<Float>.zero
    _ = renderer.snapshot(size: size, scale: 1, placement: Placement(anchor: .zero, pointsPerUnit: ppu)) { skin, positions in
        root = core.step(dt: 0, skin: skin, positions: positions).root
    }
    let placement = Placement(anchor: SIMD2(100, 10) - root * ppu, pointsPerUnit: ppu)
    let points = [0.9, 0.6].map { (100, 240 - 10 - Int(height * Float($0) * ppu)) } + [(5, 5)]
    var seen: [[UInt8]] = []
    for samples in [1, 4] {
        renderer.antialiasing = samples
        _ = renderer.snapshot(size: size, scale: 1, placement: placement) { skin, positions in
            core.step(dt: 0, skin: skin, positions: positions)
        }
        seen.append(points.map { renderer.part(atPixel: $0.0, $0.1) })
    }
    #expect(seen[0] == seen[1], "1x \(seen[0]) / 4x \(seen[1])")
    #expect(seen[1][0] != 0 && seen[1][1] != 0 && seen[1][2] == 0)
}
