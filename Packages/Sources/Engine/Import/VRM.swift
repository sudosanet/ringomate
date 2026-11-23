import Foundation
import simd

/// 座標: 1.0（と VRM でない glTF）は Z の反転、0.x は X の反転、× 12.5（m → MMD 単位）。三角形の並びは逆にする。
/// ponytail: MToon のテクスチャ（影色・リム・MatCap・UV アニメのマスク）、表情の UV・材質の変化、目の注視は使わない。
enum VRM {
    static let scale: Float = 12.5
    static let armDownDegrees: Float = 35

    struct Converted {
        var pmx: PMXModel
        var images: [(String, [UInt8])]
        var mtoon: [[Float]]
        var diagnostics: [String]
        var format: String
        var terms: String
    }

    struct NotHumanoid: Error, CustomStringConvertible {
        var description: String { "humanoid bones (hips and both legs) not found" }
    }

    enum Version { case v0, v1 }

    struct Prim {
        var node: Int, mesh: Int, base: UInt32
        var targets: [[SIMD3<Float>]]
    }

    static func convert(_ bytes: [UInt8]) throws -> Converted {
        let glb = try GLB(bytes)
        let json = glb.json
        let ext = json["extensions"]
        let plain = !ext["VRMC_vrm"].isObject && !ext["VRM"].isObject
        let version: Version = ext["VRM"].isObject ? .v0 : .v1
        let vrm = version == .v0 ? ext["VRM"] : ext["VRMC_vrm"]
        var diagnostics = [plain ? "glTF (no VRM; humanoid guessed from bone names)" : version == .v1 ? "vrm 1.0" : "vrm 0.x"]
        let nodes = json["nodes"].array ?? []

        var humanoid: [Int: String] = [:]
        var humanNode: [String: Int] = [:]
        func add(_ bone: String, _ node: Int?) {
            guard let n = node, n < nodes.count else { return }
            humanNode[bone] = n
            if let name = mmdName(bone, version) { humanoid[n] = name }
        }
        if plain {
            for (bone, n) in GLTFHumanoid.guess(nodes.map { $0["name"].string }) { add(bone, n) }
        }
        switch version {
        case .v1: for (bone, b) in vrm["humanoid"]["humanBones"].entries { add(bone, b["node"].uint) }
        case .v0: for b in vrm["humanoid"]["humanBones"].array ?? [] { add(b["bone"].string ?? "", b["node"].uint) }
        }

        let (children, parent, order) = GLB.tree(nodes)
        var world = [simd_float4x4](repeating: matrix_identity_float4x4, count: nodes.count)
        for i in order {
            let l = local(nodes[i])
            world[i] = parent[i].map { world[$0] * l } ?? l
        }
        let skins = json["skins"].array ?? []
        let required = ["hips", "leftUpperLeg", "rightUpperLeg"]
        if plain, !required.allSatisfy({ humanNode[$0] != nil }) {
            let joints = skins.flatMap { ($0["joints"].array ?? []).compactMap(\.uint) }
            let inferred = GLTFHumanoid.infer(parent: parent, pos: world.map { $0.columns.3.xyz }, joints: joints)
            if !inferred.isEmpty { diagnostics.append("skeleton: \(inferred.count) bones inferred from the hierarchy") }
            let taken = Array(humanNode.values)
            for (bone, n) in inferred where humanNode[bone] == nil && !taken.contains(n) {
                if let name = mmdName(bone, version) { humanoid[n] = name }
                humanNode[bone] = n
            }
        }
        guard required.allSatisfy({ humanNode[$0] != nil }) else { throw NotHumanoid() }
        func descendants(_ root: Int) -> [Int] {
            var out = [root], k = 0
            while k < out.count {
                out += children[out[k]]
                k += 1
            }
            return out
        }
        for (upper, lower) in [("leftUpperArm", "leftLowerArm"), ("rightUpperArm", "rightLowerArm")] {
            guard let u = humanNode[upper], let l = humanNode[lower] else { continue }
            let pivot = world[u].columns.3.xyz
            let dir = Math.normalizeOrZero(world[l].columns.3.xyz - pivot)
            let a = Math.radians(armDownDegrees)
            let target = SIMD3<Float>(dir.x.sign == .minus ? -cos(a) : cos(a), -sin(a), 0)
            let r = Math.translation(pivot) * simd_float4x4(Math.rotationArc(dir, target)) * Math.translation(-pivot)
            for d in descendants(u) { world[d] = r * world[d] }
        }
        func conv(_ v: SIMD3<Float>) -> SIMD3<Float> { version == .v1 ? SIMD3(v.x, v.y, -v.z) : SIMD3(-v.x, v.y, v.z) }

        var isBone = [Bool](repeating: false, count: nodes.count)
        for s in skins { for j in (s["joints"].array ?? []).compactMap(\.uint) where j < nodes.count { isBone[j] = true } }
        for n in humanoid.keys where n < nodes.count { isBone[n] = true }
        var boneOf: [Int: Int] = [:]
        var bones = [
            bone("全ての親", -1, .zero, translatable: true),
            bone("センター", 0, (humanNode["hips"].map { conv(world[$0].columns.3.xyz) * scale } ?? .zero)
                * SIMD3(0, 0.65, 0), translatable: true),
        ]
        func nearestBone(_ start: Int?) -> Int {
            var n = start
            while let i = n {
                if let b = boneOf[i] { return b }
                n = parent[i]
            }
            return 0
        }
        for i in order where isBone[i] {
            let name = humanoid[i] ?? nodes[i]["name"].string ?? "bone\(i)"
            let p = name == "下半身" || name == "上半身" ? 1 : nearestBone(parent[i])
            boneOf[i] = bones.count
            bones.append(bone(name, Int32(p), conv(world[i].columns.3.xyz) * scale, translatable: false))
        }
        func boneIndex(_ name: String) -> Int? { bones.firstIndex { $0.name == name } }
        var iks: [(PMXParts.Bone, Int, [(Int, Bool)])] = []
        for side in ["左", "右"] {
            guard let knee = boneIndex("\(side)ひざ"), let ankle = boneIndex("\(side)足首"), let thigh = boneIndex("\(side)足")
            else { continue }
            iks.append((bone("\(side)足ＩＫ", 0, bones[ankle].position, translatable: true), ankle, [(knee, true), (thigh, false)]))
            if let toe = boneIndex("\(side)つま先") {
                iks.append((bone("\(side)つま先ＩＫ", -2, bones[toe].position, translatable: true), toe, [(ankle, false)]))
            }
        }

        var pos: [Float] = [], nrm: [Float] = [], uv: [Float] = []
        var skinI: [UInt32] = [], skinW: [Float] = []
        var groups: [(key: (Int, Int), order: Int, material: Int?, tri: [UInt32])] = []
        var prims: [Prim] = []
        let meshes = json["meshes"].array ?? []
        let materialsJSON = json["materials"].array ?? []
        func addGroup(_ prim: JSONValue, _ indices: [UInt32]) {
            let mi = prim["material"].uint
            let mode = mi.map { materialsJSON.indices.contains($0) ? materialsJSON[$0]["alphaMode"].string ?? "OPAQUE" : "OPAQUE" }
            let cls = mode == "MASK" ? 1 : mode == "BLEND" ? 2 : 0
            groups.append(((cls, renderQueue(vrm, json, mi, version)), groups.count, mi, indices))
        }
        func readIndices(_ prim: JSONValue) -> [UInt32]? {
            prim["indices"].uint.flatMap { glb.accessor($0) }.flatMap { a in
                let out = a.compactMap { $0.count == 1 ? UInt32(exactly: $0[0]) : nil }
                return out.count == a.count ? out : nil
            }
        }
        for ni in order {
            let node = nodes[ni]
            guard let meshIndex = node["mesh"].uint, meshIndex < meshes.count else { continue }
            let skin: [(Int, simd_float4x4)]? = node["skin"].uint.flatMap { si in
                guard si < skins.count else { return nil }
                let s = skins[si]
                let ibm: [simd_float4x4] = s["inverseBindMatrices"].uint.flatMap { glb.floats($0, components: 16) }.map { ms in
                    ms.map { v in
                        simd_float4x4(SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                                      SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
                    }
                } ?? []
                return (s["joints"].array ?? []).enumerated().compactMap { k, j in
                    guard let j = j.uint, j < nodes.count else { return nil }
                    let m = world[j] * (k < ibm.count ? ibm[k] : matrix_identity_float4x4)
                    return (boneOf[j] ?? 0, m)
                }
            }
            let rigidBone = nearestBone(ni)
            var shared: [Int: UInt32] = [:]
            for prim in meshes[meshIndex]["primitives"].array ?? [] {
                guard (prim["mode"].uint ?? 4) == 4 else { continue }
                let posAccessor = prim["attributes"]["POSITION"].uint
                if let k = posAccessor, let base = shared[k] {
                    guard var indices = readIndices(prim)?.map({ $0 + base }) else { continue }
                    for t in stride(from: 0, to: indices.count - indices.count % 3, by: 3) { indices.swapAt(t + 1, t + 2) }
                    addGroup(prim, indices)
                    continue
                }
                guard let k = posAccessor, let ps = glb.floats(k, components: 3) else { continue }
                func attribute(_ name: String, _ n: Int, normalize: Bool = false) -> [[Float]]? {
                    prim["attributes"][name].uint.flatMap { glb.floats($0, components: n, normalize: normalize) }
                        .flatMap { $0.count >= ps.count ? $0 : nil }
                }
                let ns = attribute("NORMAL", 3) ?? Array(repeating: [0, 1, 0], count: ps.count)
                let ts = attribute("TEXCOORD_0", 2, normalize: true) ?? Array(repeating: [0, 0], count: ps.count)
                let js: [[Int]] = prim["attributes"]["JOINTS_0"].uint.flatMap { glb.accessor($0) }
                    .map { $0.map { $0.count == 4 ? $0.map { Int(exactly: $0) ?? -1 } : [-1, -1, -1, -1] } } ?? []
                let ws = attribute("WEIGHTS_0", 4, normalize: true) ?? []
                let base = UInt32(pos.count / 3)
                shared[k] = base
                var mats: [simd_float3x3] = []
                mats.reserveCapacity(ps.count)
                for v in 0..<ps.count {
                    var m: simd_float4x4
                    var idx: [UInt32]
                    var w: [Float]
                    if let sk = skin, v < js.count, v < ws.count {
                        let sum = ws[v].reduce(0, +)
                        w = ws[v].map { sum > 0 ? $0 / sum : 0.25 }
                        m = simd_float4x4()
                        idx = [0, 0, 0, 0]
                        for c in 0..<4 {
                            let j = js[v][c]
                            let (b, jm) = j >= 0 && j < sk.count ? sk[j] : (0, matrix_identity_float4x4)
                            idx[c] = UInt32(b)
                            m += jm * w[c]
                        }
                    } else {
                        (m, idx, w) = (world[ni], [UInt32(rigidBone), 0, 0, 0], [1, 0, 0, 0])
                    }
                    let p = conv(Math.point(m, SIMD3(ps[v][0], ps[v][1], ps[v][2]))) * scale
                    let m3 = Math.mat3(m)
                    let n = Math.normalize(conv(m3 * SIMD3(ns[v][0], ns[v][1], ns[v][2])), or: SIMD3(0, 1, 0))
                    pos += [p.x, p.y, p.z]
                    nrm += [n.x, n.y, n.z]
                    uv += [ts[v][0], ts[v][1]]
                    skinI += idx
                    skinW += w
                    mats.append(m3)
                }
                let targets: [[SIMD3<Float>]] = (prim["targets"].array ?? []).map { t in
                    guard let d = t["POSITION"].uint.flatMap({ glb.floats($0, components: 3) }) else { return [] }
                    return zip(d, mats).map { d, m in conv(m * SIMD3(d[0], d[1], d[2])) * scale }
                }
                prims.append(Prim(node: ni, mesh: meshIndex, base: base, targets: targets))
                var indices = readIndices(prim)?.map { $0 + base } ?? Array(base..<base + UInt32(ps.count))
                for t in stride(from: 0, to: indices.count - indices.count % 3, by: 3) { indices.swapAt(t + 1, t + 2) }
                addGroup(prim, indices)
            }
        }
        // 不透明 → 切り抜き → 半透明（同じ種類の中は元の順、安定な並べ替え）
        groups.sort { $0.key != $1.key ? $0.key < $1.key : $0.order < $1.order }

        var images: [(String, [UInt8])] = []
        var imageRef: [Int: String] = [:]
        var materials: [PMXModel.Material] = []
        var mtoon: [[Float]] = []
        var indices: [UInt32] = []
        let textures = json["textures"].array ?? []
        func addImage(_ img: Int?) -> String? {
            guard let img else { return nil }
            if let r = imageRef[img] { return r }
            let im = json["images"][img]
            guard let bv = im["bufferView"].uint, let mime = im["mimeType"].string, let (data, _) = glb.view(bv) else {
                return nil
            }
            let r = "vrm-textures/\(img).\(mime.contains("jpeg") ? "jpg" : "png")"
            images.append((r, Array(data)))
            imageRef[img] = r
            return r
        }
        func textureSource(_ t: Int?) -> Int? { t.flatMap { $0 < textures.count ? textures[$0]["source"].uint : nil } }
        for g in groups {
            let mi = g.material
            let m: JSONValue? = mi.flatMap { $0 < materialsJSON.count ? materialsJSON[$0] : nil }
            let texturePath = addImage(textureSource(m?["pbrMetallicRoughness"]["baseColorTexture"]["index"].uint)) ?? ""
            let shadePath = addImage(textureSource(shadeTexture(vrm, json, mi, version))) ?? ""
            let factor = m?["pbrMetallicRoughness"]["baseColorFactor"].array
            let diffuse = m == nil ? SIMD4<Float>(1, 1, 1, 1)
                : factor.flatMap { $0.count == 4 ? SIMD4($0[0].f, $0[1].f, $0[2].f, $0[3].f) : nil } ?? SIMD4(1, 1, 1, 1)
            let (edge, edgeColor) = outline(vrm, json, mi, version)
            let params = mtoonParams(vrm, json, mi, version)
            let emissionPath = params.isEmpty ? "" : addImage(textureSource(emissionTexture(vrm, json, mi, version))) ?? ""
            mtoon.append(params)
            var x = PMXModel.Material()
            x.name = m?["name"].string ?? "material"
            x.texturePath = texturePath
            x.sphereTexturePath = shadePath
            x.sphereMode = "none"
            x.sharedToonIndex = emissionPath.isEmpty ? 0 : nil
            x.toonTexturePath = emissionPath
            x.diffuse = diffuse
            x.specular = .zero
            x.specularPower = 1
            x.ambient = SIMD3(diffuse.x, diffuse.y, diffuse.z) * 0.5
            x.edgeColor = edgeColor
            x.edgeSize = 1
            x.flags.doubleSided = m?["doubleSided"].bool ?? false
            x.flags.groundShadow = true
            x.flags.selfShadowMap = true
            x.flags.selfShadow = true
            x.flags.edge = edge
            x.faceCount = Int32(g.tri.count / 3)
            materials.append(x)
            indices += g.tri
        }

        let morphs = expressions(vrm, json, version, prims)
        diagnostics.append("vrm: \(humanoid.count) humanoid bones, \(morphs.count) expressions, \(images.count) images")
        let meta = vrm["meta"]
        let title = meta["name"].string ?? meta["title"].string ?? json["scenes"][0]["name"].string ?? "model"
        let author = version == .v1 ? (meta["authors"].array?.compactMap(\.string).joined(separator: ", ") ?? "")
            : meta["author"].string ?? ""
        let license = meta["licenseUrl"].string ?? meta["licenseName"].string ?? ""
        diagnostics.append("vrm meta: \(title) by \(author) (\(license))")
        let terms = plain ? "" : metaTerms(meta)
        let format = plain ? "glTF" : version == .v1 ? "VRM 1.0" : "VRM 0.x"

        let ikStart = bones.count
        var ikSpecs: [(Int, [(Int, Bool)])] = []
        for (k, (b0, target, links)) in iks.enumerated() {
            var b = b0
            if b.parentIndex == -2 { b.parentIndex = Int32(ikStart + k - 1) }
            bones.append(b)
            ikSpecs.append((target, links))
        }
        let spring = version == .v1 ? ext["VRMC_springBone"] : vrm["secondaryAnimation"]
        let (bodies, joints) = VRMSpring.convert(VRMSpring.Input(
            spring: spring, v1: version == .v1, children: children, world: world,
            toMMD: { conv($0) * scale }, scale: scale, boneOf: { nearestBone($0) },
            fastLimb: { n in humanoid[n].map { b in ["手首", "ひじ", "腕", "指"].contains { b.contains($0) } } ?? false }))
        diagnostics.append("vrm: \(bodies.count) rigid bodies, \(joints.count) joints from spring bones")

        var parts = PMXParts()
        parts.name = title
        parts.englishName = title
        parts.comment = "\(title)\n\(author)\n\(license)"
        parts.materialName = ""
        parts.materials = materials
        parts.bones = bones
        parts.morphs = morphs
        parts.rigidBodies = bodies
        parts.joints = joints
        parts.indexSizes = PMXModel.IndexSizes(vertex: 4, texture: 4, material: 4, bone: 4, morph: 4, rigidBody: 4)
        parts.positions = pos
        parts.normals = nrm
        parts.uvs = uv
        parts.indices = indices
        parts.skinIndices = skinI
        parts.skinWeights = skinW
        parts.edgeScale = Array(repeating: 1, count: pos.count / 3)
        var pmx = try parts.build()
        for (k, (target, links)) in ikSpecs.enumerated() {
            let i = ikStart + k
            pmx.bones[i].flags.ik = true
            let toe = links.count == 1
            pmx.bones[i].ik = PMXModel.IK(
                targetIndex: Int32(target), loopCount: toe ? 3 : 40, limitAngle: toe ? 4 : 2,
                links: links.map { b, knee in
                    PMXModel.IKLink(boneIndex: Int32(b), limits: knee
                        ? PMXModel.IKLimit(lower: SIMD3(-.pi, 0, 0), upper: SIMD3(-Math.radians(0.5), 0, 0)) : nil)
                })
        }
        return Converted(pmx: pmx, images: images, mtoon: mtoon, diagnostics: diagnostics, format: format, terms: terms)
    }

    static let labels: [(String, String)] = [
        ("version", String(localized: "Version", bundle: #bundle)), ("authors", String(localized: "Authors", bundle: #bundle)), ("author", String(localized: "Author", bundle: #bundle)), ("copyrightInformation", String(localized: "Copyright", bundle: #bundle)),
        ("contactInformation", String(localized: "Contact", bundle: #bundle)), ("references", String(localized: "References", bundle: #bundle)), ("reference", String(localized: "Reference", bundle: #bundle)),
        ("thirdPartyLicenses", String(localized: "Third-party licenses", bundle: #bundle)), ("avatarPermission", String(localized: "Who can use it as an avatar", bundle: #bundle)),
        ("allowedUserName", String(localized: "Who can use it as an avatar", bundle: #bundle)), ("commercialUsage", String(localized: "Commercial use", bundle: #bundle)), ("commercialUssageName", String(localized: "Commercial use", bundle: #bundle)),
        ("creditNotation", String(localized: "Credit notation", bundle: #bundle)), ("allowRedistribution", String(localized: "Redistribution", bundle: #bundle)), ("modification", String(localized: "Modification", bundle: #bundle)),
        ("allowExcessivelyViolentUsage", String(localized: "Excessive violence", bundle: #bundle)), ("violentUssageName", String(localized: "Violence", bundle: #bundle)),
        ("allowExcessivelySexualUsage", String(localized: "Excessive sexual content", bundle: #bundle)), ("sexualUssageName", String(localized: "Sexual content", bundle: #bundle)),
        ("allowPoliticalOrReligiousUsage", String(localized: "Political or religious use", bundle: #bundle)), ("allowAntisocialOrHateUsage", String(localized: "Antisocial or hate use", bundle: #bundle)),
        ("licenseName", String(localized: "License", bundle: #bundle)), ("licenseUrl", String(localized: "License URL", bundle: #bundle)), ("otherPermissionUrl", String(localized: "Other permission URL", bundle: #bundle)),
        ("otherLicenseUrl", String(localized: "Other license URL", bundle: #bundle)),
    ]

}

extension JSONValue {
    var jsonText: String {
        switch self {
        case .null: "null"
        case let .bool(b): b ? "true" : "false"
        case let .number(d, integer): integer ? String(Int(d)) : "\(d)"
        case let .string(s): "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        case let .array(a): "[" + a.map(\.jsonText).joined(separator: ",") + "]"
        case .object: "{" + entries.map { "\"\($0.0)\":\($0.1.jsonText)" }.joined(separator: ",") + "}"
        }
    }
}
