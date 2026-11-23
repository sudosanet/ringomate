import CoreBridge
import Foundation
import Render
import Testing

/// 非表示のときに外して、表示したときに読みなおせる。GPU がない環境（CI）では何もしない。
@MainActor @Test func unloadsAndReloads() throws {
    guard let renderer = try? Renderer() else { return }
    let core = Core()
    let model = try core.load(model: Bundled.model, library: Bundled.library)
    try renderer.load(MeshInput(model, core: core))
    let (skin, pos) = (UnsafeMutableRawBufferPointer.allocate(byteCount: Int(model.boneCount) * 64, alignment: 16),
                       UnsafeMutableRawBufferPointer.allocate(byteCount: model.positions.count * 4, alignment: 16))
    defer { skin.deallocate(); pos.deallocate() }
    let placement = Placement(anchor: [100, 15], pointsPerUnit: 10)
    #expect(renderer.snapshot(size: CGSize(width: 200, height: 240), scale: 1, placement: placement) != nil)
    _ = core.stepAhead(dt: 1.0 / 60.0, input: .init(), skin: skin, positions: pos)

    core.unload()
    renderer.unload()
    #expect(renderer.modelHeight == nil)
    #expect(core.step(dt: 1.0 / 60.0, skin: skin, positions: pos).bones == 0)
    #expect(core.stepAhead(dt: 1.0 / 60.0, input: .init(), skin: skin, positions: pos).bones == 0)
    #expect(renderer.part(atPixel: 10, 10) == 0)

    let again = try core.load(model: Bundled.model, library: Bundled.library)
    try renderer.load(MeshInput(again, core: core))
    #expect(renderer.modelHeight != nil)
    #expect(core.step(dt: 1.0 / 60.0, skin: skin, positions: pos).bones == model.boneCount)
    #expect(renderer.snapshot(size: CGSize(width: 200, height: 240), scale: 1, placement: placement) != nil)
}
