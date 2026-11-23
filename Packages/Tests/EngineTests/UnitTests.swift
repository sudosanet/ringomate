@testable import Engine
import Foundation
import simd
import Testing

@Test func resolverHandlesCaseSeparatorExtensionAndParent() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "ringomate-resolver-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    for f in ["model/Tex/Face.PNG", "model/hair.dds", "toon/toon01.bmp", "model/m.pmx"] {
        let u = dir.appending(path: f)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: u)
    }
    let r = TextureResolver(try Archive.open(dir) { _ in [] }, pmxPath: "model/m.pmx")
    #expect(r.resolve("tex\\face.png") == "model/Tex/Face.PNG")
    #expect(r.resolve("hair.png") == "model/hair.dds")
    #expect(r.resolve("../toon/toon01.bmp") == "toon/toon01.bmp")
    #expect(r.resolve("missing.png") == nil)
}

@Test func gesturesAreTrimmed() throws {
    let root = Assets.url("assets/bandai/dataset")
    for (f, trim): (String, BVH.Trim) in [
        ("Bandai-Namco-Research-Motiondataset-1/data/dataset-1_byebye_happy_001.bvh", .handsUp),
        ("Bandai-Namco-Research-Motiondataset-1/data/dataset-1_bow_happy_001.bvh", .bow),
        ("Bandai-Namco-Research-Motiondataset-1/data/dataset-1_call_normal_001.bvh", .handsUp),
        ("Bandai-Namco-Research-Motiondataset-1/data/dataset-1_respond_normal_001.bvh", .handsUp),
        ("Bandai-Namco-Research-Motiondataset-2/data/dataset-2_wave-both-hands_youthful_001.bvh", .handsUp),
        ("Bandai-Namco-Research-Motiondataset-2/data/dataset-2_raise-up-both-hands_youthful_001.bvh", .handsUp),
        ("Bandai-Namco-Research-Motiondataset-1/data/dataset-1_dance-short_normal_001.bvh", .active),
    ] {
        guard let text = try? String(contentsOf: root.appending(path: f), encoding: .utf8) else { continue }
        let (_, clip) = try BVH.loadGesture(text, name: "g", trim: trim, maxSeconds: 6)
        #expect((0.5...6).contains(clip.duration), "\(f): \(clip.duration)")
    }
}

@Test func gunzipsOnlyGzip() throws {
    let text = Array("HIERARCHY\n".utf8)
    #expect(try BVH.gunzipIfNeeded(text) == text)
    let dir = FileManager.default.temporaryDirectory.appending(path: "ringomate-gz-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let f = dir.appending(path: "a.txt")
    try Data(text).write(to: f)
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/gzip")
    p.arguments = [f.path]
    try p.run()
    p.waitUntilExit()
    #expect(try BVH.gunzipIfNeeded([UInt8](Data(contentsOf: dir.appending(path: "a.txt.gz")))) == text)
}

@Test func plainGLBIsLeftAloneAndRoundTrips() throws {
    let json: [String: Any] = ["asset": ["version": "2.0"], "buffers": [["byteLength": 4]]]
    let glb = try GLTFExpand.join(json, [1, 2, 3, 4])
    #expect(try GLTFExpand.expand(glb) == nil)
    let (j, b) = try GLTFExpand.split(glb)
    #expect(NSDictionary(dictionary: j).isEqual(to: json))
    #expect(b == [1, 2, 3, 4])
    #expect(GLTFExpand.base64("AQID") == [1, 2, 3])
    #expect(GLTFExpand.percentDecode("a%20b.png") == "a b.png")
}

@Test func guessesCommonRigs() {
    func has(_ g: [(String, Int)], _ bone: String, _ n: Int) -> Bool { g.contains { $0 == (bone, n) } }
    var g = GLTFHumanoid.guess(["pelvis", "thigh_l", "calf_r", "index_02_l", "spine_03"])
    #expect(has(g, "hips", 0) && has(g, "leftUpperLeg", 1) && has(g, "rightLowerLeg", 2) && has(g, "leftIndexIntermediate", 3) && has(g, "chest", 4))
    g = GLTFHumanoid.guess(["mixamorig:Hips", "mixamorig:LeftUpLeg", "mixamorig:LeftForeArm"])
    #expect(has(g, "leftUpperLeg", 1) && has(g, "leftLowerArm", 2))
    g = GLTFHumanoid.guess(["thigh.L", "shin.R", "forearm.L"])
    #expect(has(g, "leftUpperLeg", 0) && has(g, "rightLowerLeg", 1) && has(g, "leftLowerArm", 2))
    g = GLTFHumanoid.guess(["J_Bip_C_Hips", "J_Bip_L_UpperLeg", "J_Bip_R_LowerArm", "J_Bip_L_Little2", "Bip001 Pelvis", "Bip01 L Thigh",
                            "Bip001 R Finger02", "CC_Base_L_Forearm", "CC_Base_R_Mid3"])
    for (bone, n) in [("leftUpperLeg", 1), ("rightLowerArm", 2), ("leftLittleIntermediate", 3), ("rightThumbDistal", 6),
                      ("leftLowerArm", 7), ("rightMiddleDistal", 8)] {
        #expect(has(g, bone, n), "\(bone) in \(g)")
    }
}

@Test func infersMannequinAndVRMFromHierarchy() throws {
    for file in ["assets/ual/UAL1_Standard.glb", "assets/tsukuyomi/Tsukuyomi.vrm"] {
        guard let bytes = try? [UInt8](Data(contentsOf: Assets.url(file))) else { continue }
        let json = try GLB(bytes).json
        let nodes = json["nodes"].array ?? []
        let children = nodes.map { ($0["children"].array ?? []).compactMap(\.uint) }
        var parent = [Int?](repeating: nil, count: nodes.count)
        for (i, cs) in children.enumerated() { for c in cs { parent[c] = i } }
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nodes.count)
        func visit(_ n: Int, _ m: simd_float4x4) {
            world[n] = m * VRM.local(nodes[n])
            for c in children[n] { visit(c, world[n]) }
        }
        for i in nodes.indices where parent[i] == nil { visit(i, matrix_identity_float4x4) }
        let joints = (json["skins"].array ?? []).flatMap { ($0["joints"].array ?? []).compactMap(\.uint) }
        let byName = GLTFHumanoid.guess(nodes.map { $0["name"].string })
        let inferred = GLTFHumanoid.infer(parent: parent, pos: world.map { xyz($0.columns.3) }, joints: joints)
        for bone in ["hips", "leftUpperLeg", "rightUpperLeg", "leftLowerLeg", "leftFoot", "leftUpperArm", "rightLowerArm", "leftHand", "neck", "head"] {
            let a = byName.first { $0.0 == bone }.map { nodes[$0.1]["name"].string }
            let b = inferred.first { $0.0 == bone }.map { nodes[$0.1]["name"].string }
            #expect(a != nil && a == b, "\(file) \(bone)")
        }
    }
}

@Test func profileAliasesAndFaceMatching() throws {
    let g = try #require(Profile.builtin.first { $0.name == "default" })
    #expect(g.aliases.bone("頭") == ["頭", "头"])
    #expect(g.aliases.morph("まばたき") == ["まばたき", "眨眼", "闭眼"])
    #expect(g.aliases.bone("腰") == ["腰"])
    let n = try #require(Profile.builtin.first { $0.name == "nte" })
    #expect(n.isFace("面") && n.isFace("頭脸"))
    #expect(!n.isFace("眼白") && !n.isFace("前髪"))
}

@Test func phoneFacesPointOutward() {
    let m = PropMesh.phone()
    #expect(m.indices.count == 7 * 6)
    for k in stride(from: 0, to: m.indices.count, by: 3) {
        let (a, b, c) = (m.positions[Int(m.indices[k])], m.positions[Int(m.indices[k + 1])], m.positions[Int(m.indices[k + 2])])
        #expect(simd_dot(simd_cross(b - a, c - a), (a + b + c) / 3) > 0)
    }
}

@Test func weldsSplitNormalsAtSamePosition() {
    let s = Optimize.smoothNormals(positions: [0, 0, 0, 0, 0, 0, 1, 0, 0], normals: [1, 0, 0, 0, 1, 0, 0, 0, 1])
    let h = Float(0.5).squareRoot()
    #expect(abs(s[0] - h) < 1e-5 && abs(s[1] - h) < 1e-5)
    #expect(Array(s[0..<3]) == Array(s[3..<6]))
    #expect(Array(s[6..<9]) == [0, 0, 1])
}

@Test func vertexCacheKeepsTheSameTriangles() {
    var pmx = PMXModel()
    pmx.geometry.positions = [Float](repeating: 0, count: 8 * 3)
    pmx.geometry.indices = [0, 1, 2, 2, 1, 3, 4, 5, 6, 6, 5, 7]
    pmx.materials = [PMXModel.Material()]
    pmx.materials[0].faceCount = 4
    let before = pmx.geometry.indices
    Optimize.optimizeVertexCache(&pmx)
    func tris(_ v: [UInt32]) -> [[UInt32]] {
        stride(from: 0, to: v.count, by: 3).map { k in
            var a = [v[k], v[k + 1], v[k + 2]]
            while a[0] != a.min()! { a = Array(a[1...]) + [a[0]] }
            return a
        }.sorted { $0.lexicographicallyPrecedes($1) }
    }
    #expect(tris(before) == tris(pmx.geometry.indices))
}

@Test func excludesOnlyOverlappingLinkedDynamicPairs() {
    func body(_ group: UInt8, _ x: Float, _ mode: String) -> PMXModel.RigidBody {
        var r = PMXModel.RigidBody()
        (r.boneIndex, r.group, r.size, r.position, r.mode) = (0, group, SIMD3(1, 0, 0), SIMD3(x, 0, 0), mode)
        return r
    }
    func joint(_ a: Int32, _ b: Int32) -> PMXModel.Joint {
        var j = PMXModel.Joint()
        (j.rigidBodyIndexA, j.rigidBodyIndexB) = (a, b)
        return j
    }
    var pmx = PMXModel()
    pmx.rigidBodies = [body(1, 0, "dynamic"), body(2, 0.5, "dynamic"), body(3, 5, "dynamic"), body(4, 5.2, "static")]
    pmx.joints = [joint(0, 1), joint(1, 2), joint(2, 3)]
    #expect(Optimize.excludeRestOverlaps(&pmx) == 1)
    #expect(pmx.rigidBodies[0].mask & (1 << 2) == 0)
    #expect(pmx.rigidBodies[1].mask & (1 << 1) == 0)
    #expect(pmx.rigidBodies[1].mask & (1 << 3) == 1 << 3)
    #expect(pmx.rigidBodies[3].mask == 0xffff)
}

@Test func bakeCacheRoundTripsAndRejectsBrokenBytes() throws {
    let frame = BakedClip.Frame(rotations: [(3, simd_quatf(angle: 0.5, axis: SIMD3(0, 1, 0)))], center: (1, SIMD3(0, 1, 2)), feet: [(7, SIMD3(1, 0, 0))])
    let clip = BakedClip(name: "歩き", frames: [frame], fps: 30, groundSpeed: 4.5, mapped: 12)
    let empty = BakedClip(name: "", frames: [], fps: 30, groundSpeed: 0, mapped: 0)
    let bytes = BakeCache.encode([(.walk, clip), (.gesture(3), clip), (.land, empty)])
    let back = try #require(BakeCache.decode(bytes))
    #expect(back.count == 3 && back[1].0 == .gesture(3) && back[2].0 == .land && back[0].1.name == "歩き")
    #expect(back[0].1.frames[0].rotations[0].1 == frame.rotations[0].1)
    #expect(back[0].1.frames[0].center?.0 == 1 && back[0].1.frames[0].center?.1 == SIMD3(0, 1, 2))
    #expect(BakeCache.decode(Array(bytes.dropLast())) == nil)
    #expect(BakeCache.decode(Array("AMBAKE01".utf8) + [0xff, 0xff, 0xff, 0xff]) == nil)
}

@Test func bustBoneNames() {
    for (n, side) in [("左胸上2", true), ("右胸", false), ("J_Sec_L_Bust1", true), ("Breast_R", false)] {
        #expect(Bust.isBreast(n), "\(n)")
        #expect(Bust.side(n) == side, "\(n)")
    }
    for n in ["上半身2", "胸亲", "Chest", "UpperChest", "Bone_BreastDecor01_L錘"] { #expect(!Bust.isBreast(n), "\(n)") }
}

@Test func feetAreHomeBetweenMoves() {
    for legs in Dance.legs {
        let n = Float(Dance.beats(legs))
        for i in 0...45 {
            let t = (n - 0.4 + Float(i) * 0.01).truncatingRemainder(dividingBy: n)
            let pose = Dance.legPose(legs, t)
            for k in 0..<2 {
                let f = pose.feet[k]
                #expect(simd_length(SIMD2(f.x, f.z)) < 1e-3 && f.y < 0.025, "\(legs) foot \(k) not home at \(t): \(f)")
            }
        }
    }
}

@Test func danceMovesAreContinuous() {
    let steps = 480
    for legs in Dance.legs {
        var last = Dance.legPose(legs, 0)
        var issues = 0
        for i in 1...steps {
            let now = Dance.legPose(legs, Float(i) / Float(steps) * Float(Dance.beats(legs)))
            var ok = simd_length(now.center - last.center) < 0.02 && abs(now.twist - last.twist) < 0.05
            for k in 0..<2 { ok = ok && abs(now.pitch[k] - last.pitch[k]) < 0.06 && simd_length(now.feet[k] - last.feet[k]) < 0.02 }
            if legs != "Hop" && legs != "Tiptoe" {
                for k in 0..<2 where now.feet[k].y <= 1e-5 && last.feet[k].y <= 1e-5 {
                    ok = ok && simd_length(SIMD2(now.feet[k].x - last.feet[k].x, now.feet[k].z - last.feet[k].z)) < 1e-5
                }
                ok = ok && !(now.feet[0].y > 1e-5 && now.feet[1].y > 1e-5)
            }
            if !ok { issues += 1 }
            last = now
        }
        #expect(issues == 0, "\(legs): \(issues) jumps, slides or both feet up")
    }
    for arms in Dance.arms {
        for x: Float in [1, -1] {
            var last = Dance.armPose(arms, x, 0).0
            for i in 1...steps {
                let now = Dance.armPose(arms, x, Float(i) / Float(steps) * 4).0
                let d = simd_length(SIMD3(now.0 - last.0, now.1 - last.1, now.2 - last.2))
                #expect(d < 0.02, "\(arms) \(x) jumps at \(i): \(d)")
                last = now
            }
        }
    }
}

@Test func flagsSetAndClear() {
    Flags.set(["MASCOT_TEST_ONLY": "a"])
    #expect(Flags.value("MASCOT_TEST_ONLY") == "a")
    Flags.set(["MASCOT_TEST_ONLY": ""])
    #expect(Flags.value("MASCOT_TEST_ONLY") == nil)
}
