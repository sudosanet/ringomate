extension PMXModel {
    func pmxBytes() -> [UInt8] {
        let utf16 = metadata.encoding == "utf-16-le"
        let s = metadata.indexSizes
        var w = ByteWriter()
        w.out = [0x50, 0x4D, 0x58, 0x20]
        w.f32(metadata.version)
        w.u8(8)
        w.u8(utf16 ? 0 : 1)
        w.u8(metadata.additionalUVCount)
        for v in [s.vertex, s.texture, s.material, s.bone, s.morph, s.rigidBody] { w.u8(v) }
        for t in [metadata.name, metadata.englishName, metadata.comment, metadata.englishComment] {
            w.string(t, utf16: utf16)
        }

        let g = geometry
        let n = g.positions.count / 3
        w.i32(Int32(n))
        for v in 0..<n {
            w.floats(g.positions[v * 3..<v * 3 + 3])
            w.floats(g.normals[v * 3..<v * 3 + 3])
            w.floats(g.uvs[v * 2..<v * 2 + 2])
            for uv in g.additionalUVs { w.floats(uv[v * 4..<v * 4 + 4]) }
            writeSkinning(&w, v)
            w.f32(v < g.edgeScale.count ? g.edgeScale[v] : 1)
        }
        w.i32(Int32(g.indices.count))
        for i in g.indices { w.vertexIndex(i, s.vertex) }

        var textures: [String] = []
        for m in materials {
            for t in [m.texturePath, m.sphereTexturePath, m.toonTexturePath] where !t.isEmpty && !textures.contains(t) {
                textures.append(t)
            }
        }
        func textureIndex(_ t: String) -> Int32 {
            t.isEmpty ? -1 : textures.firstIndex(of: t).map(Int32.init) ?? -1
        }
        w.i32(Int32(textures.count))
        for t in textures { w.string(t, utf16: utf16) }

        w.i32(Int32(materials.count))
        for m in materials {
            w.string(m.name, utf16: utf16)
            w.string(m.englishName, utf16: utf16)
            w.vec(m.diffuse)
            w.vec(m.specular)
            w.f32(m.specularPower)
            w.vec(m.ambient)
            w.u8(m.flags.bits)
            w.vec(m.edgeColor)
            w.f32(m.edgeSize)
            w.sizedIndex(textureIndex(m.texturePath), s.texture)
            w.sizedIndex(textureIndex(m.sphereTexturePath), s.texture)
            w.u8(["multiply": 1, "add": 2, "subTexture": 3][m.sphereMode] ?? 0)
            if let shared = m.sharedToonIndex {
                w.u8(1)
                w.u8(shared)
            } else {
                w.u8(0)
                w.sizedIndex(textureIndex(m.toonTexturePath), s.texture)
            }
            w.string("", utf16: utf16)
            w.i32(m.faceCount.multipliedReportingOverflow(by: 3).overflow
                ? (m.faceCount < 0 ? .min : .max) : m.faceCount * 3)
        }

        w.i32(Int32(bones.count))
        for b in bones {
            w.string(b.name, utf16: utf16)
            w.string(b.englishName, utf16: utf16)
            w.vec(b.position)
            w.sizedIndex(b.parentIndex, s.bone)
            w.i32(b.layer)
            w.u16(b.flags.bits)
            if b.flags.indexedTail {
                w.sizedIndex(b.tailIndex, s.bone)
            } else {
                w.vec(b.tailPosition ?? .zero)
            }
            if b.flags.appendRotate || b.flags.appendTranslate {
                w.sizedIndex(b.appendTransform?.parentIndex ?? -1, s.bone)
                w.f32(b.appendTransform?.weight ?? 0)
            }
            if b.flags.fixedAxis { w.vec(b.fixedAxis ?? .zero) }
            if b.flags.localAxis {
                w.vec(b.localAxis?.x ?? SIMD3(1, 0, 0))
                w.vec(b.localAxis?.z ?? SIMD3(0, 0, 1))
            }
            if b.flags.externalParentTransform { w.i32(b.externalParentKey ?? 0) }
            if b.flags.ik {
                if let ik = b.ik {
                    w.sizedIndex(ik.targetIndex, s.bone)
                    w.i32(ik.loopCount)
                    w.f32(ik.limitAngle)
                    w.i32(Int32(ik.links.count))
                    for l in ik.links {
                        w.sizedIndex(l.boneIndex, s.bone)
                        w.u8(l.limits == nil ? 0 : 1)
                        if let lim = l.limits {
                            w.vec(lim.lower)
                            w.vec(lim.upper)
                        }
                    }
                } else {
                    w.sizedIndex(-1, s.bone)
                    w.i32(0)
                    w.f32(0)
                    w.i32(0)
                }
            }
        }

        w.i32(Int32(morphs.count))
        for m in morphs {
            w.string(m.name, utf16: utf16)
            w.string(m.englishName, utf16: utf16)
            w.u8(UInt8(Self.panels.firstIndex(of: m.panel) ?? 4))
            let type = m.typeByte
            w.u8(type)
            switch type {
            case 0, 9:
                let offsets = type == 0 ? m.groupOffsets : m.flipOffsets
                w.i32(Int32(offsets.count))
                for o in offsets {
                    w.sizedIndex(o.morphIndex, s.morph)
                    w.f32(o.weight)
                }
            case 1:
                w.i32(Int32(m.vertexOffsets.count))
                for o in m.vertexOffsets {
                    w.vertexIndex(o.vertexIndex, s.vertex)
                    w.vec(o.position)
                }
            case 2:
                w.i32(Int32(m.boneOffsets.count))
                for o in m.boneOffsets {
                    w.sizedIndex(o.boneIndex, s.bone)
                    w.vec(o.translation)
                    w.vec(o.rotation)
                }
            case 3:
                w.i32(Int32(m.uvOffsets.count))
                for o in m.uvOffsets {
                    w.vertexIndex(o.vertexIndex, s.vertex)
                    w.vec(o.uv)
                }
            case 4...7:
                w.i32(Int32(m.additionalUVOffsets.count))
                for o in m.additionalUVOffsets {
                    w.vertexIndex(o.vertexIndex, s.vertex)
                    w.vec(o.uv)
                }
            case 8:
                w.i32(Int32(m.materialOffsets.count))
                for o in m.materialOffsets {
                    w.sizedIndex(o.materialIndex, s.material)
                    w.u8(o.operation == "multiply" ? 0 : 1)
                    w.vec(o.diffuse)
                    w.vec(o.specular)
                    w.f32(o.specularPower)
                    w.vec(o.ambient)
                    w.vec(o.edgeColor)
                    w.f32(o.edgeSize)
                    w.vec(o.textureFactor)
                    w.vec(o.sphereTextureFactor)
                    w.vec(o.toonTextureFactor)
                }
            default:
                w.i32(Int32(m.impulseOffsets.count))
                for o in m.impulseOffsets {
                    w.sizedIndex(o.rigidBodyIndex, s.rigidBody)
                    w.u8(o.local ? 1 : 0)
                    w.vec(o.velocity)
                    w.vec(o.torque)
                }
            }
        }

        w.i32(Int32(displayFrames.count))
        for f in displayFrames {
            w.string(f.name, utf16: utf16)
            w.string(f.englishName, utf16: utf16)
            w.u8(f.special ? 1 : 0)
            w.i32(Int32(f.frames.count))
            for item in f.frames {
                if item.kind == "morph" {
                    w.u8(1)
                    w.sizedIndex(item.index, s.morph)
                } else {
                    w.u8(0)
                    w.sizedIndex(item.index, s.bone)
                }
            }
        }

        w.i32(Int32(rigidBodies.count))
        for b in rigidBodies {
            w.string(b.name, utf16: utf16)
            w.string(b.englishName, utf16: utf16)
            w.sizedIndex(b.boneIndex, s.bone)
            w.u8(b.group)
            w.u16(b.mask)
            w.u8(b.shape == "box" ? 1 : b.shape == "capsule" ? 2 : 0)
            w.vec(b.size)
            w.vec(b.position)
            w.vec(b.rotation)
            for v in [b.mass, b.linearDamping, b.angularDamping, b.restitution, b.friction] { w.f32(v) }
            w.u8(b.mode == "dynamic" ? 1 : b.mode == "dynamicBone" ? 2 : 0)
        }

        w.i32(Int32(joints.count))
        for j in joints {
            w.string(j.name, utf16: utf16)
            w.string(j.englishName, utf16: utf16)
            w.u8(UInt8(Self.jointKinds.dropFirst().firstIndex(of: j.kind) ?? 0))
            w.sizedIndex(j.rigidBodyIndexA, s.rigidBody)
            w.sizedIndex(j.rigidBodyIndexB, s.rigidBody)
            for v in [j.position, j.rotation, j.translationLowerLimit, j.translationUpperLimit, j.rotationLowerLimit,
                      j.rotationUpperLimit, j.springTranslationFactor, j.springRotationFactor] { w.vec(v) }
        }

        if metadata.version >= 2.05 {
            w.i32(Int32(softBodies.count))
            for b in softBodies {
                w.string(b.name, utf16: utf16)
                w.string(b.englishName, utf16: utf16)
                w.u8(b.kind == "rope" ? 1 : 0)
                w.sizedIndex(b.materialIndex, s.material)
                w.u8(b.collisionGroup)
                w.u16(b.collisionMask)
                w.u8(b.flags)
                w.i32(b.bendingConstraintsDistance)
                w.i32(b.clusterCount)
                w.f32(b.totalMass)
                w.f32(b.collisionMargin)
                w.out += Array(repeating: 0, count: Self.softBodySkip)
                w.i32(0)
                w.i32(0)
            }
        }
        return w.out
    }

    private func writeSkinning(_ w: inout ByteWriter, _ v: Int) {
        let g = geometry
        let bone = metadata.indexSizes.bone
        func index(_ slot: Int) {
            let i = v * 4 + slot
            w.sizedIndex(Int32(truncatingIfNeeded: i < g.skinIndices.count ? g.skinIndices[i] : 0), bone)
        }
        func weight(_ slot: Int) -> Float {
            let i = v * 4 + slot
            return i < g.skinWeights.count ? g.skinWeights[i] : slot == 0 ? 1 : 0
        }
        func vec3(_ a: [Float]) {
            for k in 0..<3 { w.f32(v * 3 + k < a.count ? a[v * 3 + k] : 0) }
        }
        let mode: String = if v < g.sdef.skinningModes.count {
            g.sdef.skinningModes[v]
        } else if v < g.sdef.enabled.count, g.sdef.enabled[v] > 0.5 {
            "sdef"
        } else if v < g.qdefEnabled.count, g.qdefEnabled[v] > 0.5 {
            "qdef"
        } else {
            "bdef4"
        }
        switch mode {
        case "bdef1":
            w.u8(0)
            index(0)
        case "bdef2", "sdef":
            w.u8(mode == "sdef" ? 3 : 1)
            index(0)
            index(1)
            w.f32(weight(0))
            if mode == "sdef" {
                vec3(g.sdef.c)
                vec3(g.sdef.r0)
                vec3(g.sdef.r1)
            }
        default:
            w.u8(mode == "qdef" ? 4 : 2)
            for k in 0..<4 { index(k) }
            for k in 0..<4 { w.f32(weight(k)) }
        }
    }
}

extension PMXModel.Morph {
    /// 追加 UV は最初の差分の番号（なければ 4）。
    var typeByte: UInt8 {
        switch kind {
        case "group": 0
        case "vertex": 1
        case "bone": 2
        case "uv": 3
        case "additionalUv": UInt8(min(UInt16(additionalUVOffsets.first?.uvIndex ?? 0) + 4, 7))
        case "material": 8
        case "flip": 9
        case "impulse": 10
        default: 0
        }
    }
}
