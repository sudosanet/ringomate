import Foundation
import simd

public enum PropKind: CaseIterable, Sendable {
    case chair, rug, carry, phone, book
    case mug, bottle, iceCream, onigiri, lollipop, flower, balloon, umbrella, fan, teddy, camera, controller
    case magnifier, headphones, toothbrush, comb, paintbrush

    public enum Grip: Sendable { case rightHand, bothHands, head }

    public var grip: Grip? {
        switch self {
        case .teddy, .camera, .controller: .bothHands
        case .headphones: .head
        case .chair, .rug, .carry, .phone, .book: nil
        default: .rightHand
        }
    }

    var boneName: String {
        switch self {
        case .iceCream: "prop_ice_cream"
        default: "prop_" + "\(self)"
        }
    }

    var handMesh: (PropMesh, Float, Bool)? {
        switch self {
        case .mug: (.mug(), 0.06, false)
        case .bottle: (.bottle(), 0.12, false)
        case .iceCream: (.iceCream(), 0.1, false)
        case .onigiri: (.onigiri(), 0.06, true)
        case .lollipop: (.lollipop(), 0.13, false)
        case .flower: (.flower(), 0.13, false)
        case .balloon: (.balloon(), 0.45, false)
        case .umbrella: (.umbrella(), 0.55, false)
        case .fan: (.fan(), 0.16, false)
        case .teddy: (.teddy(), 0.18, true)
        case .camera: (.camera(), 0.08, true)
        case .controller: (.controller(), 0.09, true)
        case .magnifier: (.magnifier(), 0.12, false)
        case .headphones: (.headphones(0.17), 0.15, true)
        case .toothbrush: (.toothbrush(), 0.11, false)
        case .comb: (.comb(), 0.1, false)
        case .paintbrush: (.paintbrush(), 0.12, false)
        default: nil
        }
    }

    static func forGesture(_ name: String) -> PropKind? {
        switch name.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? "" {
        case "sipping-coffee", "hard-days-drink": .mug
        case "drinking-water", "drink-soda": .bottle
        case "eating-sandwich": .onigiri
        case "brushing-teeth": .toothbrush
        case "combing-hair": .comb
        case "painting", "chalkboard": .paintbrush
        case "taking-movie": .camera
        case "holding-baby": .teddy
        case "open-umbrella": .umbrella
        case "violin", "drums", "piano": .headphones
        default: nil
        }
    }
}

enum Props {
    static let files: [(PropKind, String)] = [(.chair, ""), (.rug, "rug_oval_B"), (.carry, "cactus_medium_A"), (.book, ""), (.phone, "")]
    static let texture = "furniturebits_texture.png"

    @discardableResult
    static func attach(_ pmx: inout PMXModel, _ mesh: PropMesh, name: String, anchor: SIMD3<Float>,
                              basis: simd_float3x3, texture: String) -> Int? {
        guard var b = pmx.bones.first, let m0 = pmx.materials.first else { return nil }
        let old = pmx.geometry.positions.count / 3
        let added = mesh.positions.count
        let bone = pmx.bones.count
        b.name = name
        b.englishName = name
        b.parentIndex = -1
        b.position = .zero
        b.tailIndex = -1
        b.tailPosition = .zero
        b.flags.indexedTail = false
        b.flags.rotatable = true
        b.flags.translatable = true
        b.flags.visible = false
        b.flags.enabled = true
        b.flags.ik = false
        b.flags.appendRotate = false
        b.flags.appendTranslate = false
        b.flags.fixedAxis = false
        b.flags.localAxis = false
        b.appendTransform = nil
        b.fixedAxis = nil
        b.localAxis = nil
        b.ik = nil
        pmx.bones.append(b)

        // Z の反転（左手系へ）で表裏が入れ替わるので、三角形の並びも逆にする
        let flip = SIMD3<Float>(1, 1, -1)
        var g = pmx.geometry
        for (p, n) in zip(mesh.positions, mesh.normals) {
            let q = basis * ((p - anchor) * flip)
            let m = Math.normalizeOrZero(basis * (n * flip))
            g.positions += [q.x, q.y, q.z]
            g.normals += [m.x, m.y, m.z]
        }
        g.uvs += mesh.uvs.flatMap { [$0.x, $0.y] }
        for k in g.additionalUVs.indices { g.additionalUVs[k] += Array(repeating: 0, count: added * 4) }
        func grow(_ v: inout [Float], _ fill: Float) {
            if old > 0 && !v.isEmpty { v += Array(repeating: fill, count: added * (v.count / old)) }
        }
        grow(&g.edgeScale, 1)
        grow(&g.sdef.enabled, 0)
        grow(&g.sdef.c, 0)
        grow(&g.sdef.r0, 0)
        grow(&g.sdef.r1, 0)
        grow(&g.sdef.rw0, 0)
        grow(&g.sdef.rw1, 0)
        grow(&g.qdefEnabled, 0)
        if !g.sdef.skinningModes.isEmpty { g.sdef.skinningModes += Array(repeating: "bdef1", count: added) }
        for _ in 0..<added {
            g.skinIndices += [UInt32(bone), 0, 0, 0]
            g.skinWeights += [1, 0, 0, 0]
        }
        var start = g.indices.count
        for t in stride(from: 0, to: mesh.indices.count, by: 3) {
            g.indices += [mesh.indices[t], mesh.indices[t + 2], mesh.indices[t + 1]].map { $0 + UInt32(old) }
        }
        for mat in mesh.materials {
            let color = mat.textured ? SIMD4<Float>(1, 1, 1, 1) : mat.color
            var m = m0
            m.name = "\(name)_\(mat.name)"
            m.englishName = m.name
            m.texturePath = mat.textured ? texture : ""
            m.sphereTexturePath = ""
            m.sphereMode = "none"
            m.toonTexturePath = ""
            m.sharedToonIndex = 0
            m.diffuse = color
            m.specular = .zero
            m.specularPower = 5
            m.ambient = SIMD3(color.x * 0.5, color.y * 0.5, color.z * 0.5)
            m.edgeColor = SIMD4(0.15, 0.1, 0.08, 1)
            m.edgeSize = 0.6
            m.flags.doubleSided = false
            m.flags.edge = true
            m.flags.vertexColor = false
            m.faceCount = Int32(mat.count / 3)
            g.materialGroups.append(PMXModel.MaterialGroup(start: start, count: mat.count, materialIndex: pmx.materials.count))
            pmx.materials.append(m)
            start += mat.count
        }
        pmx.geometry = g
        let vertices = g.positions.count / 3
        let capacity = pmx.metadata.indexSizes.vertex == 1 ? 256 : pmx.metadata.indexSizes.vertex == 2 ? 65536 : Int.max
        if vertices > capacity {
            pmx.metadata.indexSizes.vertex = 4
        }
        pmx.metadata.counts.vertices = vertices
        pmx.metadata.counts.faces = g.indices.count / 3
        pmx.metadata.counts.materials = pmx.materials.count
        pmx.metadata.counts.bones = pmx.bones.count
        return bone
    }

    static func add(to model: inout LoadedModel, library: URL, seat: Float?) {
        let dir = library.deletingLastPathComponent().deletingLastPathComponent().appending(path: "kaykit/addons/kaykit_furniture_bits/Assets/gltf")
        guard let tex = try? Data(contentsOf: dir.appending(path: texture)) else { return }
        let height = stride(from: 1, to: model.pmx.geometry.positions.count, by: 3)
            .reduce(Float(0)) { max($0, model.pmx.geometry.positions[$1]) }
        let reference = "props/\(texture)"
        let firstMaterial = model.pmx.materials.count
        var added = 0
        for (kind, file) in files {
            func read(_ ext: String) -> [UInt8]? { (try? Data(contentsOf: dir.appending(path: "\(file).\(ext)"))).map { [UInt8]($0) } }
            let mesh: PropMesh? = switch kind {
            case .phone: .phone()
            case .chair: .pipeChair()
            case .book: .openBook()
            default: read("gltf").flatMap { j in read("bin").flatMap { try? PropMesh.gltf(json: j, bin: $0) } }
            }
            guard let mesh else { continue }
            let (lo, hi) = mesh.bounds
            let center = (lo + hi) / 2
            let bottom = SIMD3(center.x, lo.y, center.z)
            let identity = matrix_identity_float3x3
            let scale: Float, anchor: SIMD3<Float>, rotation: simd_float3x3
            switch kind {
            case .chair:
                guard let seat else { continue }
                (scale, anchor, rotation) = (seat * 0.95 / PropMesh.pipeChairSeat, bottom, identity)
            case .rug:
                let (sa, ca) = (sin(Float.pi / 2), cos(Float.pi / 2))
                let ry = simd_float3x3(SIMD3(ca, 0, -sa), SIMD3(0, 1, 0), SIMD3(sa, 0, ca))
                (scale, anchor, rotation) = (height * 1.15 / (hi.x - lo.x), bottom,
                                             ry * simd_float3x3(diagonal: SIMD3(1, 0.2, 1)))
            case .carry: (scale, anchor, rotation) = (height * 0.2 / (hi - lo).max(), center, identity)
            case .phone: (scale, anchor, rotation) = (height * 0.1 / (hi.y - lo.y), center, identity)
            case .book: (scale, anchor, rotation) = (height * 0.13 / (hi.y - lo.y), center, identity)
            default: continue
            }
            if attach(&model.pmx, mesh, name: kind.boneName, anchor: anchor, basis: rotation * scale, texture: reference) != nil {
                added += 1
            }
        }
        for kind in PropKind.allCases where kind.grip != nil {
            guard let (mesh, size, centered) = kind.handMesh else { continue }
            let (lo, hi) = mesh.bounds
            let anchor = centered ? (lo + hi) / 2 : SIMD3<Float>.zero
            let scale = height * size / (hi - lo).max()
            if attach(&model.pmx, mesh, name: kind.boneName, anchor: anchor, basis: matrix_identity_float3x3 * scale,
                      texture: reference) != nil {
                added += 1
            }
        }
        guard added > 0 else { return }
        let t = model.addTexture(reference: reference, data: [UInt8](tex))
        while model.materialTextures.count < model.pmx.materials.count { model.materialTextures.append(.init()) }
        for k in firstMaterial..<model.pmx.materials.count {
            model.materialTextures[k].diffuse = model.pmx.materials[k].texturePath == reference ? t : nil
        }
        // 三角形が増えるので、隠れた素体の削除のキャッシュのキーを分ける
        model.key += "-props4"
    }

    static func seatHeight(_ clip: BakedClip, _ pmx: PMXModel) -> Float? {
        guard !clip.frames.isEmpty, let (_, offset) = clip.frames[clip.frames.count / 2].center,
              let pelvis = pmx.bones.first(where: { $0.name == "下半身" }),
              let leg = pmx.bones.first(where: { $0.name == "左足" }) else { return nil }
        return pelvis.position.y + offset.y - leg.position.y * 0.1
    }
}
