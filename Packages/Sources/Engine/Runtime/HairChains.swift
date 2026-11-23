import Foundation
import simd

struct HairChains {
    struct Tuning {
        var stiff: Float = 30, tip: Float = 0.15, world: Float = 0.5, damp: Float = 4, dampTip: Float = 1
        var substeps: Int = 8, cone: Float = 70, soft: Float = 1
        /// 0 で切る。
        var hit: Float = 1
        /// 点の半径に対する比。
        var push: Float = 0.1

        static func fromEnvironment() -> Tuning {
            var t = Tuning()
            guard let v = Flags.value("MASCOT_HAIR") else { return t }
            for part in v.split(separator: ",") {
                let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard kv.count == 2, let x = Float(kv[1]) else { continue }
                switch kv[0] {
                case "stiff": t.stiff = x
                case "tip": t.tip = x
                case "world": t.world = x
                case "damp": t.damp = x
                case "damptip": t.dampTip = x
                case "substeps": t.substeps = max(Int(x), 1)
                case "cone": t.cone = x
                case "soft": t.soft = max(x, 0.05)
                case "hit": t.hit = x
                case "push": t.push = x
                default: break
                }
            }
            return t
        }
    }

    struct Chain {
        var bones: [Int]
        var parent: Int
        var rest: [SIMD3<Float>]
        var dir: [SIMD3<Float>], len: [Float]
        var radius: [Float], stiff: [Float], damp: [Float]
        var cone: [Float] = []
        var locked: [Bool] = []
        var rods: [(root: Int, tip: Int, cone: Float)] = []
        var hits: [Int]
        /// 点ごと・当たりの番号ごとの押し出しの上限（ない値は nan）。
        var allow: [[Float]] = []
        var p: [SIMD3<Float>] = [], prev: [SIMD3<Float>] = []
        var lastRoot: SIMD3<Float>?
    }

    struct Collider {
        var bone: Int
        var a: SIMD3<Float>, b: SIMD3<Float>, r: Float
        var group: UInt16
        /// 物理で揺れる剛体。位置は解いたあとの骨から取る。
        var moving = false
    }

    var chains: [Chain] = []
    var colliders: [Collider] = []
    let tuning: Tuning

    var bodies: Set<Int> = []
    /// 前のフレームの 1 刻み（間隔が変わったら前の位置との差を比で直す）。
    var lastH: Float = 0
    /// `hair_hits_cloth` のときだけ。
    var surface: HairSurface?

    /// `skip`: 当たる相手にしない剛体（親に乗せた鎖）。`wider`: 名前の先頭がこれに一致する剛体の太さの倍率。
    init(_ pmx: PMXModel, _ bindings: [PhysicsWorld.Binding], skip: Set<Int> = [], wider: ([String], Float) = ([], 1)) {
        tuning = Tuning.fromEnvironment()
        let bones = pmx.bones
        guard Optimize.enabled("hair_chains"), let head = bones.firstIndex(where: { $0.name == "頭" }) else { return }
        var skinned = [Bool](repeating: false, count: bones.count)
        for (b, w) in zip(pmx.geometry.skinIndices, pmx.geometry.skinWeights) where w > 0 && Int(b) < skinned.count { skinned[Int(b)] = true }
        func under(_ b: Int) -> Bool { pmx.ancestors(of: b).contains(head) }
        var bodyOf: [Int: Int] = [:]
        for (i, b) in bindings.enumerated() where b.mode == .dynamic || b.mode == .dynamicBone {
            if let bone = b.bone, bone < bones.count, bodyOf[bone] == nil { bodyOf[bone] = i }
        }
        let physical = Set(bodyOf.keys.filter { skinned[$0] && under($0) })
        guard !physical.isEmpty else { return }
        func hasPhysicalAncestor(_ b: Int) -> Bool {
            var x = Int(bones[b].parentIndex)
            while x >= 0 && x != head {
                if physical.contains(x) { return true }
                x = Int(bones[x].parentIndex)
            }
            return false
        }
        var children = [Int: [Int]]()
        for (i, b) in bones.enumerated() where b.parentIndex >= 0 { children[Int(b.parentIndex), default: []].append(i) }
        var size = [Int](repeating: 1, count: bones.count)
        for i in bones.indices.reversed() where bones[i].parentIndex >= 0 && Int(bones[i].parentIndex) < bones.count { size[Int(bones[i].parentIndex)] += size[i] }
        // 親は子より前に並ぶ前提で後ろから
        var visibleBelow = skinned
        for i in bones.indices.reversed() where bones[i].parentIndex >= 0 && Int(bones[i].parentIndex) < bones.count && visibleBelow[i] {
            visibleBelow[Int(bones[i].parentIndex)] = true
        }
        func tail(_ b: Int) -> SIMD3<Float>? {
            let bone = bones[b]
            if bone.flags.indexedTail, bone.tailIndex >= 0, Int(bone.tailIndex) < bones.count, Int(bone.tailIndex) != b {
                let p = bones[Int(bone.tailIndex)].position
                return simd_distance(p, bone.position) > 1e-4 ? p : nil
            }
            if let t = bone.tailPosition, simd_length(t) > 1e-4 { return bone.position + t }
            return nil
        }
        let rigid = pmx.rigidBodies
        // VRM のスプリング（ばね = stiffness × 20、減衰 = 0.5 + 0.45 × dragForce）
        var vrmStiffness = [Int: Float]()
        if Optimize.optIn("vrm_spring_params") {
            for j in pmx.joints where j.rigidBodyIndexB >= 0 && Int(j.rigidBodyIndexB) < pmx.rigidBodies.count
                && pmx.rigidBodies[Int(j.rigidBodyIndexB)].name.hasPrefix("spring") {
                vrmStiffness[Int(j.rigidBodyIndexB)] = j.springRotationFactor.x / VRMSpring.springPerStiffness
            }
        }
        var range = [Int: Float]()
        for j in pmx.joints where j.rigidBodyIndexB >= 0 {
            let lo = j.rotationLowerLimit, hi = j.rotationUpperLimit
            let r = lo.x > hi.x && lo.y > hi.y && lo.z > hi.z ? Float.pi : max(max(abs(lo.x), abs(hi.x)), max(max(abs(lo.y), abs(hi.y)), max(abs(lo.z), abs(hi.z))))
            range[Int(j.rigidBodyIndexB)] = max(range[Int(j.rigidBodyIndexB)] ?? 0, r)
        }
        var queue = physical.filter { !hasPhysicalAncestor($0) }.sorted()
        var used = Set<Int>()
        while !queue.isEmpty {
            let root = queue.removeFirst()
            guard !used.contains(root) else { continue }
            var list = [root]
            used.insert(root)
            while list.count < 64, let kids = children[list.last!]?.filter({ !used.contains($0) && visibleBelow[$0] }), !kids.isEmpty {
                let next = kids.max { size[$0] != size[$1] ? size[$0] < size[$1] : $0 > $1 }!
                for extra in kids where extra != next { queue.append(extra) }
                list.append(next)
                used.insert(next)
            }
            var rest = list.map { bones[$0].position }
            let last = list.last!
            if let t = tail(last) {
                rest.append(t)
            } else if rest.count >= 2 {
                let d = rest[rest.count - 1] - rest[rest.count - 2]
                rest.append(rest.last! + d)
            } else if let bi = bodyOf[last] {
                let body = rigid[bi]
                let q = Math.quatEulerYXZ(body.rotation.y, body.rotation.x, body.rotation.z)
                var axis = q.act(SIMD3(0, 1, 0))
                if simd_dot(axis, body.position - bones[last].position) < 0 { axis = -axis }
                let length = max(body.shape == "capsule" ? body.size.y + body.size.x * 2 : body.size.y * 2, 0.1)
                rest.append(bones[last].position + axis * length)
            } else {
                continue
            }
            var dir: [SIMD3<Float>] = [], len: [Float] = []
            for i in 0..<(rest.count - 1) {
                let d = rest[i + 1] - rest[i]
                len.append(max(simd_length(d), 1e-3))
                dir.append(simd_length(d) > 1e-5 ? simd_normalize(d) : SIMD3(0, -1, 0))
            }
            let n = rest.count
            let t = tuning
            func along(_ i: Int) -> Float { n > 1 ? Float(i) / Float(n - 1) : 0 }
            var radius: [Float] = []
            var r: Float = 0.1
            for i in rest.indices {
                if let bi = bodyOf[list[min(i, list.count - 1)]] { r = rigid[bi].size.x }
                radius.append(max(r * 0.8, 0.05))
            }
            var locked: [Bool] = [], segRange: [Float] = []
            var lk = false, rr = t.cone * .pi / 180
            for b in list {
                if let bi = bodyOf[b], !rigid[bi].name.hasPrefix("spring"), let r = range[bi] { (lk, rr) = (r < 0.005, r) }
                locked.append(lk)
                segRange.append(rr)
            }
            var longRun = [Bool](repeating: false, count: locked.count), runStart = [Int](repeating: 0, count: locked.count)
            var q = 0
            while q < locked.count {
                guard locked[q] else { q += 1; continue }
                var e = q
                while e + 1 < locked.count && locked[e + 1] { e += 1 }
                if e - q >= 2 { for m in q...e { (longRun[m], runStart[m]) = (true, max(q - 1, 0)) } }
                q = e + 1
            }
            let cone = locked.indices.map { i -> Float in
                guard longRun[i] else { return cos(t.cone * .pi / 180) }
                let deg = segRange[runStart[i]] * 1.5 * 180 / .pi + 4 * Float(i - runStart[i])
                return cos(min(max(deg, 10), t.cone) * .pi / 180)
            }
            var stiff = rest.indices.map { i -> Float in
                t.stiff / t.soft * (1 + (t.tip - 1) * along(i)) * (i > 0 && longRun[min(i - 1, locked.count - 1)] ? 2 : 1)
            }
            // 上に立つ短い棒は逆さの振り子なので、根元の範囲を広げすぎると倒れる
            var rods: [(root: Int, tip: Int, cone: Float)] = []
            var k = 0
            while k < locked.count {
                if locked[k] && !longRun[k] {
                    var e = k
                    while e + 1 < locked.count && locked[e + 1] { e += 1 }
                    let r0 = max(k - 1, 0)
                    rods.append((root: r0, tip: e + 1, cone: cos(min(max(segRange[r0] * 1.5, 10 * .pi / 180), t.cone * .pi / 180))))
                    k = e + 1
                } else {
                    k += 1
                }
            }
            // 半径より短い節は押し出しのたびに向きが跳ねるので、半径の 3 倍に届くまでまとめて棒にする
            var covered = [Bool](repeating: false, count: len.count)
            for r in rods { for s in r.root..<min(r.tip, len.count) { covered[s] = true } }
            var a = 0
            while a < len.count {
                guard !covered[a] else { a += 1; continue }
                var b = a, reach: Float = 0
                while b < len.count && !covered[b] && reach < 3 * radius[a] {
                    reach += len[b]
                    b += 1
                }
                if b - a > 1 { rods.append((root: a, tip: b, cone: cone[a])) }
                a = b
            }
            var damp = rest.indices.map { t.damp + (t.dampTip - t.damp) * along($0) }
            // 倍率は 0.5 + 値、0.3〜3 倍
            for (i, b) in list.enumerated() {
                guard let bi = bodyOf[b], let k = vrmStiffness[bi] else { continue }
                let drag = (rigid[bi].angularDamping - 0.5) / 0.45
                if i + 1 < stiff.count { stiff[i + 1] *= min(max(0.5 + k, 0.3), 3) }
                damp[i] *= min(max(0.5 + 2 * drag, 0.3), 3)
            }
            let mask = list.compactMap { bodyOf[$0] }.reduce(UInt16(0)) { $0 | rigid[$1].mask }
            chains.append(Chain(bones: list, parent: Int(bones[root].parentIndex), rest: rest, dir: dir, len: len, radius: radius,
                                stiff: stiff, damp: damp, cone: cone, locked: locked, rods: rods, hits: [], p: [], prev: []))
            chains[chains.count - 1].hits = [Int(mask)]  // 後で当たる相手の番号に置き換える
            for b in list { if let bi = bodyOf[b] { bodies.insert(bi) } }
        }
        // 揺れる剛体も一覧に入れ、当てるかは `hair_hits_cloth` で決める
        for (i, b) in bindings.enumerated() where !bodies.contains(i) && !skip.contains(i) {
            guard let bone = b.bone, bone < bones.count else { continue }
            let body = rigid[i]
            let r: Float, h: SIMD3<Float>
            switch body.shape {
            case "sphere": (r, h) = (body.size.x, .zero)
            case "capsule": (r, h) = (body.size.x, SIMD3(0, body.size.y / 2, 0))
            default:
                let s = body.size
                let order = [0, 1, 2].sorted { s[$0] > s[$1] }
                var axis = SIMD3<Float>.zero
                axis[order[0]] = max(s[order[0]] - s[order[1]], 0)
                (r, h) = (s[order[1]], axis)
            }
            let (bp, bq) = b.bodyFromBone
            let scale = wider.0.contains { body.name.hasPrefix($0) } ? wider.1 : 1
            colliders.append(Collider(bone: bone, a: bp + bq.act(-h), b: bp + bq.act(h), r: r * scale, group: UInt16(1) << UInt16(min(body.group, 15)),
                                      moving: b.mode != .static))
        }
        for c in chains.indices {
            let mask = UInt16(chains[c].hits.first ?? 0)
            let cloth = Optimize.optIn("hair_hits_cloth")
            chains[c].hits = colliders.indices.filter { colliders[$0].group & mask != 0 && (cloth || !colliders[$0].moving) }
            // 止まっているときから重なっている点は押し出しをそのときの距離までにする（形を保つ力と引っ張り合って震える）
            chains[c].allow = chains[c].rest.indices.map { i in
                var out = [Float](repeating: .nan, count: colliders.count)
                for k in chains[c].hits {
                    let col = colliders[k], base = bones[col.bone].position
                    let (a, b) = (col.a + base, col.b + base)
                    let ab = b - a, x = chains[c].rest[i]
                    let u = simd_dot(ab, ab) > 1e-8 ? min(max(simd_dot(x - a, ab) / simd_dot(ab, ab), 0), 1) : 0
                    let d = simd_distance(x, a + ab * u)
                    if d < col.r + chains[c].radius[i] { out[k] = d }
                }
                return out
            }
        }
        if Optimize.optIn("hair_hits_cloth") {
            let hairBones = Set(chains.flatMap(\.bones))
            let s = HairSurface(pmx, chains: chains) { b in b == head || hairBones.contains(b) || under(b) }
            if !s.isEmpty { surface = s }
        }
    }

    var isEmpty: Bool { chains.isEmpty }

}
