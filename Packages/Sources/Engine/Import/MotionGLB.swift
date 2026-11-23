import Foundation
import CMeshopt
import simd

extension BVH {
    public static func writeMotionGLB(_ m: RawMotion) throws -> [UInt8] {
        let frames = m.poses.count
        var bin: [UInt8] = []
        var views: [[String: Any]] = [], accessors: [[String: Any]] = []
        let times = (0..<frames).map { Float($0) / m.fps }
        for t in times { withUnsafeBytes(of: t.bitPattern.littleEndian) { bin += $0 } }
        views.append(["buffer": 0, "byteOffset": 0, "byteLength": bin.count])
        accessors.append(["bufferView": 0, "componentType": 5126, "count": frames, "type": "SCALAR",
                          "min": [0.0], "max": [Double(times.last ?? 0)]])
        var fallback = 0
        func compressed<T>(_ values: [T], stride: Int, filter: String) {
            var data = [UInt8](repeating: 0, count: meshopt_encodeVertexBufferBound(frames, stride))
            let n = values.withUnsafeBytes { v in data.withUnsafeMutableBufferPointer {
                meshopt_encodeVertexBuffer($0.baseAddress, $0.count, v.baseAddress, frames, stride)
            } }
            while bin.count % 4 != 0 { bin.append(0) }
            let at = bin.count
            bin += data[0..<n]
            let raw = frames * stride
            views.append(["buffer": 1, "byteOffset": fallback, "byteLength": raw, "byteStride": stride,
                          "extensions": ["EXT_meshopt_compression": [
                              "buffer": 0, "byteOffset": at, "byteLength": n, "byteStride": stride, "count": frames,
                              "mode": "ATTRIBUTES", "filter": filter]]])
            fallback += (raw + 3) / 4 * 4
        }
        let hips = m.parents.firstIndex { $0 == nil } ?? 0
        var samplers: [[String: Any]] = [], channels: [[String: Any]] = []
        for j in m.names.indices {
            let q = m.poses.flatMap { p in [p[j].1.imag.x, p[j].1.imag.y, p[j].1.imag.z, p[j].1.real] }
            var enc = [Int16](repeating: 0, count: frames * 4)
            enc.withUnsafeMutableBytes { meshopt_encodeFilterQuat($0.baseAddress, frames, 8, 10, q) }
            compressed(enc, stride: 8, filter: "QUATERNION")
            accessors.append(["bufferView": views.count - 1, "componentType": 5122, "normalized": true, "count": frames, "type": "VEC4"])
            samplers.append(["input": 0, "output": accessors.count - 1, "interpolation": "LINEAR"])
            channels.append(["sampler": samplers.count - 1, "target": ["node": j, "path": "rotation"]])
            if j == hips {
                let t = m.poses.flatMap { p in [p[j].0.x, p[j].0.y, p[j].0.z] }
                compressed(t, stride: 12, filter: "NONE")
                accessors.append(["bufferView": views.count - 1, "componentType": 5126, "count": frames, "type": "VEC3"])
                samplers.append(["input": 0, "output": accessors.count - 1, "interpolation": "LINEAR"])
                channels.append(["sampler": samplers.count - 1, "target": ["node": j, "path": "translation"]])
            }
        }
        let nodes: [[String: Any]] = m.names.indices.map { j in
            var n: [String: Any] = ["name": m.names[j], "translation": [m.offsets[j].x, m.offsets[j].y, m.offsets[j].z].map(Double.init)]
            let children = m.names.indices.filter { m.parents[$0] == j }
            if !children.isEmpty { n["children"] = children }
            return n
        }
        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "RingoMate Engine"],
            "extensionsUsed": ["EXT_meshopt_compression"],
            "extensionsRequired": ["EXT_meshopt_compression"],
            "scene": 0, "scenes": [["nodes": m.names.indices.filter { m.parents[$0] == nil }]],
            "nodes": nodes,
            "buffers": [["byteLength": (bin.count + 3) / 4 * 4],
                        ["byteLength": fallback, "extensions": ["EXT_meshopt_compression": ["fallback": true]]]],
            "bufferViews": views,
            "accessors": accessors,
            "animations": [["name": "dance", "samplers": samplers, "channels": channels]],
        ]
        return try GLTFExpand.join(json, bin)
    }
}

extension BVH {
    public static func readMotionGLB(_ bytes: [UInt8]) throws -> RawMotion {
        let glb = try GLB(GLTFExpand.expand(bytes) ?? bytes)
        let json = glb.json
        let nodes = json["nodes"].array ?? []
        let parents = GLB.tree(nodes).parent
        let offsets = nodes.map { SourceClip.decomposed($0).0 }
        guard json["animations"][0].isObject else { throw Invalid(description: "no animation") }
        let anim = json["animations"][0]
        let samplers = anim["samplers"].array ?? []
        var times: [Float] = []
        var rot = [[simd_quatf]?](repeating: nil, count: nodes.count)
        var pos = [[SIMD3<Float>]?](repeating: nil, count: nodes.count)
        for ch in anim["channels"].array ?? [] {
            guard let si = ch["sampler"].uint, si < samplers.count, let j = ch["target"]["node"].uint, j < nodes.count else { continue }
            if times.isEmpty, let input = samplers[si]["input"].uint { times = glb.floats(input, components: 1)?.map { $0[0] } ?? [] }
            guard let output = samplers[si]["output"].uint else { continue }
            switch ch["target"]["path"].string {
            case "rotation": rot[j] = glb.floats(output, components: 4, normalize: true)?.map { simd_quatf(ix: $0[0], iy: $0[1], iz: $0[2], r: $0[3]) }
            case "translation": pos[j] = glb.floats(output, components: 3)?.map { SIMD3($0[0], $0[1], $0[2]) }
            default: break
            }
        }
        let frames = times.count
        guard frames >= 2 else { throw Invalid(description: "too few frames") }
        let fps = Float(frames - 1) / max(times[frames - 1], 1e-6)
        let poses: [[Local]] = (0..<frames).map { k in
            nodes.indices.map { j in
                let p = pos[j].flatMap { k < $0.count ? $0[k] : nil } ?? offsets[j]
                let r = rot[j].flatMap { k < $0.count ? $0[k] : nil } ?? Math.identity
                return (p, simd_normalize(r))
            }
        }
        return RawMotion(names: nodes.map { $0["name"].string ?? "" }, parents: parents, offsets: offsets, fps: fps, poses: poses)
    }
}
