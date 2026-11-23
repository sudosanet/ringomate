import Foundation
import Testing
@testable import CoreBridge

enum Bundled {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized
    static let model = repo.appending(path: "assets/tsukuyomi/Tsukuyomi.vrm").path
    static let library = repo.appending(path: "assets/ual/UAL1_Standard.glb").path
}

@Test func boundaryRoundTrip() {
    let core = Core()
    let skin = UnsafeMutableRawBufferPointer.allocate(byteCount: 64, alignment: 16)
    defer { skin.deallocate() }
    #expect(core.step(dt: 1.0 / 60.0, skin: skin, positions: UnsafeMutableRawBufferPointer(start: nil, count: 0)).bones == 0)
}

@Test func loadsBundledModel() throws {
    let core = Core()
    let model = try core.load(model: Bundled.model, library: Bundled.library)
    #expect(model.boneCount == 156)
    #expect(model.walkSpeed > 5 && model.seatHeight > 3)
    let skin = UnsafeMutableRawBufferPointer.allocate(byteCount: Int(model.boneCount) * 64, alignment: 16)
    let pos = UnsafeMutableRawBufferPointer.allocate(byteCount: model.positions.count * 4, alignment: 16)
    defer { skin.deallocate(); pos.deallocate() }
    try core.setStage(width: 100, ground: 5)
    var out = core.step(dt: 1.0 / 30.0, skin: skin, positions: pos)
    #expect(out.bones == 156)
    for _ in 0..<60 { out = core.step(dt: 1.0 / 30.0, skin: skin, positions: pos) }
    #expect(out.grounded && abs(out.root.y - 5) < 0.5)

    for _ in 0..<10 { out = core.step(dt: 1.0 / 30.0, input: .init(drag: .hold([50, 30])), skin: skin, positions: pos) }
    #expect(!out.grounded && abs(out.root.x - 50) < 1 && out.root.y > 20)
    out = core.step(dt: 1.0 / 30.0, input: .init(drag: .release), skin: skin, positions: pos)
    for _ in 0..<120 { out = core.step(dt: 1.0 / 30.0, skin: skin, positions: pos) }
    #expect(out.grounded && abs(out.root.y - 5) < 0.5)

    var appear = 0, vanish = 0
    for _ in 0..<30 { appear += core.step(dt: 1.0 / 30.0, input: .init(motion: .sit), skin: skin, positions: pos).puffs.count }
    for _ in 0..<30 { vanish += core.step(dt: 1.0 / 30.0, input: .init(motion: .idle), skin: skin, positions: pos).puffs.count }
    #expect(appear == 0 && vanish == 1)

    out = core.step(dt: 1.0 / 30.0, skin: skin, positions: pos)
    #expect(out.bones == 156)
}

@Test func stepAheadMatchesStepOneFrameLater() throws {
    let (pmx, library) = (Bundled.model, Bundled.library)
    let a = Core()
    let model = try a.load(model: pmx, library: library)
    try a.setStage(width: 100, ground: 5)
    let (skin, pos) = (UnsafeMutableRawBufferPointer.allocate(byteCount: Int(model.boneCount) * 64, alignment: 16),
                       UnsafeMutableRawBufferPointer.allocate(byteCount: model.positions.count * 4, alignment: 16))
    defer { skin.deallocate(); pos.deallocate() }
    let inputs = (0..<40).map { i in Core.Input(motion: i < 20 ? .idle : .walk, walkVelocity: i < 20 ? 0 : 6) }
    var expected: [(Core.Output, [UInt8], [UInt8])] = []
    for i in inputs.indices {
        let out = a.step(dt: 1.0 / 60.0, input: inputs[max(i - 1, 0)], skin: skin, positions: pos)
        expected.append((out, Array(skin), Array(pos)))
    }
    let b = Core()
    _ = try b.load(model: pmx, library: library)
    try b.setStage(width: 100, ground: 5)
    for (i, input) in inputs.enumerated() {
        let out = b.stepAhead(dt: 1.0 / 60.0, input: input, skin: skin, positions: pos)
        #expect(out.root == expected[i].0.root && out.grounded == expected[i].0.grounded && out.bones == expected[i].0.bones)
        #expect(Array(skin) == expected[i].1, "frame \(i)")
        #expect(Array(pos) == expected[i].2, "frame \(i)")
    }
    b.drain()
}
