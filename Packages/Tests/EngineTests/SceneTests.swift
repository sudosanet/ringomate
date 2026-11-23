@testable import Engine
import Foundation
import simd
import Testing

private func loadModel() throws -> (Scene, ModelData) {
    let scene = Scene()
    let data = try scene.load(model: Assets.model, library: Assets.library)
    return (scene, data)
}

private func angle(_ a: simd_quatf, _ b: simd_quatf) -> Float { 2 * acos(min(abs(simd_dot(a.vector, b.vector)), 1)) }

@Test func stepWithoutModelIsSafe() {
    var skin = [Float](repeating: 0, count: 16)
    let out = skin.withUnsafeMutableBufferPointer { Scene().step(1.0 / 60, Scene.Inputs(), skin: $0, positions: .init(start: nil, count: 0)) }
    #expect(out == nil)
}

@Test func stepWithModelWritesMatrices() throws {
    let (scene, data) = try loadModel()
    #expect(scene.textureBytes(0) == nil)
    scene.commitLoad()
    var skin = [Float](repeating: 0, count: data.boneCount * 16)
    var pos = [Float](repeating: 0, count: data.positions.count)
    let out = skin.withUnsafeMutableBufferPointer { s in pos.withUnsafeMutableBufferPointer { p in scene.step(1.0 / 30, Scene.Inputs(), skin: s, positions: p) } }
    #expect(out?.bones == data.boneCount)
    #expect(skin.allSatisfy { $0.isFinite })
    #expect(data.materials.reduce(0) { $0 + $1.indexCount } == data.indices.count)
}

@Test func standingOnAWindowIsNotAirborne() throws {
    let (scene, _) = try loadModel()
    scene.commitLoad()
    func run(_ drag: UInt32) -> (Slot, Float) {
        var inputs = Scene.Inputs()
        (inputs.drag, inputs.dragTo, inputs.motion) = (drag, SIMD2(10, 30), .gesture(0))
        var out: Scene.Output?
        for _ in 0..<60 { out = scene.step(1.0 / 60, inputs) }
        return (scene.character!.player.current, out!.root.y)
    }
    #expect(run(1).0 == .fall)
    let (perched, y) = run(3)
    #expect(perched == .gesture(0))
    #expect(abs(y - 30) < 0.1, "root \(y)")
}

@Test(.enabled(if: Assets.hasSongs)) func songDancesWalkForReal() throws {
    let dance = Assets.url("assets/songs/goodbye-sengen/dance.glb")
    let (scene, data) = try loadModel()
    scene.commitLoad()
    scene.setStage(width: 2000, ground: 0)
    scene.teleport(x: 1000, y: 0)
    try scene.assignSongDance(index: 508, path: dance, front: nil)
    let (dt, bpm): (Float, Float) = (1.0 / 60, 170)
    let c = scene.character!
    let hips = c.bone("センター")!
    var (xs, gaps): ([Float], [Float]) = ([], [])
    for k in 0..<Int(60 * 160 / bpm * 60) {
        let clip = Float(k) * dt * bpm / 60
        var inputs = Scene.Inputs()
        inputs.motion = .dance(508)
        inputs.song = SongPlay(clipTime: clip * 60 / bpm, rate: 1)
        let out = scene.step(dt, inputs)!
        xs.append(out.root.x)
        gaps.append(c.boneWorld(hips).columns.3.x / data.height)
    }
    let walked = (xs.max()! - xs.min()!) / data.height
    let gap = gaps.map(abs).max()!
    print("walked \(walked) heights, hips from the feet at most \(gap) heights")
    #expect(walked > 0.3, "the character should travel: \(walked)")
    #expect(gap < 0.35, "the hips should stay over the feet: \(gap)")
}

@Test(.enabled(if: Assets.hasSongs)) func songDanceFingersMove() throws {
    let dance = Assets.url("assets/songs/ai-scream/dance.glb")
    let (scene, _) = try loadModel()
    scene.commitLoad()
    try scene.assignSongDance(index: 508, path: dance, front: nil)
    let c = scene.character!
    let bones = ["右人指１", "右人指２", "右中指１", "右親指１", "左人指１"].compactMap(c.bone)
    var seen = [[simd_quatf]](repeating: [], count: bones.count)
    for k in 0..<600 {
        let clip = Float(k) / 60 * 132 / 60
        var intent = Intent()
        intent.motion = .dance(508)
        intent.beat = Beat(bpm: 132, phase: clip - clip.rounded(.towardZero), energy: 1, clip: clip)
        c.step(1.0 / 60, intent)
        for (i, b) in bones.enumerated() {
            let p = c.boneWorld(Int(c.model.pmx.bones[b].parentIndex))
            seen[i].append(simd_quatf(simd_inverse(p) * c.boneWorld(b)))
        }
    }
    let moved = seen.filter { q in q.contains { angle($0, q[0]) > 0.3 } }.count
    #expect(moved >= 3, "fingers should move")
}

@Test func modelInfoReadsNamesAndTerms() throws {
    let pmxURL = FileManager.default.temporaryDirectory.appending(path: "ringomate-model-info/model.pmx")
    try FileManager.default.createDirectory(at: pmxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(Assets.pmxBytes()).write(to: pmxURL)
    let pmx = try ModelInfo(pmxURL)
    #expect(pmx.format == "PMX")
    #expect(pmx.title.hasPrefix("つくよみちゃん") && pmx.bones == 134)
    let vrm = try ModelInfo(Assets.model)
    #expect(vrm.format == "VRM 0.x" && vrm.bones == 134)
    #expect(vrm.terms.contains { $0.name == "VRM terms of use" && $0.text.contains("Commercial use") })
}

@Test func fallsLandsAndCanBeThrown() {
    var env = Environment(height: 20, root: SIMD2(50, 40))
    env.setStage(width: 100, ground: 0)
    var p = SIMD2<Float>.zero
    for _ in 0..<240 { p = env.step(1.0 / 60, .none) }
    #expect(abs(p.y) < 0.3 && abs(p.x - 50) < 0.5, "landed at \(p)")
    #expect(env.grounded)
    for i in 0..<30 { _ = env.step(1.0 / 60, .hold(x: 50 + Float(i) * 1.5, y: 30)) }
    #expect(!env.grounded)
    _ = env.step(1.0 / 60, .release)
    for _ in 0..<600 { p = env.step(1.0 / 60, .none) }
    #expect(p.x > 80 && p.x < 100 && abs(p.y) < 0.3, "thrown to \(p)")
}

@Test func landsOnAWindowWhenThrown() {
    let window = SIMD3<Float>(40, 70, 25)
    func make(_ root: SIMD2<Float>) -> Environment {
        var env = Environment(height: 20, root: root)
        env.setStage(width: 100, ground: 0)
        env.setPlatforms([window])
        return env
    }
    var env = make(SIMD2(55, 45))
    var p = SIMD2<Float>.zero
    for _ in 0..<240 { p = env.step(1.0 / 60, .none) }
    #expect(abs(p.y - 25) < 0.3 && env.onLedge, "landed at \(p)")
    _ = env.step(1.0 / 60, .hold(x: p.x, y: p.y))
    env.dropThrough()
    _ = env.step(1.0 / 60, .release)
    for _ in 0..<240 {
        env.setPlatforms([window])
        p = env.step(1.0 / 60, .none)
    }
    #expect(abs(p.y) < 0.3 && env.grounded && !env.onLedge, "dropped to \(p)")
    env = make(SIMD2(55, 0))
    for _ in 0..<10 { _ = env.step(1.0 / 60, .none) }
    for i in 0..<10 { _ = env.step(1.0 / 60, .hold(x: 55, y: Float(i) * 1.2)) }
    _ = env.step(1.0 / 60, .release)
    var highest: Float = 0
    for _ in 0..<300 {
        p = env.step(1.0 / 60, .none)
        highest = max(highest, p.y)
    }
    #expect(highest > 25, "should pass the window from below: \(highest)")
    #expect(abs(p.y - 25) < 0.3 && env.onLedge, "should come down onto the window: \(p)")
    env = make(SIMD2(20, 40))
    for _ in 0..<240 { p = env.step(1.0 / 60, .none) }
    #expect(abs(p.y) < 0.3 && abs(p.x - 20) < 0.5 && env.grounded, "landed at \(p)")
    for i in 0..<30 { _ = env.step(1.0 / 60, .hold(x: 20 + Float(i) * 0.5, y: 10)) }
    _ = env.step(1.0 / 60, .release)
    for _ in 0..<600 { p = env.step(1.0 / 60, .none) }
    #expect(p.x > 20 && p.x < 100 && env.grounded, "thrown to \(p)")
}

@Test func secondLoadUsesTheBakeCache() throws {
    _ = try loadModel()
    let (_, data) = try loadModel()
    #expect(data.diagnostics.contains("motions: from the bake cache"))
}
