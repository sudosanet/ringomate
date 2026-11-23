extension PMXModel {
    struct Header {
        var version: Float
        var utf16: Bool
        var extraUV: UInt8
        var vertex: UInt8, texture: UInt8, material: UInt8, bone: UInt8, morph: UInt8, rigidBody: UInt8
    }

    public init(pmx data: [UInt8]) throws {
        var r = ByteReader(data)
        let h = try Self.header(&r)
        metadata.version = h.version
        metadata.encoding = h.utf16 ? "utf-16-le" : "utf-8"
        metadata.name = try r.string(utf16: h.utf16)
        metadata.englishName = try r.string(utf16: h.utf16)
        metadata.comment = try r.string(utf16: h.utf16)
        metadata.englishComment = try r.string(utf16: h.utf16)
        metadata.indexSizes = IndexSizes(vertex: h.vertex, texture: h.texture, material: h.material,
                                         bone: h.bone, morph: h.morph, rigidBody: h.rigidBody)
        metadata.additionalUVCount = h.extraUV

        let vertexCount = try r.count(minRecord: 12 + 12 + 8 + 1 + 4)
        geometry = try Self.geometry(&r, h, vertexCount)
        let textures = try (0..<r.count(minRecord: 4, max: 1_000_000)).map { _ in try r.string(utf16: h.utf16) }
        materials = try Self.materials(&r, h, textures)
        var start = 0
        geometry.materialGroups = materials.enumerated().map { i, m in
            let count = Int(max(m.faceCount, 0)) * 3
            defer { start += count }
            return MaterialGroup(start: start, count: count, materialIndex: i)
        }
        let boneCount = try r.count(minRecord: 4 + 4 + 12)
        bones = try Self.bones(&r, h, boneCount)
        morphs = try Self.morphs(&r, h)
        displayFrames = try Self.displayFrames(&r, h)
        rigidBodies = r.remaining >= 4 ? try Self.rigidBodies(&r, h) : []
        joints = r.remaining >= 4 ? try Self.joints(&r, h) : []
        softBodies = h.version >= 2.05 && r.remaining >= 4 ? try Self.softBodies(&r, h) : []

        if !softBodies.isEmpty {
            diagnostics.append(Diagnostic(
                level: "warning", code: "PMX_SOFT_BODY_UNSUPPORTED",
                message: "\(softBodies.count) PMX soft bodies are read as header records only."))
        }
        if r.remaining > 0 {
            diagnostics.append(Diagnostic(
                level: "warning", code: "PMX_TRAILING_DATA_UNPARSED",
                message: "\(r.remaining) trailing PMX bytes were left unparsed."))
        }
        try validate()
        metadata.counts = Counts(
            vertices: vertexCount, faces: geometry.indices.count / 3, materials: materials.count, bones: bones.count,
            morphs: morphs.count, displayFrames: displayFrames.count, rigidBodies: rigidBodies.count,
            joints: joints.count, softBodies: softBodies.count)
    }

    static func header(_ r: inout ByteReader) throws -> Header {
        guard Array(try r.bytes(4)) == [0x50, 0x4D, 0x58, 0x20] else { throw FormatError.invalidPMXMagic }
        let version = try r.f32()
        guard version >= 2.0, version <= 2.2 else { throw FormatError.unsupportedPMXVersion(version) }
        let dataCount = try r.u8()
        guard dataCount >= 8 else { throw FormatError.invalidEncoding(dataCount) }
        let enc = try r.u8()
        guard enc <= 1 else { throw FormatError.invalidEncoding(enc) }
        let extra = try r.u8()
        let sizes = try (0..<6).map { _ in try r.u8() }
        for s in sizes where ![1, 2, 4].contains(s) { throw FormatError.invalidIndexSize(s) }
        if dataCount > 8 { try r.skip(Int(dataCount) - 8) }
        return Header(version: version, utf16: enc == 0, extraUV: extra, vertex: sizes[0], texture: sizes[1],
                      material: sizes[2], bone: sizes[3], morph: sizes[4], rigidBody: sizes[5])
    }

    static func geometry(_ r: inout ByteReader, _ h: Header, _ n: Int) throws -> Geometry {
        try r.requireRecords(n, 12 + 12 + 8 + 1 + 4)
        var g = Geometry()
        g.positions.reserveCapacity(n * 3)
        g.normals.reserveCapacity(n * 3)
        g.uvs.reserveCapacity(n * 2)
        g.additionalUVs = Array(repeating: [], count: Int(h.extraUV))
        g.skinIndices.reserveCapacity(n * 4)
        g.skinWeights.reserveCapacity(n * 4)
        g.edgeScale.reserveCapacity(n)
        g.sdef.skinningModes.reserveCapacity(n)
        g.sdef.enabled = Array(repeating: 0, count: n)
        for k in [\SDEF.c, \SDEF.r0, \SDEF.r1, \SDEF.rw0, \SDEF.rw1] {
            g.sdef[keyPath: k] = Array(repeating: 0, count: n * 3)
        }
        g.qdefEnabled = Array(repeating: 0, count: n)
        func index(_ r: inout ByteReader) throws -> UInt32 { UInt32(max(try r.sizedIndex(h.bone), 0)) }
        for v in 0..<n {
            let p = try r.vec3(), nn = try r.vec3(), uv = try r.vec2()
            g.positions += [p.x, p.y, p.z]
            g.normals += [nn.x, nn.y, nn.z]
            g.uvs += [uv.x, uv.y]
            for k in g.additionalUVs.indices {
                let a = try r.vec4()
                g.additionalUVs[k] += [a.x, a.y, a.z, a.w]
            }
            let type = try r.u8()
            var idx: [UInt32] = [0, 0, 0, 0]
            var w: [Float] = [0, 0, 0, 0]
            switch type {
            case 0:
                g.sdef.skinningModes.append("bdef1")
                idx[0] = try index(&r)
                w[0] = 1
            case 1, 3:
                g.sdef.skinningModes.append(type == 3 ? "sdef" : "bdef2")
                idx[0] = try index(&r)
                idx[1] = try index(&r)
                let w0 = try r.f32()
                w[0] = w0
                w[1] = 1 - w0
                if type == 3 {
                    let c = try r.vec3(), r0 = try r.vec3(), r1 = try r.vec3()
                    let w1 = 1 - w0
                    g.sdef.enabled[v] = 1
                    for k in 0..<3 {
                        g.sdef.c[v * 3 + k] = c[k]
                        g.sdef.r0[v * 3 + k] = r0[k]
                        g.sdef.r1[v * 3 + k] = r1[k]
                        let rw = r0[k] * w0 + r1[k] * w1
                        g.sdef.rw0[v * 3 + k] = (c[k] * 2 + r0[k] - rw) * 0.5
                        g.sdef.rw1[v * 3 + k] = (c[k] * 2 + r1[k] - rw) * 0.5
                    }
                }
            case 2, 4:
                g.sdef.skinningModes.append(type == 2 ? "bdef4" : "qdef")
                for k in 0..<4 { idx[k] = try index(&r) }
                for k in 0..<4 { w[k] = try r.f32() }
                if type == 4 { g.qdefEnabled[v] = 1 }
            default:
                throw FormatError.sectionOverflow
            }
            g.skinIndices += idx
            g.skinWeights += w
            g.edgeScale.append(try r.f32())
        }
        let indexCount = try r.count(minRecord: Int(h.vertex))
        g.indices.reserveCapacity(indexCount)
        for _ in 0..<indexCount { g.indices.append(try r.vertexIndex(h.vertex)) }
        return g
    }

    static func materials(_ r: inout ByteReader, _ h: Header, _ textures: [String]) throws -> [Material] {
        func path(_ i: Int32) -> String { i >= 0 && Int(i) < textures.count ? textures[Int(i)] : "" }
        return try (0..<r.count(minRecord: 4 + 4 + 16 + 16 + 12 + 1 + 16 + 4)).map { _ in
            var m = Material()
            m.name = try r.string(utf16: h.utf16)
            m.englishName = try r.string(utf16: h.utf16)
            m.diffuse = try r.vec4()
            m.specular = try r.vec3()
            m.specularPower = try r.f32()
            m.ambient = try r.vec3()
            m.flags = MaterialFlags(bits: try r.u8())
            m.edgeColor = try r.vec4()
            m.edgeSize = try r.f32()
            m.texturePath = path(try r.sizedIndex(h.texture))
            m.sphereTexturePath = path(try r.sizedIndex(h.texture))
            m.sphereMode = switch try r.u8() {
            case 1: "multiply"
            case 2: "add"
            case 3: "subTexture"
            default: "none"
            }
            if try r.u8() == 0 {
                m.toonTexturePath = path(try r.sizedIndex(h.texture))
            } else {
                m.sharedToonIndex = try r.u8()
            }
            _ = try r.string(utf16: h.utf16)
            m.faceCount = try r.i32() / 3
            return m
        }
    }

    static func bones(_ r: inout ByteReader, _ h: Header, _ n: Int) throws -> [Bone] {
        try r.requireRecords(n, 4 + 4 + 12)
        return try (0..<n).map { _ in
            var b = Bone()
            b.name = try r.string(utf16: h.utf16)
            b.englishName = try r.string(utf16: h.utf16)
            b.position = try r.vec3()
            b.parentIndex = try r.sizedIndex(h.bone)
            b.layer = try r.i32()
            b.flags = BoneFlags(bits: try r.u16())
            if b.flags.indexedTail {
                b.tailIndex = try r.sizedIndex(h.bone)
            } else {
                b.tailIndex = -1
                b.tailPosition = try r.vec3()
            }
            if b.flags.appendRotate || b.flags.appendTranslate {
                b.appendTransform = AppendTransform(parentIndex: try r.sizedIndex(h.bone), weight: try r.f32())
            }
            if b.flags.fixedAxis { b.fixedAxis = try r.vec3() }
            if b.flags.localAxis { b.localAxis = LocalAxis(x: try r.vec3(), z: try r.vec3()) }
            if b.flags.externalParentTransform { b.externalParentKey = try r.i32() }
            if b.flags.ik {
                let target = try r.sizedIndex(h.bone)
                let loops = try r.i32()
                let limit = try r.f32()
                let links = try (0..<r.count(minRecord: Int(h.bone) + 1)).map { _ in
                    let bone = try r.sizedIndex(h.bone)
                    let limits = try r.u8() != 0 ? IKLimit(lower: try r.vec3(), upper: try r.vec3()) : nil
                    return IKLink(boneIndex: bone, limits: limits)
                }
                b.ik = IK(targetIndex: target, loopCount: loops, limitAngle: limit, links: links)
            }
            return b
        }
    }

    static let panels = ["system", "brow", "eye", "mouth", "other"]

    static func morphs(_ r: inout ByteReader, _ h: Header) throws -> [Morph] {
        try (0..<r.count(minRecord: 4 + 4 + 1 + 1 + 4)).map { _ in
            var m = Morph()
            m.name = try r.string(utf16: h.utf16)
            m.englishName = try r.string(utf16: h.utf16)
            let panel = Int(try r.u8())
            m.panel = panel < panels.count ? panels[panel] : "unknown"
            let type = try r.u8()
            let minSize: Int = switch type {
            case 0, 9: Int(h.morph) + 4
            case 1: Int(h.vertex) + 12
            case 2: Int(h.bone) + 12 + 16
            case 3...7: Int(h.vertex) + 16
            case 8: Int(h.material) + 1 + 16 + 12 + 4 + 12 + 16 + 4 + 16 + 16 + 16
            case 10: Int(h.rigidBody) + 1 + 12 + 12
            default: throw FormatError.sectionOverflow
            }
            m.kind = ["group", "vertex", "bone", "uv", "additionalUv", "additionalUv", "additionalUv",
                      "additionalUv", "material", "flip", "impulse"][Int(type)]
            for _ in 0..<(try r.count(minRecord: minSize)) {
                switch type {
                case 0: m.groupOffsets.append(GroupOffset(morphIndex: try r.sizedIndex(h.morph), weight: try r.f32()))
                case 1: m.vertexOffsets.append(VertexOffset(vertexIndex: try r.vertexIndex(h.vertex), position: try r.vec3()))
                case 2:
                    m.boneOffsets.append(BoneOffset(boneIndex: try r.sizedIndex(h.bone), translation: try r.vec3(),
                                                    rotation: try r.vec4()))
                case 3: m.uvOffsets.append(UVOffset(vertexIndex: try r.vertexIndex(h.vertex), uv: try r.vec4()))
                case 4...7:
                    m.additionalUVOffsets.append(AdditionalUVOffset(vertexIndex: try r.vertexIndex(h.vertex),
                                                                    uvIndex: type - 4, uv: try r.vec4()))
                case 8:
                    m.materialOffsets.append(MaterialOffset(
                        materialIndex: try r.sizedIndex(h.material), operation: try r.u8() == 0 ? "multiply" : "add",
                        diffuse: try r.vec4(), specular: try r.vec3(), specularPower: try r.f32(), ambient: try r.vec3(),
                        edgeColor: try r.vec4(), edgeSize: try r.f32(), textureFactor: try r.vec4(),
                        sphereTextureFactor: try r.vec4(), toonTextureFactor: try r.vec4()))
                case 9: m.flipOffsets.append(GroupOffset(morphIndex: try r.sizedIndex(h.morph), weight: try r.f32()))
                default:
                    m.impulseOffsets.append(ImpulseOffset(rigidBodyIndex: try r.sizedIndex(h.rigidBody),
                                                          local: try r.u8() != 0, velocity: try r.vec3(),
                                                          torque: try r.vec3()))
                }
            }
            return m
        }
    }

    static func displayFrames(_ r: inout ByteReader, _ h: Header) throws -> [DisplayFrame] {
        try (0..<r.count(minRecord: 4 + 4 + 1 + 4)).map { _ in
            var f = DisplayFrame()
            f.name = try r.string(utf16: h.utf16)
            f.englishName = try r.string(utf16: h.utf16)
            f.special = try r.u8() == 1
            f.frames = try (0..<r.count(minRecord: 1)).map { _ in
                switch try r.u8() {
                case 0: DisplayFrameElement(kind: "bone", index: try r.sizedIndex(h.bone))
                case 1: DisplayFrameElement(kind: "morph", index: try r.sizedIndex(h.morph))
                default: throw FormatError.sectionOverflow
                }
            }
            return f
        }
    }

    static func rigidBodies(_ r: inout ByteReader, _ h: Header) throws -> [RigidBody] {
        try (0..<r.count(minRecord: 4 + 4 + Int(h.bone) + 1 + 2 + 1 + 36 + 20 + 1)).map { _ in
            var b = RigidBody()
            b.name = try r.string(utf16: h.utf16)
            b.englishName = try r.string(utf16: h.utf16)
            b.boneIndex = try r.sizedIndex(h.bone)
            b.group = try r.u8()
            b.mask = try r.u16()
            let shape = Int(try r.u8())
            b.shape = shape < 3 ? ["sphere", "box", "capsule"][shape] : "unknown"
            b.size = try r.vec3()
            b.position = try r.vec3()
            b.rotation = try r.vec3()
            b.mass = try r.f32()
            b.linearDamping = try r.f32()
            b.angularDamping = try r.f32()
            b.restitution = try r.f32()
            b.friction = try r.f32()
            let mode = Int(try r.u8())
            b.mode = mode < 3 ? ["static", "dynamic", "dynamicBone"][mode] : "unknown"
            return b
        }
    }

    static let jointKinds = ["generic6dofSpring", "generic6dof", "point2point", "coneTwist", "slider", "hinge"]

    static func joints(_ r: inout ByteReader, _ h: Header) throws -> [Joint] {
        try (0..<r.count(minRecord: 4 + 4 + 1 + Int(h.rigidBody) * 2 + 12 * 8)).map { _ in
            var j = Joint()
            j.name = try r.string(utf16: h.utf16)
            j.englishName = try r.string(utf16: h.utf16)
            let kind = Int(try r.u8())
            j.kind = kind < jointKinds.count ? jointKinds[kind] : "unknown"
            j.rigidBodyIndexA = try r.sizedIndex(h.rigidBody)
            j.rigidBodyIndexB = try r.sizedIndex(h.rigidBody)
            j.position = try r.vec3()
            j.rotation = try r.vec3()
            j.translationLowerLimit = try r.vec3()
            j.translationUpperLimit = try r.vec3()
            j.rotationLowerLimit = try r.vec3()
            j.rotationUpperLimit = try r.vec3()
            j.springTranslationFactor = try r.vec3()
            j.springRotationFactor = try r.vec3()
            return j
        }
    }

    static let softBodySkip = 4 + 12 * 4 + 6 * 4 + 4 * 4 + 3 * 4

    static func softBodies(_ r: inout ByteReader, _ h: Header) throws -> [SoftBody] {
        try (0..<r.count(minRecord: 4 + 4 + 1 + Int(h.material) + 1 + 2 + 1 + 16 + softBodySkip + 8)).map { _ in
            var s = SoftBody()
            s.name = try r.string(utf16: h.utf16)
            s.englishName = try r.string(utf16: h.utf16)
            let kind = try r.u8()
            s.kind = kind == 0 ? "triMesh" : kind == 1 ? "rope" : "unknown"
            s.materialIndex = try r.sizedIndex(h.material)
            s.collisionGroup = try r.u8()
            s.collisionMask = try r.u16()
            s.flags = try r.u8()
            s.bendingConstraintsDistance = try r.i32()
            s.clusterCount = try r.i32()
            s.totalMass = try r.f32()
            s.collisionMargin = try r.f32()
            try r.skip(softBodySkip)
            for _ in 0..<(try r.count(minRecord: Int(h.rigidBody) + Int(h.vertex) + 1)) {
                _ = try r.sizedIndex(h.rigidBody)
                _ = try r.vertexIndex(h.vertex)
                try r.skip(1)
            }
            for _ in 0..<(try r.count(minRecord: Int(h.vertex))) { _ = try r.vertexIndex(h.vertex) }
            return s
        }
    }
}
