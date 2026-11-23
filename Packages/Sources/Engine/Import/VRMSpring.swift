import simd

/// ponytail: 硬さ・抵抗はジョイントの回転の範囲・ばね・減衰へ目分量で写す。gravityPower は使わない。
enum VRMSpring {
    static let springGroup: UInt8 = 14, colliderGroup: UInt8 = 13, anchorGroup: UInt8 = 15
    static let rootMass: Float = 10, massDecay: Float = 0.5
    static let bendDegrees: Float = 4, springPerStiffness: Float = 20

    struct Spring {
        var node: Int, parent: Int?, tail: Int, depth: Int
        var stiffness: Float, drag: Float, radius: Float
        var groups: [Int]
    }

    struct Input {
        var spring: JSONValue
        var v1: Bool
        var children: [[Int]]
        var world: [simd_float4x4]
        var toMMD: (SIMD3<Float>) -> SIMD3<Float>
        var scale: Float
        var boneOf: (Int) -> Int
        var fastLimb: (Int) -> Bool

        func parentOf(_ n: Int) -> Int { children.firstIndex { $0.contains(n) } ?? n }
    }

    static func vec(_ v: JSONValue) -> SIMD3<Float> {
        v.isArray ? SIMD3(v[0].f, v[1].f, v[2].f) : SIMD3(v["x"].f, v["y"].f, v["z"].f)
    }

    static func indices(_ v: JSONValue) -> [Int] { (v.array ?? []).compactMap(\.uint) }

    static func pmxGroup(_ g: Int) -> UInt8 { UInt8(g % 12) }

    static func springs(_ inp: Input) -> [Spring] {
        var out: [Spring] = []
        if inp.v1 {
            for s in inp.spring["springs"].array ?? [] {
                let joints = s["joints"].array ?? []
                let groups = indices(s["colliderGroups"])
                for k in 0..<max(joints.count - 1, 0) {
                    let j = joints[k]
                    out.append(Spring(node: j["node"].uint ?? 0, parent: k > 0 ? joints[k - 1]["node"].uint ?? 0 : nil,
                                      tail: joints[k + 1]["node"].uint ?? 0, depth: k, stiffness: j["stiffness"].f,
                                      drag: j["dragForce"].f, radius: j["hitRadius"].f, groups: groups))
                }
            }
        } else {
            for g in inp.spring["boneGroups"].array ?? [] {
                let groups = indices(g["colliderGroups"])
                for root in g["bones"].array ?? [] {
                    var stack: [(Int, Int?, Int)] = [(root.uint ?? 0, nil, 0)]
                    while let (n, parent, depth) = stack.popLast() {
                        guard n < inp.children.count, let tail = inp.children[n].first else { continue }
                        out.append(Spring(node: n, parent: parent, tail: tail, depth: depth, stiffness: g["stiffiness"].f,
                                          drag: g["dragForce"].f, radius: g["hitRadius"].f, groups: groups))
                        stack += inp.children[n].map { ($0, n, depth + 1) }
                    }
                }
            }
        }
        var seen = Set<Int>()
        let count = inp.world.count
        return out.filter { $0.node < count && $0.tail < count && ($0.parent ?? 0) < count && seen.insert($0.node).inserted }
    }

    /// Ry·Rx·Rz のオイラー角 [x, y, z]。
    static func capsuleRotation(_ dir: SIMD3<Float>) -> SIMD3<Float> {
        Math.eulerYXZ(Math.rotationArc(SIMD3(0, 1, 0), Math.normalize(dir, or: SIMD3(0, 1, 0))))
    }

    static func body(_ name: String, _ bone: Int, _ shape: String, _ size: SIMD3<Float>, _ pos: SIMD3<Float>) -> PMXModel.RigidBody {
        var b = PMXModel.RigidBody()
        b.name = name
        b.boneIndex = Int32(bone)
        b.group = colliderGroup
        b.mask = 1 << springGroup
        b.shape = shape
        b.size = size
        b.position = pos
        b.rotation = .zero
        b.mass = 1
        b.linearDamping = 0.5
        b.angularDamping = 0.5
        b.restitution = 0
        b.friction = 0.5
        b.mode = "static"
        return b
    }

    static func collider(_ i: Int, _ bone: Int, _ r: Float, _ a: SIMD3<Float>, _ b: SIMD3<Float>) -> PMXModel.RigidBody {
        if simd_distance(a, b) < 1e-4 { return body("collider\(i)", bone, "sphere", SIMD3(r, 0, 0), a) }
        var d = body("collider\(i)", bone, "capsule", SIMD3(r, simd_distance(a, b), 0), (a + b) / 2)
        d.rotation = capsuleRotation(b - a)
        return d
    }

    static func convert(_ inp: Input) -> ([PMXModel.RigidBody], [PMXModel.Joint]) {
        func pos(_ n: Int) -> SIMD3<Float> { inp.toMMD(inp.world[n].columns.3.xyz) }
        var bodies: [PMXModel.RigidBody] = []
        var joints: [PMXModel.Joint] = []
        var groupOfCollider: [Int?] = []
        var groupMasks: [UInt16] = []
        if inp.v1 {
            let colliders = inp.spring["colliders"].array ?? []
            groupOfCollider = Array(repeating: nil, count: colliders.count)
            for (g, cg) in (inp.spring["colliderGroups"].array ?? []).enumerated() {
                for c in indices(cg["colliders"]) where c < groupOfCollider.count && groupOfCollider[c] == nil {
                    groupOfCollider[c] = g
                }
            }
            for (i, c) in colliders.enumerated() {
                let n = c["node"].uint ?? 0
                guard n < inp.world.count else { continue }
                func at(_ o: JSONValue) -> SIMD3<Float> { inp.toMMD(Math.point(inp.world[n], vec(o))) }
                let shape = c["shape"]
                let (r, a, b): (Float, SIMD3<Float>, SIMD3<Float>)
                if shape["capsule"].isObject {
                    let s = shape["capsule"]
                    (r, a, b) = (s["radius"].f, at(s["offset"]), at(s["tail"]))
                } else {
                    let s = shape["sphere"]
                    let p = at(s["offset"])
                    (r, a, b) = (s["radius"].f, p, p)
                }
                var d = collider(bodies.count, inp.boneOf(n), r * inp.scale, a, b)
                d.group = (i < groupOfCollider.count ? groupOfCollider[i] : nil).map(pmxGroup) ?? 12
                bodies.append(d)
            }
            for cg in inp.spring["colliderGroups"].array ?? [] {
                groupMasks.append(indices(cg["colliders"]).compactMap { $0 < groupOfCollider.count ? groupOfCollider[$0] : nil }
                    .reduce(0) { $0 | 1 << pmxGroup($1) })
            }
        } else {
            for (gi, g) in (inp.spring["colliderGroups"].array ?? []).enumerated() {
                groupMasks.append(1 << pmxGroup(gi))
                let n = g["node"].uint ?? 0
                guard n < inp.world.count else { continue }
                // 腕・手のコライダーは使わない（剛体の硬い押し返しでスカートが跳ねる）
                if inp.fastLimb(n) { continue }
                for c in g["colliders"].array ?? [] {
                    let o = vec(c["offset"]) * SIMD3(-1, 1, 1)
                    let p = inp.toMMD(Math.point(inp.world[n], o))
                    var d = collider(bodies.count, inp.boneOf(n), c["radius"].f * inp.scale * 0.7, p, p)
                    d.group = pmxGroup(gi)
                    bodies.append(d)
                }
            }
        }

        let list = springs(inp)
        var bodyOf: [Int: Int] = [:]
        var anchorOf: [Int: Int] = [:]
        for s in list {
            let (a, b) = (pos(s.node), pos(s.tail))
            let len = simd_distance(a, b)
            let r = max(s.radius * inp.scale * 0.4, 0.05)
            var d = body("spring\(bodyOf.count)", inp.boneOf(s.node), "capsule", SIMD3(r, max(len, 0.01), 0), (a + b) / 2)
            d.rotation = capsuleRotation(b - a)
            d.group = springGroup
            d.mask = s.groups.compactMap { $0 < groupMasks.count ? groupMasks[$0] : nil }.reduce(0, |)
            d.mode = "dynamicBone"
            d.angularDamping = min(0.5 + 0.45 * s.drag, 0.99)
            d.mass = rootMass * pow(massDecay, Float(s.depth))
            bodyOf[s.node] = bodies.count
            bodies.append(d)
        }
        for s in list {
            let other: Int
            if let p = s.parent, let b = bodyOf[p] {
                other = b
            } else {
                let bone = inp.boneOf(inp.parentOf(s.node))
                if let a = anchorOf[bone] {
                    other = a
                } else {
                    var d = body("anchor\(bone)", bone, "sphere", SIMD3(0.05, 0, 0), pos(s.node))
                    d.group = anchorGroup
                    d.mask = 0
                    bodies.append(d)
                    anchorOf[bone] = bodies.count - 1
                    other = bodies.count - 1
                }
            }
            let limit = Math.radians(bendDegrees / (1 + s.stiffness))
            var j = PMXModel.Joint()
            j.name = "joint\(joints.count)"
            j.kind = "generic6dofSpring"
            j.rigidBodyIndexA = Int32(other)
            j.rigidBodyIndexB = Int32(bodyOf[s.node]!)
            j.position = pos(s.node)
            j.rotationLowerLimit = SIMD3(repeating: -limit)
            j.rotationUpperLimit = SIMD3(repeating: limit)
            j.springRotationFactor = SIMD3(repeating: s.stiffness * springPerStiffness)
            joints.append(j)
        }
        return (bodies, joints)
    }
}
