/// ponytail: 回転連動（ボーンの種類 5・9）と、英語名・表示枠は写さない。
enum PMD {
    struct Vertex {
        var position: SIMD3<Float>, normal: SIMD3<Float>, uv: SIMD2<Float>
        var bones: (Int32, Int32), weight: UInt8, edge: Bool
    }

    struct Material {
        var diffuse: SIMD4<Float>, specularPower: Float, specular: SIMD3<Float>, ambient: SIMD3<Float>
        var toonIndex: UInt8, edge: Bool, faceCount: UInt32, textureName: String
    }

    public struct Bone {
        var name: String, englishName = ""
        var parent: Int32, tail: Int32, type: UInt8, position: SIMD3<Float>
    }

    struct IK {
        var bone: UInt16, target: UInt16, loops: UInt16, limit: Float, links: [UInt16]
    }

    public struct Morph {
        var name: String, englishName = "", base: Bool, offsets: [(UInt32, SIMD3<Float>)]
    }

    struct Body {
        var name: String, bone: Int32, group: UInt8, mask: UInt16, shape: String
        var size: SIMD3<Float>, position: SIMD3<Float>, rotation: SIMD3<Float>
        var mass: Float, linearDamping: Float, angularDamping: Float, restitution: Float, friction: Float, mode: String
    }

    public struct Joint {
        var name: String, a: UInt32, b: UInt32
        var values: [SIMD3<Float>]
    }

    struct Model {
        var name = "", englishName = "", comment = "", englishComment = ""
        var vertices: [Vertex] = [], indices: [UInt16] = [], materials: [Material] = []
        var bones: [Bone] = [], ik: [IK] = [], morphs: [Morph] = [], bodies: [Body] = [], joints: [Joint] = []
    }

    static func index(_ v: UInt16) -> Int32 { v == 0xffff ? -1 : Int32(v) }

    static func text(_ r: inout ByteReader, _ n: Int) throws -> String {
        let b = Array(try r.bytes(n))
        let end = b.firstIndex(of: 0) ?? b.count
        return decode(Array(b[..<end]), .shiftJIS).text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ data: [UInt8]) throws -> Model {
        var r = ByteReader(data)
        guard Array(try r.bytes(3)) == Array("Pmd".utf8) else { throw FormatError.invalid("missing PMD signature") }
        var m = Model()
        _ = try r.f32()
        m.name = try text(&r, 20)
        m.comment = try text(&r, 256)
        let vc = Int(try r.u32())
        try r.requireRecords(vc, 38)
        m.vertices = try (0..<vc).map { _ in
            Vertex(position: try r.vec3(), normal: try r.vec3(), uv: try r.vec2(),
                   bones: (index(try r.u16()), index(try r.u16())), weight: try r.u8(), edge: try r.u8() == 0)
        }
        let ic = Int(try r.u32())
        try r.requireRecords(ic, 2)
        m.indices = try (0..<ic).map { _ in try r.u16() }
        let mc = Int(try r.u32())
        try r.requireRecords(mc, 70)
        m.materials = try (0..<mc).map { _ in
            Material(diffuse: try r.vec4(), specularPower: try r.f32(), specular: try r.vec3(), ambient: try r.vec3(),
                     toonIndex: try r.u8(), edge: try r.u8() != 0, faceCount: try r.u32() / 3, textureName: try text(&r, 20))
        }
        let bc = Int(try r.u16())
        m.bones = try (0..<bc).map { _ in
            let name = try text(&r, 20)
            let parent = index(try r.u16()), tail = index(try r.u16()), type = try r.u8()
            _ = try r.u16()
            return Bone(name: name, parent: parent, tail: tail, type: type, position: try r.vec3())
        }
        m.ik = try (0..<Int(try r.u16())).map { _ in
            let bone = try r.u16(), target = try r.u16()
            let links = Int(try r.u8())
            let loops = try r.u16(), limit = try r.f32()
            return IK(bone: bone, target: target, loops: loops, limit: limit, links: try (0..<links).map { _ in try r.u16() })
        }
        m.morphs = try (0..<Int(try r.u16())).map { _ in
            let name = try text(&r, 20)
            let n = Int(try r.u32())
            let base = try r.u8() == 0
            try r.requireRecords(n, 16)
            return Morph(name: name, base: base, offsets: try (0..<n).map { _ in (try r.u32(), try r.vec3()) })
        }
        var boneFrames = 0
        if r.remaining >= 1 { try r.skip(Int(try r.u8()) * 2) }
        if r.remaining >= 1 {
            boneFrames = Int(try r.u8())
            try r.skip(boneFrames * 50)
            if r.remaining >= 4 { try r.skip(Int(try r.u32()) * 3) }
        }
        if r.remaining >= 1, try r.u8() != 0 {
            m.englishName = try text(&r, 20)
            m.englishComment = try text(&r, 256)
            for i in m.bones.indices { m.bones[i].englishName = try text(&r, 20) }
            for i in m.morphs.indices.dropFirst() { m.morphs[i].englishName = try text(&r, 20) }
            try r.skip(boneFrames * 50)
        }
        if r.remaining >= 1000, !physicsTail(r) { try r.skip(1000) }
        if r.remaining >= 4 {
            m.bodies = try (0..<Int(try r.u32())).map { _ in
                let name = try text(&r, 20)
                let bone = index(try r.u16()), group = try r.u8(), mask = try r.u16()
                let shape = Int(try r.u8())
                let size = try r.vec3(), pos = try r.vec3(), rot = try r.vec3()
                let mass = try r.f32(), ld = try r.f32(), ad = try r.f32(), rest = try r.f32(), fr = try r.f32()
                let mode = Int(try r.u8())
                return Body(name: name, bone: bone, group: group, mask: mask,
                            shape: shape < 3 ? ["sphere", "box", "capsule"][shape] : "unknown",
                            size: size, position: pos, rotation: rot, mass: mass, linearDamping: ld, angularDamping: ad,
                            restitution: rest, friction: fr,
                            mode: mode < 3 ? ["static", "dynamic", "dynamicBone"][mode] : "unknown")
            }
        }
        if r.remaining >= 4 {
            m.joints = try (0..<Int(try r.u32())).map { _ in
                Joint(name: try text(&r, 20), a: try r.u32(), b: try r.u32(), values: try (0..<8).map { _ in try r.vec3() })
            }
        }
        return m
    }

    static func physicsTail(_ r: ByteReader) -> Bool {
        let s = r.pos
        guard s + 4 <= r.data.count else { return false }
        let (bytes, o1) = Int(le32(r.data, s)).multipliedReportingOverflow(by: 83)
        guard !o1 else { return false }
        let jointAt = s + 4 + bytes
        if jointAt == r.data.count { return true }
        guard jointAt >= 0, jointAt + 4 <= r.data.count else { return false }
        let (jb, o2) = Int(le32(r.data, jointAt)).multipliedReportingOverflow(by: 124)
        return !o2 && jointAt + 4 + jb == r.data.count
    }

    static func convert(_ bytes: [UInt8]) throws -> PMXModel {
        let pmd = try parse(bytes)
        var parts = PMXParts()
        for v in pmd.vertices {
            parts.positions += [v.position.x, v.position.y, v.position.z]
            parts.normals += [v.normal.x, v.normal.y, v.normal.z]
            parts.uvs += [v.uv.x, v.uv.y]
            let w = Float(min(v.weight, 100)) / 100
            parts.skinIndices += [UInt32(max(v.bones.0, 0)), UInt32(max(v.bones.1, 0)), 0, 0]
            parts.skinWeights += [w, 1 - w, 0, 0]
            parts.edgeScale.append(v.edge ? 1 : 0)
        }
        parts.indices = pmd.indices.map(UInt32.init)
        parts.materials = pmd.materials.enumerated().map { i, m in
            var tex = "", sphere = ""
            for part in m.textureName.split(separator: "*") where !part.isEmpty {
                let lower = part.lowercased()
                if lower.hasSuffix(".sph") || lower.hasSuffix(".spa") { sphere = String(part) } else { tex = String(part) }
            }
            var x = PMXModel.Material()
            x.name = "材質\(i + 1)"
            x.texturePath = tex
            x.sphereTexturePath = sphere
            let ls = sphere.lowercased()
            x.sphereMode = ls.hasSuffix(".spa") ? "add" : ls.hasSuffix(".sph") ? "multiply" : "none"
            x.sharedToonIndex = m.toonIndex < 10 ? m.toonIndex : nil
            x.diffuse = m.diffuse
            x.specular = m.specular
            x.specularPower = m.specularPower
            x.ambient = m.ambient
            x.edgeColor = SIMD4(0, 0, 0, 1)
            x.edgeSize = 1
            x.flags.doubleSided = m.diffuse.w < 1
            x.flags.groundShadow = true
            x.flags.selfShadowMap = true
            x.flags.selfShadow = true
            x.flags.edge = m.edge
            x.faceCount = Int32(truncatingIfNeeded: m.faceCount)
            return x
        }
        parts.bones = pmd.bones.map { b in
            var x = PMXParts.Bone()
            x.name = b.name
            x.englishName = b.englishName
            x.parentIndex = b.parent
            x.position = b.position
            x.tailIndex = b.tail > 0 ? b.tail : -1
            // 種類 1: 回転と移動、2: IK（移動する）、7: 非表示
            x.translatable = b.type == 1 || b.type == 2
            x.visible = b.type != 7
            return x
        }
        let base = pmd.morphs.first { $0.base }
        parts.morphs = pmd.morphs.filter { !$0.base }.map { m in
            var x = PMXModel.Morph()
            x.name = m.name
            x.englishName = m.englishName
            x.vertexOffsets = m.offsets.compactMap { o in
                guard let base, Int(o.0) < base.offsets.count else { return nil }
                return PMXModel.VertexOffset(vertexIndex: base.offsets[Int(o.0)].0, position: o.1)
            }
            return x
        }
        parts.name = pmd.name
        parts.englishName = pmd.englishName
        parts.comment = pmd.comment
        parts.englishComment = pmd.englishComment
        parts.materialName = ""
        parts.indexSizes = PMXModel.IndexSizes(vertex: 4, texture: 4, material: 4, bone: 4, morph: 4, rigidBody: 4)
        var pmx = try parts.build()

        let names = pmd.bones.map(\.name)
        for ik in pmd.ik where Int(ik.bone) < pmx.bones.count {
            let i = Int(ik.bone)
            pmx.bones[i].flags.ik = true
            pmx.bones[i].flags.translatable = true
            pmx.bones[i].ik = PMXModel.IK(
                targetIndex: Int32(ik.target), loopCount: Int32(ik.loops), limitAngle: ik.limit * 4,
                links: ik.links.map { l in
                    let knee = Int(l) < names.count && names[Int(l)].contains("ひざ")
                    return PMXModel.IKLink(boneIndex: Int32(l), limits: knee
                        ? PMXModel.IKLimit(lower: SIMD3(-.pi, 0, 0), upper: SIMD3(-(0.5 as Float) * (Float.pi / 180), 0, 0)) : nil)
                })
        }
        func bonePos(_ i: Int32) -> SIMD3<Float> {
            let k = i < 0 ? 0 : Int(i)
            return k < pmd.bones.count ? pmd.bones[k].position : .zero
        }
        pmx.rigidBodies = pmd.bodies.map { r in
            var b = PMXModel.RigidBody()
            b.name = r.name
            b.boneIndex = r.bone
            b.group = r.group
            b.mask = r.mask
            b.shape = r.shape
            b.size = r.size
            b.position = bonePos(r.bone) + r.position
            b.rotation = r.rotation
            b.mass = r.mass
            b.linearDamping = r.linearDamping
            b.angularDamping = r.angularDamping
            b.restitution = r.restitution
            b.friction = r.friction
            b.mode = r.mode
            return b
        }
        pmx.joints = pmd.joints.map { j in
            var x = PMXModel.Joint()
            x.name = j.name
            x.kind = "generic6dofSpring"
            x.rigidBodyIndexA = Int32(bitPattern: j.a)
            x.rigidBodyIndexB = Int32(bitPattern: j.b)
            x.position = j.values[0]
            x.rotation = j.values[1]
            x.translationLowerLimit = j.values[2]
            x.translationUpperLimit = j.values[3]
            x.rotationLowerLimit = j.values[4]
            x.rotationUpperLimit = j.values[5]
            x.springTranslationFactor = j.values[6]
            x.springRotationFactor = j.values[7]
            return x
        }
        pmx.metadata.counts.rigidBodies = pmx.rigidBodies.count
        pmx.metadata.counts.joints = pmx.joints.count
        return pmx
    }
}
