import CUfbx
import Foundation
import simd

enum FBX {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func mat(_ m: ufbx_matrix) -> simd_float4x4 {
        simd_float4x4(SIMD4(Float(m.m00), Float(m.m10), Float(m.m20), 0), SIMD4(Float(m.m01), Float(m.m11), Float(m.m21), 0),
                      SIMD4(Float(m.m02), Float(m.m12), Float(m.m22), 0), SIMD4(Float(m.m03), Float(m.m13), Float(m.m23), 1))
    }

    static func v3(_ v: ufbx_vec3) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }

    static func string(_ s: ufbx_string) -> String {
        s.data == nil ? "" : String(decoding: UnsafeRawBufferPointer(start: s.data, count: s.length), as: UTF8.self)
    }

    static func list<T>(_ data: UnsafeMutablePointer<T>?, _ count: Int) -> [T] {
        data.map { Array(UnsafeBufferPointer(start: $0, count: count)) } ?? []
    }

    static func rotationTranslation(_ m: simd_float4x4) -> (simd_quatf, SIMD3<Float>) {
        let (_, r, t) = Math.scaleRotationTranslation(m)
        return (r, t)
    }

    static func glb(_ bytes: [UInt8], read: (String) -> [UInt8]?) throws -> [UInt8] {
        var opts = ufbx_load_opts()
        opts.target_axes = ufbx_axes_right_handed_y_up
        opts.target_unit_meters = 1
        opts.space_conversion = UFBX_SPACE_CONVERSION_MODIFY_GEOMETRY
        opts.generate_missing_normals = true
        var error = ufbx_error()
        guard let scene = bytes.withUnsafeBytes({ ufbx_load_memory($0.baseAddress, $0.count, &opts, &error) }) else {
            throw Failure(description: "fbx: \(string(error.description))")
        }
        defer { ufbx_free_scene(scene) }
        var bin = GLBBuilder()
        let nodes = list(scene.pointee.nodes.data, scene.pointee.nodes.count).compactMap { $0 }.filter { !$0.pointee.is_root }
        let index = Dictionary(nodes.enumerated().map { ($1.pointee.element_id, $0) }, uniquingKeysWith: { a, _ in a })
        func parentOf(_ n: UnsafeMutablePointer<ufbx_node>) -> Int? { n.pointee.parent.flatMap { index[$0.pointee.element_id] } }
        var gnodes: [[String: Any]] = nodes.map { n in
            let (s, r, t) = Math.scaleRotationTranslation(mat(n.pointee.node_to_parent))
            let q = r.normalized
            return ["name": string(n.pointee.name), "translation": [t.x, t.y, t.z], "rotation": [q.imag.x, q.imag.y, q.imag.z, q.real],
                    "scale": [s.x, s.y, s.z]]
        }
        var roots: [Int] = []
        for (i, n) in nodes.enumerated() {
            if let p = parentOf(n) {
                gnodes[p]["children"] = (gnodes[p]["children"] as? [Int] ?? []) + [i]
            } else {
                roots.append(i)
            }
        }

        var images: [[String: Any]] = [], textures: [[String: Any]] = []
        var textureOf: [UInt32: Int] = [:]
        func texture(_ t: UnsafeMutablePointer<ufbx_texture>) -> Int? {
            if let i = textureOf[t.pointee.element_id] { return i }
            let data: [UInt8]
            if t.pointee.content.size > 0, let p = t.pointee.content.data {
                data = Array(UnsafeRawBufferPointer(start: p, count: t.pointee.content.size))
            } else {
                guard let d = [string(t.pointee.relative_filename), string(t.pointee.filename)].lazy
                    .filter({ !$0.isEmpty }).compactMap(read).first else { return nil }
                data = d
            }
            let mime: String
            if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { mime = "image/png" } else if data.starts(with: [0xff, 0xd8]) { mime = "image/jpeg" } else { return nil }
            let view = bin.view(data, target: nil)
            images.append(["bufferView": view, "mimeType": mime, "name": string(t.pointee.name)])
            textures.append(["source": images.count - 1])
            textureOf[t.pointee.element_id] = textures.count - 1
            return textures.count - 1
        }

        var materials: [[String: Any]] = []
        var materialOf: [UInt32: Int] = [:]
        var meshes: [[String: Any]] = []
        var skins: [[String: Any]] = []
        var tris = [UInt32](repeating: 0, count: 64)
        for (ni, node) in nodes.enumerated() {
            guard let mesh = node.pointee.mesh else { continue }
            let m = mesh.pointee
            let geo = mat(node.pointee.geometry_to_world)
            let nm = Math.mat3(geo).inverse.transpose
            let skin = m.skin_deformers.count > 0 ? m.skin_deformers.data[0] : nil
            var pos: [Float] = [], nrm: [Float] = [], uv: [Float] = []
            var joints: [UInt8] = [], weights: [Float] = []
            var cornerVertex: [Int] = []
            var parts: [(Int, [UInt32])] = []
            let faceMaterial = list(m.face_material.data, m.face_material.count)
            for (fi, face) in list(m.faces.data, m.faces.count).enumerated() {
                let need = (max(Int(face.num_indices), 3) - 2) * 3
                if tris.count < need { tris += Array(repeating: 0, count: need - tris.count) }
                let n = Int(tris.withUnsafeMutableBufferPointer { ufbx_triangulate_face($0.baseAddress, $0.count, mesh, face) }) * 3
                let mi = fi < faceMaterial.count ? Int(faceMaterial[fi]) : 0
                let part = parts.firstIndex { $0.0 == mi } ?? { parts.append((mi, [])); return parts.count - 1 }()
                for corner in tris[0..<n] {
                    let c = Int(corner)
                    let base = UInt32(pos.count / 3)
                    let vp = m.vertex_position
                    let p = Math.point(geo, v3(vp.values.data[Int(vp.indices.data[c])]))
                    var nn = SIMD3<Float>(0, 1, 0)
                    if m.vertex_normal.exists {
                        let vn = m.vertex_normal
                        nn = Math.normalize(nm * v3(vn.values.data[Int(vn.indices.data[c])]), or: SIMD3(0, 1, 0))
                    }
                    pos += [p.x, p.y, p.z]
                    nrm += [nn.x, nn.y, nn.z]
                    if m.vertex_uv.exists {
                        let t = m.vertex_uv.values.data[Int(m.vertex_uv.indices.data[c])]
                        uv += [Float(t.x), 1 - Float(t.y)]
                    } else {
                        uv += [0, 0]
                    }
                    let vi = Int(m.vertex_indices.data[c])
                    cornerVertex.append(vi)
                    var j: [UInt16] = [0, 0, 0, 0], w: [Float] = [0, 0, 0, 0]
                    if let sk = skin, vi < sk.pointee.vertices.count {
                        let sv = sk.pointee.vertices.data[vi]
                        for k in 0..<min(Int(sv.num_weights), 4) {
                            let sw = sk.pointee.weights.data[Int(sv.weight_begin) + k]
                            j[k] = UInt16(truncatingIfNeeded: sw.cluster_index)
                            w[k] = Float(sw.weight)
                        }
                    }
                    let sum = w.reduce(0, +)
                    w = sum > 0 ? w.map { $0 / sum } : [1, 0, 0, 0]
                    for x in j { joints += [UInt8(x & 0xff), UInt8(x >> 8)] }
                    weights += w
                    parts[part].1.append(base)
                }
            }
            if pos.isEmpty { continue }
            var attrs: [String: Any] = ["POSITION": bin.floats(pos, "VEC3", minmax: true), "NORMAL": bin.floats(nrm, "VEC3"),
                                        "TEXCOORD_0": bin.floats(uv, "VEC2")]
            if let sk = skin {
                let jv = bin.view(joints, target: 34962)
                attrs["JOINTS_0"] = bin.accessor(["bufferView": jv, "componentType": 5123, "count": pos.count / 3, "type": "VEC4"])
                attrs["WEIGHTS_0"] = bin.floats(weights, "VEC4")
                let clusters = list(sk.pointee.clusters.data, sk.pointee.clusters.count).compactMap { $0 }
                let jointNodes = clusters.map { c in c.pointee.bone_node.flatMap { index[$0.pointee.element_id] } ?? ni }
                let ibm = clusters.flatMap { c -> [Float] in
                    let inv = mat(c.pointee.bind_to_world).inverse
                    return (0..<4).flatMap { k in [inv[k].x, inv[k].y, inv[k].z, inv[k].w] }
                }
                skins.append(["joints": jointNodes, "inverseBindMatrices": bin.floats(ibm, "MAT4")])
            }
            var targets: [[String: Any]] = [], targetNames: [String] = []
            let m3 = Math.mat3(geo)
            for bd in list(m.blend_deformers.data, m.blend_deformers.count).compactMap({ $0 }) {
                for ch in list(bd.pointee.channels.data, bd.pointee.channels.count).compactMap({ $0 }) {
                    let keys = list(ch.pointee.keyframes.data, ch.pointee.keyframes.count)
                    guard let shape = ch.pointee.target_shape ?? keys.last?.shape else { continue }
                    let s = shape.pointee
                    let ov = list(s.offset_vertices.data, s.offset_vertices.count)
                    let po = list(s.position_offsets.data, s.position_offsets.count)
                    var offs: [Int: SIMD3<Float>] = [:]
                    for (v, d) in zip(ov, po) { offs[Int(v)] = m3 * v3(d) }
                    let hits = cornerVertex.enumerated().compactMap { c, v in offs[v].map { (UInt32(c), $0) } }
                    if hits.isEmpty { continue }
                    var ib: [UInt8] = [], vb: [UInt8] = []
                    for (c, d) in hits {
                        ib += withUnsafeBytes(of: c.littleEndian) { Array($0) }
                        for f in [d.x, d.y, d.z] { vb += withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) } }
                    }
                    let iv = bin.view(ib, target: nil), vv = bin.view(vb, target: nil)
                    targets.append(["POSITION": bin.accessor([
                        "componentType": 5126, "count": pos.count / 3, "type": "VEC3",
                        "sparse": ["count": hits.count, "indices": ["bufferView": iv, "componentType": 5125], "values": ["bufferView": vv]],
                    ])])
                    targetNames.append(string(ch.pointee.name))
                }
            }
            var primitives: [[String: Any]] = []
            let meshMaterials = list(m.materials.data, m.materials.count)
            for (mi, idx) in parts {
                let iv = bin.view(idx.flatMap { i in withUnsafeBytes(of: i.littleEndian) { Array($0) } }, target: 34963)
                let aIdx = bin.accessor(["bufferView": iv, "componentType": 5125, "count": idx.count, "type": "SCALAR"])
                var material: Int?
                if mi < meshMaterials.count, let mat = meshMaterials[mi] {
                    if let k = materialOf[mat.pointee.element_id] {
                        material = k
                    } else {
                        let d = mat.pointee.fbx.diffuse_color, fac = mat.pointee.fbx.diffuse_factor
                        let f: Float = fac.has_value ? Float(fac.value_vec4.x) : 1
                        var c: [Float] = d.has_value
                            ? [Float(d.value_vec4.x) * f, Float(d.value_vec4.y) * f, Float(d.value_vec4.z) * f, 1] : [1, 1, 1, 1]
                        var pbr: [String: Any] = ["metallicFactor": 0.0, "roughnessFactor": 0.9]
                        if let t = d.texture.flatMap(texture) {
                            pbr["baseColorTexture"] = ["index": t]
                            c = [1, 1, 1, 1]
                        }
                        pbr["baseColorFactor"] = c
                        materials.append(["name": string(mat.pointee.name), "pbrMetallicRoughness": pbr, "alphaMode": "MASK",
                                          "alphaCutoff": 0.5])
                        materialOf[mat.pointee.element_id] = materials.count - 1
                        material = materials.count - 1
                    }
                }
                var prim: [String: Any] = ["attributes": attrs, "indices": aIdx]
                if let material { prim["material"] = material }
                if !targets.isEmpty { prim["targets"] = targets }
                primitives.append(prim)
            }
            meshes.append(["name": string(node.pointee.name), "primitives": primitives, "extras": ["targetNames": targetNames]])
            var mnode: [String: Any] = ["name": "\(string(node.pointee.name))_mesh", "mesh": meshes.count - 1]
            if skin != nil { mnode["skin"] = skins.count - 1 }
            gnodes.append(mnode)
            roots.append(gnodes.count - 1)
        }
        if meshes.isEmpty { throw Failure(description: "fbx: no mesh") }

        var animations: [[String: Any]] = []
        for stack in list(scene.pointee.anim_stacks.data, scene.pointee.anim_stacks.count).compactMap({ $0 }) {
            let (t0, t1) = (stack.pointee.time_begin, stack.pointee.time_end)
            guard t1 > t0 else { continue }
            let frames = min(max(Int(((t1 - t0) * 30).rounded(.up)), 2), 30 * 600)
            let times = (0..<frames).map { Float($0) / 30 }
            var rot = [[simd_quatf]](repeating: [], count: nodes.count), tra = [[SIMD3<Float>]](repeating: [], count: nodes.count)
            for t in times {
                var err = ufbx_error()
                guard let ev = ufbx_evaluate_scene(scene, stack.pointee.anim, t0 + Double(t), nil, &err) else { break }
                defer { ufbx_free_scene(ev) }
                var byID: [UInt32: ufbx_matrix] = [:]
                for n in list(ev.pointee.nodes.data, ev.pointee.nodes.count).compactMap({ $0 }) { byID[n.pointee.element_id] = n.pointee.node_to_parent }
                for (i, n) in nodes.enumerated() {
                    let (r, p) = rotationTranslation(mat(byID[n.pointee.element_id] ?? n.pointee.node_to_parent))
                    rot[i].append(r.normalized)
                    tra[i].append(p)
                }
            }
            guard rot.first?.count == times.count else { continue }
            let aTime = bin.floats(times, "SCALAR")
            bin.accessors[aTime]["min"] = [0.0]
            bin.accessors[aTime]["max"] = [times[times.count - 1]]
            var channels: [[String: Any]] = [], samplers: [[String: Any]] = []
            for i in nodes.indices {
                let r = rot[i].flatMap { [$0.imag.x, $0.imag.y, $0.imag.z, $0.real] }
                let p = tra[i].flatMap { [$0.x, $0.y, $0.z] }
                for (path, out) in [("rotation", bin.floats(r, "VEC4")), ("translation", bin.floats(p, "VEC3"))] {
                    samplers.append(["input": aTime, "output": out, "interpolation": "LINEAR"])
                    channels.append(["sampler": samplers.count - 1, "target": ["node": i, "path": path]])
                }
            }
            animations.append(["name": string(stack.pointee.name), "channels": channels, "samplers": samplers])
        }

        var doc: [String: Any] = ["asset": ["version": "2.0", "generator": "RingoMate fbx"], "scene": 0,
                                  "scenes": [["nodes": roots]], "nodes": gnodes, "meshes": meshes, "materials": materials]
        if !skins.isEmpty { doc["skins"] = skins }
        if !images.isEmpty {
            doc["images"] = images
            doc["textures"] = textures
        }
        if !animations.isEmpty { doc["animations"] = animations }
        return try bin.glb(doc)
    }
}

struct GLBBuilder {
    var data: [UInt8] = []
    var views: [[String: Any]] = []
    var accessors: [[String: Any]] = []

    mutating func view(_ bytes: [UInt8], target: Int?) -> Int {
        while data.count % 4 != 0 { data.append(0) }
        var v: [String: Any] = ["buffer": 0, "byteOffset": data.count, "byteLength": bytes.count]
        if let target { v["target"] = target }
        data += bytes
        views.append(v)
        return views.count - 1
    }

    mutating func floats(_ v: [Float], _ kind: String, minmax: Bool = false) -> Int {
        let view = self.view(v.flatMap { f in withUnsafeBytes(of: f.bitPattern.littleEndian) { Array($0) } }, target: 34962)
        let n = ["VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16][kind] ?? 1
        var a: [String: Any] = ["bufferView": view, "componentType": 5126, "count": v.count / n, "type": kind]
        if minmax, n == 3, !v.isEmpty {
            var lo = [Float](repeating: .greatestFiniteMagnitude, count: 3), hi = [Float](repeating: -.greatestFiniteMagnitude, count: 3)
            for i in stride(from: 0, to: v.count, by: 3) { for k in 0..<3 { lo[k] = min(lo[k], v[i + k]); hi[k] = max(hi[k], v[i + k]) } }
            a["min"] = lo
            a["max"] = hi
        }
        accessors.append(a)
        return accessors.count - 1
    }

    mutating func accessor(_ a: [String: Any]) -> Int {
        accessors.append(a)
        return accessors.count - 1
    }

    func glb(_ doc: [String: Any]) throws -> [UInt8] {
        var d = doc
        var bin = data
        while bin.count % 4 != 0 { bin.append(0) }
        d["buffers"] = [["byteLength": bin.count]]
        d["bufferViews"] = views
        d["accessors"] = accessors
        return try GLTFExpand.join(d, bin)
    }
}
