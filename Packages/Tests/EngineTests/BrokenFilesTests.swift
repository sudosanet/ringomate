@testable import Engine
import Foundation
import simd
import Testing

private func variants(_ bytes: [UInt8]) -> [[UInt8]] {
    var out = ([0, 1, 4, 16, 64, 300, 1000] + [bytes.count / 7, bytes.count / 3, bytes.count / 2, bytes.count - 1])
        .filter { $0 < bytes.count }.map { Array(bytes[..<$0]) }
    for (seed, step) in [(7, 997), (13, 4093), (101, 65_521)] {
        var b = bytes
        for i in stride(from: seed, to: b.count, by: step) { b[i] ^= 0xa5 }
        out.append(b)
    }
    return out
}

private func read(_ path: String) -> [UInt8]? { try? [UInt8](Data(contentsOf: Assets.url(path))) }
private func text(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self) }

@Test func brokenPMXDoesNotCrash() throws {
    for b in variants(try Assets.pmxBytes()) {
        if let pmx = try? PMXModel(pmx: b) { _ = RuntimeModel(pmx) }
    }
}

@Test func brokenVRMAndGLBDoNotCrash() {
    for p in ["assets/tsukuyomi/Tsukuyomi.vrm", "assets/ual/UAL1_Standard.glb"] {
        guard let bytes = read(p) else { continue }
        for b in variants(bytes) {
            _ = try? VRM.convert(b)
            _ = try? SourceClip.loadGLB(b)
        }
    }
}

@Test func brokenBVHAndPMDDoNotCrash() throws {
    if let bytes = read("assets/bandai/dataset/Bandai-Namco-Research-Motiondataset-1/data/dataset-1_walk_happy_001.bvh") {
        for b in variants(bytes) {
            _ = try? BVH.loadClip(text(b), name: "x")
            _ = try? BVH.loadWalkCycle(text(b), name: "x")
        }
    }
    for b in variants(try Assets.pmxBytes()) { #expect((try? PMD.convert(b)) == nil || b.count > 3) }
}

@Test func fuzzFindingsStayFixed() throws {
    let dir = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Corpus")
    let bvh = text(try [UInt8](Data(contentsOf: dir.appending(path: "fuzz-bvh-nan.bvh"))))
    _ = try? BVH.loadClip(bvh, name: "x")
    _ = try? BVH.loadWalkCycle(bvh, name: "x")
    let glb = try [UInt8](Data(contentsOf: dir.appending(path: "fuzz-glb-short-header.glb")))
    #expect((try? VRM.convert(glb)) == nil)
    #expect((try? SourceClip.loadGLB(glb)) == nil)
}

private func edited(_ change: (inout PMXModel) -> Void) throws -> [UInt8] {
    var pmx = try PMXModel(pmx: Assets.pmxBytes())
    pmx.metadata.indexSizes.vertex = 4
    pmx.metadata.indexSizes.bone = 4
    change(&pmx)
    return pmx.pmxBytes()
}

private func glb(_ json: String, bin: [UInt8] = []) -> [UInt8] {
    var j = Array(json.utf8)
    while j.count % 4 != 0 { j.append(32) }
    var b = bin
    while b.count % 4 != 0 { b.append(0) }
    func le(_ v: Int) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
    var out = Array("glTF".utf8) + le(2) + le(12 + 8 + j.count + (b.isEmpty ? 0 : 8 + b.count))
    out += le(j.count) + le(0x4E4F_534A) + j
    if !b.isEmpty { out += le(b.count) + le(0x004E_4942) + b }
    return out
}

@Test func craftedPMXIsRejectedOrRepaired() throws {
    #expect(throws: (any Error).self) { try PMXModel(pmx: edited { $0.geometry.indices[0] = 0x7fff_ffff }) }
    #expect(throws: (any Error).self) { try PMXModel(pmx: edited { $0.materials[0].faceCount = 1 << 28 }) }

    let bad = try PMXModel(pmx: edited {
        $0.bones[1].parentIndex = 2
        $0.bones[2].parentIndex = 1
        $0.bones[3].parentIndex = 99_999
        $0.geometry.skinIndices[0] = 99_999
        $0.rigidBodies[0].boneIndex = 99_999
    })
    #expect(bad.bones[3].parentIndex == -1 && bad.geometry.skinIndices[0] == 0 && bad.rigidBodies[0].boneIndex == -1)
    #expect(bad.bones[1].parentIndex == -1 || bad.bones[2].parentIndex == -1)

    let dir = FileManager.default.temporaryDirectory.appending(path: "ringomate-crafted-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "cycle.pmx")
    try Data(edited { $0.bones[1].parentIndex = 2; $0.bones[2].parentIndex = 1 }).write(to: url)
    _ = try Scene().load(model: url, library: nil)
}

@Test func craftedGLTFDoesNotCrashOrHang() throws {
    // 人型として通したうえで、子の輪・親が二つ・届かない輪・範囲外のノードを混ぜる
    let cycle = #"""
    {"asset":{"version":"2.0"},"extensionsUsed":["VRMC_vrm","VRMC_springBone"],
     "nodes":[{"name":"hips","children":[1,2]},{"name":"l","translation":[0.1,-0.5,0],"children":[3]},{"name":"r","translation":[-0.1,-0.5,0]},
              {"name":"x","children":[1]},{"name":"y","children":[5]},{"name":"z","children":[4]}],
     "extensions":{"VRMC_vrm":{"humanoid":{"humanBones":{"hips":{"node":0},"leftUpperLeg":{"node":1},"rightUpperLeg":{"node":2},"spine":{"node":99999}}}},
       "VRMC_springBone":{"colliders":[{"node":99999,"shape":{"sphere":{"radius":0.1}}}],"colliderGroups":[{"colliders":[0]}],
         "springs":[{"joints":[{"node":1},{"node":3},{"node":99999}],"colliderGroups":[0]}]}}}
    """#
    // メッシュが無いので最後の書き出しで止まる（骨・スプリングの組み立ては通り切る）
    do { _ = try VRM.convert(glb(cycle)) } catch { #expect("\(error)".contains("vertex")) }
    let short = #"{"asset":{"version":"2.0"},"nodes":[{"translation":[],"rotation":[1],"scale":[]}]}"#
    _ = try? VRM.convert(glb(short))
    let huge = #"{"asset":{"version":"2.0"},"accessors":[{"count":4000000000,"componentType":5126,"type":"VEC3"},{"count":2,"componentType":5126,"type":"FOO","bufferView":0},{"count":2,"componentType":5126,"type":"VEC3","bufferView":1}],"bufferViews":[{"buffer":0,"byteLength":24},{"buffer":0,"byteLength":24,"byteStride":-4}],"buffers":[{"byteLength":24}]}"#
    let g = try? GLB(glb(huge, bin: Array(repeating: 0, count: 24)))
    #expect(g != nil)
    #expect(g?.accessor(0) == nil)
    #expect(g?.accessor(1) == nil)
    #expect(g?.accessor(2) == nil)
}

@Test func craftedMotionAndArchiveHeadersAreRejected() throws {
    let bvh = "HIERARCHY\nROOT Hips\n{\nOFFSET 0 0 0\nCHANNELS 6 Xposition Yposition Zposition Zrotation Xrotation Yrotation\n}\nMOTION\nFrames: 1\nFrame Time: 0\n0 0 0 0 0 0\n"
    #expect(throws: (any Error).self) { try BVH.parse(bvh) }
    let gzip: [UInt8] = [0x1f, 0x8b, 8, 8] + Array(repeating: 0x41, count: 20)
    #expect(throws: (any Error).self) { try BVH.gunzipIfNeeded(gzip) }
}

@Test func bakeCacheWithForeignBonesIsIgnored() throws {
    let frame = BakedClip.Frame(rotations: [(99_999, simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))], center: nil, feet: [])
    let clip = BakedClip(name: "x", frames: [frame], fps: 30, groundSpeed: 0, mapped: 1)
    let url = FileManager.default.temporaryDirectory.appending(path: "ringomate-bake-\(UUID())")
    defer { try? FileManager.default.removeItem(at: url) }
    try Data(BakeCache.encode([(.idle, clip)])).write(to: url)
    #expect(BakeCacheFile.read(url, boneCount: 10) == nil)
    #expect(BakeCacheFile.read(url, boneCount: 100_000) != nil)
}
