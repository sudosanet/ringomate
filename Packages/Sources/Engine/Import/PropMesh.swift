import simd

/// glTF の座標、メートル。
struct PropMesh {
    public var positions: [SIMD3<Float>] = []
    public var normals: [SIMD3<Float>] = []
    public var uvs: [SIMD2<Float>] = []
    public var indices: [UInt32] = []
    public var materials: [Material] = []

    public struct Material {
        public var name: String
        public var color: SIMD4<Float>
        public var count: Int
        public var textured: Bool
    }

    public var bounds: (SIMD3<Float>, SIMD3<Float>) {
        positions.reduce((SIMD3(repeating: .greatestFiniteMagnitude), SIMD3(repeating: -.greatestFiniteMagnitude))) {
            (simd_min($0.0, $1), simd_max($0.1, $1))
        }
    }

    /// 表は `u × v` の向き。
    mutating func quad(_ c: SIMD3<Float>, _ u: SIMD3<Float>, _ v: SIMD3<Float>) {
        let cr = simd_cross(u, v)
        let n = cr * (1 / simd_length(cr))
        let base = UInt32(positions.count)
        for (a, b) in [(Float(-1), Float(-1)), (1, -1), (1, 1), (-1, 1)] {
            positions.append(c + u * a + v * b)
            normals.append(n)
            uvs.append(.zero)
        }
        indices += [base, base + 1, base + 2, base, base + 2, base + 3]
    }

    mutating func cuboid(_ c: SIMD3<Float>, _ h: SIMD3<Float>) {
        let x = SIMD3<Float>(1, 0, 0), y = SIMD3<Float>(0, 1, 0), z = SIMD3<Float>(0, 0, 1)
        for axis in 0..<3 {
            for sign: Float in [-1, 1] {
                var n = SIMD3<Float>.zero
                n[axis] = sign
                let (u0, v) = axis == 0 ? (y, z) : axis == 1 ? (z, x) : (x, y)
                let u = simd_dot(simd_cross(u0, v), n) > 0 ? u0 : -u0
                quad(c + n * h, u * h, v * h)
            }
        }
    }

    mutating func material(_ name: String, _ color: SIMD3<Float>) {
        let done = materials.reduce(0) { $0 + $1.count }
        materials.append(Material(name: name, color: SIMD4(color, 1), count: indices.count - done, textured: false))
    }

    mutating func transform(from start: Int, _ rot: simd_quatf, _ offset: SIMD3<Float>) {
        for i in start..<positions.count {
            positions[i] = rot.act(positions[i]) + offset
            normals[i] = rot.act(normals[i])
        }
    }

    static func rotation(x a: Float) -> simd_quatf { simd_quatf(ix: sin(a / 2), iy: 0, iz: 0, r: cos(a / 2)) }
    static func rotation(y a: Float) -> simd_quatf { simd_quatf(ix: 0, iy: sin(a / 2), iz: 0, r: cos(a / 2)) }
    static func rotation(z a: Float) -> simd_quatf { simd_quatf(ix: 0, iy: 0, iz: sin(a / 2), r: cos(a / 2)) }

    mutating func cylinder(_ c: SIMD3<Float>, _ r: Float, _ rTop: Float, _ h: Float, _ segments: UInt32) {
        let base = UInt32(positions.count)
        func ring(_ k: UInt32, _ y: Float, _ rr: Float) -> SIMD3<Float> {
            let a = Float(k) / Float(segments) * (2 * .pi)
            return c + SIMD3(cos(a) * rr, y, sin(a) * rr)
        }
        for k in 0...segments {
            let a = Float(k) / Float(segments) * (2 * .pi)
            let raw = SIMD3(cos(a), (r - rTop) / max(h, 1e-6), sin(a))
            let n = raw * (1 / simd_length(raw))
            for (y, rr) in [(Float(0), r), (h, rTop)] {
                positions.append(ring(k, y, rr))
                normals.append(n)
                uvs.append(.zero)
            }
        }
        for k in 0..<segments {
            let (a, b) = (base + k * 2, base + k * 2 + 2)
            indices += [a, a + 1, b, b, a + 1, b + 1]
        }
        for (y, rr, n) in [(Float(0), r, SIMD3<Float>(0, -1, 0)), (h, rTop, SIMD3<Float>(0, 1, 0))] where rr > 0 {
            let center = UInt32(positions.count)
            positions.append(c + SIMD3(0, 1, 0) * y)
            normals.append(n)
            uvs.append(.zero)
            for k in 0...segments {
                positions.append(ring(k, y, rr))
                normals.append(n)
                uvs.append(.zero)
            }
            for k in 0..<segments {
                let (p, q) = (center + 1 + k, center + 2 + k)
                indices += n.y > 0 ? [center, q, p] : [center, p, q]
            }
        }
    }

    mutating func sphere(_ c: SIMD3<Float>, _ r: Float, _ scale: SIMD3<Float>) {
        let (rings, segs): (UInt32, UInt32) = (10, 14)
        let base = UInt32(positions.count)
        for i in 0...rings {
            let v = Float(i) / Float(rings) * .pi
            for k in 0...segs {
                let u = Float(k) / Float(segs) * (2 * .pi)
                let n = SIMD3(sin(v) * cos(u), cos(v), sin(v) * sin(u))
                positions.append(c + n * r * scale)
                let ns = n / scale
                normals.append(ns * (1 / simd_length(ns)))
                uvs.append(.zero)
            }
        }
        for i in 0..<rings {
            for k in 0..<segs {
                let a = base + i * (segs + 1) + k, b = a + segs + 1
                indices += [a, a + 1, b, b, a + 1, b + 1]
            }
        }
    }

    static let pipeChairSeat: Float = 0.455

    public static func gltf(json data: [UInt8], bin: [UInt8]) throws -> PropMesh {
        let json = try JSONValue.parse(data)
        struct Bad: Error {}
        func accessor(_ i: JSONValue, _ size: Int) throws -> (Int, Int, Int, Int) {
            guard let ai = i.uint else { throw Bad() }
            let a = json["accessors"][ai]
            guard let vi = a["bufferView"].uint else { throw Bad() }
            let view = json["bufferViews"][vi]
            return ((view["byteOffset"].uint ?? 0) + (a["byteOffset"].uint ?? 0), a["count"].uint ?? 0,
                    a["componentType"].uint ?? 0, view["byteStride"].uint ?? size)
        }
        func floats(_ i: JSONValue, _ n: Int) throws -> [[Float]] {
            let (o, count, _, stride) = try accessor(i, n * 4)
            return try (0..<count).map { k in
                try (0..<n).map { j in
                    let at = o + k * stride + j * 4
                    guard at + 4 <= bin.count else { throw Bad() }
                    return Float(bitPattern: le32(bin, at))
                }
            }
        }
        let scale = json["nodes"][0]["scale"].array.flatMap { s in s.count < 3 ? nil : SIMD3((0..<3).map { Float(s[$0].double ?? 1) }) }
            ?? SIMD3<Float>(1, 1, 1)
        var mesh = PropMesh()
        guard let prims = json["meshes"][0]["primitives"].array else { throw Bad() }
        for prim in prims {
            let attrs = prim["attributes"]
            let base = UInt32(mesh.positions.count)
            let ps = try floats(attrs["POSITION"], 3)
            mesh.positions += ps.map { SIMD3($0[0], $0[1], $0[2]) * scale }
            mesh.normals += try floats(attrs["NORMAL"], 3).map { SIMD3($0[0], $0[1], $0[2]) }
            mesh.uvs += attrs["TEXCOORD_0"].isNull ? Array(repeating: .zero, count: ps.count)
                : try floats(attrs["TEXCOORD_0"], 2).map { SIMD2($0[0], $0[1]) }
            let (o, count, kind, _) = try accessor(prim["indices"], 0)
            let size = kind == 5125 ? 4 : 2
            for k in 0..<count {
                guard o + (k + 1) * size <= bin.count else { throw Bad() }
                mesh.indices.append(base + (size == 4 ? le32(bin, o + k * size) : UInt32(le16(bin, o + k * size))))
            }
            let m = json["materials"][prim["material"].uint ?? 0]
            let pbr = m["pbrMetallicRoughness"], c = pbr["baseColorFactor"]
            mesh.materials.append(Material(name: m["name"].string ?? "prop",
                                           color: SIMD4((0..<4).map { Float(c[$0].double ?? 1) }), count: count,
                                           textured: !pbr["baseColorTexture"].isNull))
        }
        return mesh
    }
}

extension JSONValue {
    var isNull: Bool { if case .null = self { true } else { false } }
}
