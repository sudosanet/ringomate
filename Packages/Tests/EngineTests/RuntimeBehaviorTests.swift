@testable import Engine
import Foundation
import simd
import Testing

enum Assets {
    static let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized
    static func url(_ path: String) -> URL { repo.appending(path: path) }
    static let model = url("assets/tsukuyomi/Tsukuyomi.vrm")
    static let library = url("assets/ual/UAL1_Standard.glb")
    /// 曲のパックは各自で入れるもの（CI は secret があるときだけ取る）
    static let hasSongs = FileManager.default.fileExists(atPath: url("assets/songs").path)

    /// 同梱モデルを PMX に変換したバイト列。
    static func pmxBytes() throws -> [UInt8] { try VRM.convert([UInt8](Data(contentsOf: model))).pmx.pmxBytes() }

    static func ual(_ names: [String], for model: LoadedModel) throws -> [String: BakedClip] {
        let (skel, clips) = try SourceClip.loadGLB([UInt8](Data(contentsOf: library)))
        var out: [String: BakedClip] = [:]
        for n in names {
            if let clip = clips.first(where: { $0.name == n }) {
                out[n] = Retarget.bake(skel, clip, model.pmx, model.profile.aliases)
            }
        }
        return out
    }
}

func xyz(_ v: SIMD4<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, v.z) }

extension Puppet {
    func bonePositions() -> [SIMD3<Float>] {
        let p = place()
        return eval.pose.world.map { xyz(p * SIMD4(xyz($0.columns.3), 1)) }
    }

    func bone(_ name: String) -> Int? { model.pmx.bones.firstIndex { $0.name == name } }
    func boneWorld(_ i: Int) -> simd_float4x4 { eval.pose.world[i] }

    func step(_ dt: Float, motion: Slot) {
        var i = Intent()
        i.motion = motion
        step(dt, i)
    }
}

@Test func walksWithoutSliding() throws {
    let (ualSkel, ualClips) = try SourceClip.loadGLB([UInt8](Data(contentsOf: Assets.library)))
    var sources: [(String, SourceSkeleton, SourceClip)] = [("UAL", ualSkel, ualClips.first { $0.name == "Walk_Loop" }!)]
    let bvh = Assets.url("assets/bandai/dataset/Bandai-Namco-Research-Motiondataset-1/data/dataset-1_walk_feminine_001.bvh")
    if let text = try? String(contentsOf: bvh, encoding: .utf8) {
        let (s, c) = try BVH.loadWalkCycle(text, name: "walk")
        sources.append(("feminine", s, c))
    }
    for (label, skel, walk) in sources {
        for url in [Assets.model] {
            let model = try LoadedModel.load(url)
            var options = Retarget.Options()
            options.cycleFeet = label == "feminine"
            let baked = Retarget.bake(skel, walk, model.pmx, model.profile.aliases, options)
            let c = Puppet(model)
            c.setBaked(.walk, baked)
            let ankles = ["左足首", "右足首"].map { c.bone($0)! }
            let toes = ["左つま先", "右つま先"].map { c.bone($0) }
            let speed = c.walkSpeed
            #expect(speed > 1, "\(url.lastPathComponent): walk speed \(speed)")
            var intent = Intent()
            intent.motion = .walk
            intent.facing = -.pi / 2
            c.teleport(intent)
            let dt: Float = 1.0 / 60
            var slides: [Float] = []
            var prev: [SIMD3<Float>]?
            for i in 0..<360 {
                intent.root.x += speed * dt
                c.step(dt, intent)
                let p = c.bonePositions()
                let feet = zip(ankles, toes).map { a, t in t.map { p[$0].y < p[a].y ? p[$0] : p[a] } ?? p[a] }
                if let prev, i > 60 {
                    let low = feet[0].y <= feet[1].y ? 0 : 1
                    slides.append(abs(feet[low].x - prev[low].x) / dt)
                }
                prev = feet
            }
            let median = slides.sorted()[slides.count / 2]
            print("\(label) \(url.lastPathComponent): walk speed \(speed), stance foot slide median \(median) (\(Int(median / speed * 100))%)")
            #expect(median < speed * (label == "feminine" ? 0.16 : 0.1), "\(url.lastPathComponent): sliding \(median) vs \(speed)")
        }
    }
}

@Test func interruptedCrossfadesDoNotSnap() throws {
    func make() throws -> Puppet {
        let model = try LoadedModel.load(Assets.model)
        let clips = try Assets.ual(["Idle_Loop", "Walk_Loop"], for: model)
        let c = Puppet(model)
        c.setBaked(.idle, clips["Idle_Loop"]!)
        c.setBaked(.walk, clips["Walk_Loop"]!)
        return c
    }
    func maxStep(_ c: Puppet, _ slots: [Slot]) -> Float {
        var prev = c.bonePositions(), most: Float = 0
        for s in slots {
            c.step(1.0 / 30, motion: s)
            let now = c.bonePositions()
            for (a, b) in zip(now, prev) { most = max(most, simd_distance(a, b)) }
            prev = now
        }
        return most
    }
    let steady = try make()
    _ = maxStep(steady, Array(repeating: .walk, count: 60))
    let walking = maxStep(steady, Array(repeating: .walk, count: 90))
    let c = try make()
    _ = maxStep(c, Array(repeating: .idle, count: 30))
    let flipping = maxStep(c, (0..<150).map { ($0 / 5) % 2 == 0 ? .walk : .idle })
    print("max bone step per frame: walking \(walking), flipping \(flipping)")
    #expect(flipping < walking * 1.5)
}

@Test func pointsAtTarget() throws {
    let c = Puppet(try LoadedModel.load(Assets.model))
    let (shoulder, wrist) = (c.bone("右腕")!, c.bone("右手首")!)
    func pos(_ b: Int) -> SIMD3<Float> { xyz(c.boneWorld(b).columns.3) }
    for _ in 0..<30 { c.step(1.0 / 30, Intent()) }
    let rest = pos(wrist)
    let target = SIMD3<Float>(-30, 30, 0)
    var pointing = Intent()
    pointing.point = target
    for _ in 0..<30 { c.step(1.0 / 30, pointing) }
    let (s, w) = (pos(shoulder), pos(wrist))
    let aim = simd_dot(simd_normalize(w - s), simd_normalize(target - s))
    #expect(aim > 0.9, "the arm points at the target (\(aim))")
    for _ in 0..<30 { c.step(1.0 / 30, Intent()) }
    #expect(simd_distance(pos(wrist), rest) < 0.5, "the arm comes back")
}

@Test func wakingUpAfterALongTimeDoesNotShake() throws {
    let c = Puppet(try LoadedModel.load(Assets.model))
    c.disablePhysics()
    c.procedural.time = 3600
    let head = c.bone("頭")!
    var (prev, prev2): (SIMD3<Float>?, SIMD3<Float>?) = (nil, nil)
    var worst: Float = 0
    for f in 0..<360 {
        var intent = Intent()
        if f < 180 { intent.expressions[Expression.eyesClosed.rawValue] = 1 }
        c.step(1.0 / 60, intent)
        let p = xyz(c.boneWorld(head).columns.3)
        if f > 150, let a = prev, let b = prev2 { worst = max(worst, simd_length(p - 2 * a + b)) }
        (prev2, prev) = (prev, p)
    }
    #expect(worst < 0.002, "the head shakes \(worst) per frame² after waking up")
}

@Test func composedDirectionsMeanWhatTheGuideSays() throws {
    let c = Puppet(try LoadedModel.load(Assets.model))
    func moved(_ name: String, _ deg: Float, _ watch: String) -> SIMD3<Float> {
        let w = c.bone(watch)!
        c.step(1.0 / 30, Intent())
        let rest = xyz(c.boneWorld(w).columns.3)
        let clip = c.buildComposed([Compose.Keyframe(seconds: 0.6, commands: [Compose.Command(name: name, degrees: deg)])])!
        c.setBaked(.composed, clip)
        for _ in 0..<24 { c.step(1.0 / 30, motion: .composed) }
        let d = xyz(c.boneWorld(w).columns.3) - rest
        for _ in 0..<60 { c.step(1.0 / 30, Intent()) }
        return d
    }
    let raise = moved("raise_left_arm", 60, "左手首"), forward = moved("left_arm_forward", 60, "左手首")
    let raiseR = moved("raise_right_arm", 60, "右手首"), forwardR = moved("right_arm_forward", 60, "右手首")
    let elbow = moved("bend_left_elbow", 90, "左手首")
    let nod = moved("nod", 40, "左目"), lean = moved("lean_forward", 40, "左目")
    #expect(raise.y > 2 && raiseR.y > 2, "腕が上がる")
    #expect(forward.z < -2 && forwardR.z < -2, "腕が前へ出る")
    #expect(elbow.z < -1, "ひじを曲げると手が前へ")
    #expect(nod.y < 0 && lean.z < -1, "うなずく・前かがみ")
}

@Test func composedKeyframesAreValidated() throws {
    let c = Puppet(try LoadedModel.load(Assets.model))
    let cmd = Compose.Command.init(name:degrees:)
    let clip = try #require(c.buildComposed([
        Compose.Keyframe(seconds: 0.5, commands: [cmd("right_arm_forward", 60), cmd("bend_right_elbow", 400), cmd("kick", 30), cmd("nod", .nan)]),
        Compose.Keyframe(seconds: 0.4, commands: [cmd("tilt_head_left", 20)]),
    ]))
    #expect(clip.mapped == 3, "右腕・右ひじ・頭")
    #expect(clip.frames.count == 46)
    func angle(_ q: simd_quatf) -> Float { 2 * acos(min(abs(q.vector.w), 1)) }
    #expect(abs(angle(clip.frames[15].rotations[1].1) - .pi) < 1e-3)
    for f in [clip.frames[0], clip.frames.last!] { #expect(f.rotations.allSatisfy { angle($0.1) < 1e-3 }) }
    #expect(c.buildComposed([Compose.Keyframe(seconds: 1, commands: [cmd("fly", 10)])]) == nil)
}

@Test func modelsLoadPlayAndStayStable() throws {
    for url in [Assets.model] {
        let model = try LoadedModel.load(url)
        let c = Puppet(model)
        c.setBaked(.idle, try #require(Assets.ual(["Idle_Loop"], for: model)["Idle_Loop"]))
        let g = c.model.pmx.geometry
        var skinned = [Bool](repeating: false, count: c.boneCount)
        for (b, w) in zip(g.skinIndices, g.skinWeights) where w > 0 { skinned[Int(b)] = true }
        c.step(1.0 / 30, Intent())
        let rest = c.bonePositions()
        let height = zip(rest, skinned).filter(\.1).map(\.0.y).max() ?? 0
        let physical = c.model.pmx.rigidBodies.contains { $0.mode != "static" }
        let want = ProcessInfo.processInfo.environment["MASCOT_PHYSICS_HZ"].flatMap(Float.init) ?? 60
        var moved: Float = 0
        var intent = Intent()
        for i in 0..<1200 {
            intent.look = SIMD3(sin(Float(i) * 0.02) * 30, 28, -40)
            intent.root = SIMD3(min(max((Float(i) - 600) / 120, 0), 1) * 30, 0, 0)
            c.step(i < 600 ? 1.0 / 30 : 1.0 / 60, intent)
            if physical { #expect(abs(1 / c.substep - want) < want * 0.1, "physics rate at frame \(i)") }
            for (k, p) in c.bonePositions().enumerated() where skinned[k] { moved = max(moved, simd_length(p - rest[k] - intent.root)) }
        }
        print("\(url.lastPathComponent): bones \(c.boneCount), height \(height), max bone travel \(moved)")
        #expect(moved.isFinite && moved < height * 0.35, "physics exploded: travel \(moved) vs height \(height)")
    }
}
