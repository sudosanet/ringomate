struct PMXParts {
    var version: Float = 2.0
    /// "utf-8" か "utf-16-le"。
    var encoding = "utf-8"
    var name = "model", englishName = ""
    var comment = "", englishComment = ""
    var materialName = "material", englishMaterialName = ""
    var materials: [PMXModel.Material] = []
    var bones: [Bone] = []
    var morphs: [PMXModel.Morph] = []
    var displayFrames: [PMXModel.DisplayFrame] = []
    var rigidBodies: [PMXModel.RigidBody] = []
    var joints: [PMXModel.Joint] = []
    var indexSizes = PMXModel.IndexSizes(vertex: 4, texture: 1, material: 1, bone: 1, morph: 1, rigidBody: 1)

    var positions: [Float] = [], normals: [Float] = [], uvs: [Float] = []
    var indices: [UInt32] = []
    /// 空なら全部 0 番の骨・重み (1, 0, 0, 0)。
    var skinIndices: [UInt32] = [], skinWeights: [Float] = []
    /// 空なら全部 1。
    var edgeScale: [Float] = []

    init() {}

    public struct Bone: Sendable {
        var name = "", englishName = ""
        var parentIndex: Int32 = -1
        var layer: Int32 = 0
        public var position = SIMD3<Float>(0, 0, 0)
        var tailIndex: Int32 = -1
        var tailPosition: SIMD3<Float>?
        var rotatable = true, translatable = false, visible = true, enabled = true

        init() {}
    }

    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    static func canHold(signed size: UInt8, _ count: Int) -> Bool {
        switch size {
        case 1: count <= 128
        case 2: count <= 32768
        case 4: true
        default: false
        }
    }

    func build() throws -> PMXModel {
        func fail(_ m: String) -> Invalid { Invalid(description: m) }
        guard positions.count % 3 == 0 else { throw fail("positions must be vertex_count * 3") }
        let n = positions.count / 3
        guard n > 0 else { throw fail("PMX parts export requires at least one vertex") }
        guard normals.count == n * 3, uvs.count == n * 2 else { throw fail("normals / uvs length mismatch") }
        guard indices.count % 3 == 0 else { throw fail("indices must be divisible by 3") }
        if let bad = indices.first(where: { Int($0) >= n }) { throw fail("out-of-range vertex index \(bad)") }
        guard skinIndices.isEmpty || skinIndices.count == n * 4, skinWeights.isEmpty || skinWeights.count == n * 4,
              skinIndices.isEmpty == skinWeights.isEmpty else { throw fail("skin length mismatch") }
        guard edgeScale.isEmpty || edgeScale.count == n else { throw fail("edge_scale length mismatch") }
        guard version >= 2.0 else { throw fail("PMX 2.0 or newer") }
        guard encoding == "utf-8" || encoding == "utf-16-le" else { throw fail("encoding \(encoding)") }
        let s = indexSizes
        for v in [s.vertex, s.texture, s.material, s.bone, s.morph, s.rigidBody] where ![1, 2, 4].contains(v) {
            throw fail("index size \(v)")
        }
        let faces = indices.count / 3
        guard faces <= Int(Int32.max) else { throw fail("too many faces") }
        let vertexHold: (Int) -> Bool = { c in s.vertex == 4 || c <= (s.vertex == 1 ? 256 : 65536) }
        guard vertexHold(n), indices.isEmpty || vertexHold(Int(indices.max()!) + 1) else {
            throw fail("vertex index size \(s.vertex) cannot hold \(n)")
        }
        if !materials.isEmpty {
            guard Self.canHold(signed: s.material, materials.count) else { throw fail("material index size") }
            guard materials.allSatisfy({ $0.faceCount >= 0 }) else { throw fail("negative faceCount") }
            guard materials.reduce(0, { $0 + Int($1.faceCount) }) == faces else { throw fail("faceCount sum mismatch") }
        }
        let boneCount = max(bones.count, 1)
        guard Self.canHold(signed: s.bone, boneCount) else { throw fail("bone index size") }
        func ref(_ i: Int32, _ count: Int) -> Bool { i == -1 || (i >= 0 && Int(i) < count) }
        for b in bones where !ref(b.parentIndex, boneCount) || !ref(b.tailIndex, boneCount) {
            throw fail("bad bone reference in \(b.name)")
        }
        guard Self.canHold(signed: s.morph, morphs.count) else { throw fail("morph index size") }
        for m in morphs {
            guard PMXModel.panels.contains(m.panel) else { throw fail("morph panel \(m.panel)") }
            switch m.kind {
            case "vertex":
                if m.vertexOffsets.contains(where: { Int($0.vertexIndex) >= n }) { throw fail("morph vertex out of range") }
            case "group":
                if m.groupOffsets.contains(where: { $0.morphIndex < 0 || Int($0.morphIndex) >= morphs.count }) {
                    throw fail("group morph out of range")
                }
            default: throw fail("morph kind \(m.kind)")
            }
        }
        if let bad = skinIndices.first(where: { Int($0) >= boneCount }) { throw fail("skin bone \(bad) out of range") }
        for f in displayFrames {
            for item in f.frames {
                switch item.kind {
                case "bone": guard item.index >= 0, Int(item.index) < boneCount else { throw fail("display frame bone") }
                case "morph": guard item.index >= 0, Int(item.index) < morphs.count else { throw fail("display frame morph") }
                default: throw fail("display frame kind \(item.kind)")
                }
            }
        }
        guard Self.canHold(signed: s.rigidBody, rigidBodies.count) else { throw fail("rigid body index size") }
        for b in rigidBodies {
            guard ref(b.boneIndex, boneCount), ["sphere", "box", "capsule"].contains(b.shape),
                  ["static", "dynamic", "dynamicBone"].contains(b.mode) else { throw fail("bad rigid body \(b.name)") }
        }
        for j in joints {
            guard ref(j.rigidBodyIndexA, rigidBodies.count), ref(j.rigidBodyIndexB, rigidBodies.count),
                  PMXModel.jointKinds.contains(j.kind) else { throw fail("bad joint \(j.name)") }
        }

        var m = PMXModel()
        m.metadata.version = version
        m.metadata.encoding = encoding
        m.metadata.name = name
        m.metadata.englishName = englishName
        m.metadata.comment = comment
        m.metadata.englishComment = englishComment
        m.metadata.indexSizes = s
        m.geometry.positions = positions
        m.geometry.normals = normals
        m.geometry.uvs = uvs
        m.geometry.indices = indices
        m.geometry.skinIndices = skinIndices.isEmpty ? Array(repeating: 0, count: n * 4) : skinIndices
        m.geometry.skinWeights = skinWeights.isEmpty
            ? (0..<n * 4).map { $0 % 4 == 0 ? 1 : 0 } : skinWeights
        m.geometry.edgeScale = edgeScale.isEmpty ? Array(repeating: 1, count: n) : edgeScale
        m.geometry.sdef.skinningModes = Array(repeating: "bdef4", count: n)
        if faces > 0 {
            if materials.isEmpty {
                var d = PMXModel.Material()
                d.name = materialName.isEmpty ? "material" : materialName
                d.englishName = englishMaterialName
                d.sharedToonIndex = 0
                d.diffuse = SIMD4(0.8, 0.8, 0.8, 1)
                d.specularPower = 1
                d.ambient = SIMD3(0.2, 0.2, 0.2)
                d.flags.doubleSided = true
                d.flags.groundShadow = true
                d.flags.selfShadowMap = true
                d.flags.selfShadow = true
                d.faceCount = Int32(faces)
                m.materials = [d]
            } else {
                m.materials = materials.map { var x = $0; if x.sphereMode.isEmpty { x.sphereMode = "none" }; return x }
            }
            var start = 0
            m.geometry.materialGroups = m.materials.enumerated().map { i, mat in
                defer { start += Int(mat.faceCount) * 3 }
                return PMXModel.MaterialGroup(start: start, count: Int(mat.faceCount) * 3, materialIndex: i)
            }
        }
        m.bones = bones.isEmpty ? [Self.rootBone] : bones.map { b in
            var p = PMXModel.Bone()
            p.name = b.name
            p.englishName = b.englishName
            p.parentIndex = b.parentIndex
            p.layer = b.layer
            p.position = b.position
            p.tailIndex = b.tailIndex
            p.tailPosition = b.tailIndex >= 0 ? nil : (b.tailPosition ?? SIMD3(0, 1, 0))
            p.flags.indexedTail = b.tailIndex >= 0
            p.flags.rotatable = b.rotatable
            p.flags.translatable = b.translatable
            p.flags.visible = b.visible
            p.flags.enabled = b.enabled
            return p
        }
        m.morphs = morphs.map { mo in
            var x = PMXModel.Morph()
            x.name = mo.name
            x.englishName = mo.englishName
            x.panel = mo.panel
            x.kind = mo.kind
            if mo.kind == "vertex" { x.vertexOffsets = mo.vertexOffsets } else { x.groupOffsets = mo.groupOffsets }
            return x
        }
        m.displayFrames = displayFrames
        m.rigidBodies = rigidBodies
        m.joints = joints
        m.metadata.counts = PMXModel.Counts(
            vertices: n, faces: faces, materials: m.materials.count, bones: m.bones.count, morphs: m.morphs.count,
            displayFrames: displayFrames.count, rigidBodies: rigidBodies.count, joints: joints.count, softBodies: 0)
        return m
    }

    static var rootBone: PMXModel.Bone {
        var b = PMXModel.Bone()
        b.name = "root"
        b.englishName = "root"
        b.tailPosition = SIMD3(0, 1, 0)
        b.flags.rotatable = true
        b.flags.translatable = true
        b.flags.visible = true
        b.flags.enabled = true
        return b
    }
}
