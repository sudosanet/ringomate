import CMeshopt
import simd

enum Optimize {
    static func enabled(_ step: String) -> Bool { !Flags.disabled(step) }

    /// `MASCOT_ANALYZE="skin_color=0.2,…"`
    static func knob(_ name: String, _ fallback: Float) -> Float {
        guard let v = Flags.value("MASCOT_ANALYZE") else { return fallback }
        for part in v.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == name, let x = Float(kv[1]) { return x }
        }
        return fallback
    }

    /// 既定でオフ。`MASCOT_DISABLE` に `+名前` でオン。
    static func optIn(_ step: String) -> Bool { Flags.disabled("+" + step) }

    /// 形からの判定（解析器）。`MASCOT_DISABLE=analyzer` でまとめて切れる。
    static func analyzer(_ step: String) -> Bool { enabled("analyzer") && enabled(step) }

    @discardableResult
    static func optimizeVertexCache(_ pmx: inout PMXModel) -> Int {
        let vertexCount = pmx.geometry.positions.count / 3
        var start = 0, changed = 0
        for m in pmx.materials {
            let end = min(start + Int(max(m.faceCount, 0)) * 3, pmx.geometry.indices.count)
            if end - start >= 3 {
                let range = Array(pmx.geometry.indices[start..<end])
                var out = [UInt32](repeating: 0, count: range.count)
                meshopt_optimizeVertexCache(&out, range, range.count, vertexCount)
                pmx.geometry.indices.replaceSubrange(start..<end, with: out)
                changed += 1
            }
            start = end
        }
        return changed
    }

    static let weld: Float = 1e-4

    struct Key: Hashable {
        var m: Int, x: Int64, y: Int64, z: Int64
    }

    static func q(_ v: Float) -> Int64 { Int64((v / weld).rounded()) }

    static func normal(_ n: [Float], _ i: Int) -> SIMD3<Float> { SIMD3(n[i * 3], n[i * 3 + 1], n[i * 3 + 2]) }

    static func smoothNormals(positions: [Float], normals: [Float]) -> [Float] {
        let n = positions.count / 3
        func key(_ i: Int) -> Key { Key(m: 0, x: q(positions[i * 3]), y: q(positions[i * 3 + 1]), z: q(positions[i * 3 + 2])) }
        var sum: [Key: SIMD3<Float>] = [:]
        sum.reserveCapacity(n)
        for i in 0..<n { sum[key(i), default: .zero] += normal(normals, i) }
        var out = [Float]()
        out.reserveCapacity(n * 3)
        for i in 0..<n {
            let s = sum[key(i)]!
            let v = simd_length_squared(s) > 1e-12 ? s * (1 / simd_length(s)) : Math.normalizeOrZero(normal(normals, i))
            out += [v.x, v.y, v.z]
        }
        return out
    }

    @discardableResult
    static func weldSeamNormals(_ pmx: inout PMXModel, skip: [String], maxDegrees: Float) -> Int {
        let materials = pmx.materials.map { (Int(max($0.faceCount, 0)) * 3, skip.contains($0.name)) }
        return weld(positions: pmx.geometry.positions, normals: &pmx.geometry.normals, indices: pmx.geometry.indices,
                    materials: materials, maxDegrees: maxDegrees)
    }

    static func weld(positions: [Float], normals: inout [Float], indices: [UInt32], materials: [(Int, Bool)],
                     maxDegrees: Float) -> Int {
        let n = positions.count / 3
        var owner = [Int](repeating: -1, count: n)
        var start = 0
        for (mi, (count, skipped)) in materials.enumerated() {
            let end = min(start + count, indices.count)
            if !skipped {
                for i in indices[start..<end] where Int(i) < n && owner[Int(i)] == -1 { owner[Int(i)] = mi }
            }
            start = end
        }
        var groups: [Key: [Int]] = [:]
        for (i, mi) in owner.enumerated() where mi != -1 {
            groups[Key(m: mi, x: q(positions[i * 3]), y: q(positions[i * 3 + 1]), z: q(positions[i * 3 + 2])), default: []]
                .append(i)
        }
        let cosLimit = cos(Math.radians(maxDegrees))
        let src = normals
        func unit(_ i: Int) -> SIMD3<Float> { Math.normalizeOrZero(normal(src, i)) }
        var changed: [(Int, SIMD3<Float>)] = []
        for verts in groups.values where verts.count > 1 {
            for i in verts {
                let ni = unit(i)
                var sum = SIMD3<Float>.zero
                for j in verts {
                    let nj = unit(j)
                    if simd_dot(ni, nj) >= cosLimit { sum += nj }
                }
                let avg = Math.normalizeOrZero(sum)
                if avg != .zero && simd_dot(avg, ni) < 0.99999 { changed.append((i, avg)) }
            }
        }
        for (i, v) in changed { normals.replaceSubrange(i * 3..<i * 3 + 3, with: [v.x, v.y, v.z]) }
        return changed.count
    }

    @discardableResult
    static func faceNormals(_ pmx: inout PMXModel, names: [String]) -> Int {
        let blend: Float = 0.85
        var start = 0
        var verts: [Int] = []
        let idx = pmx.geometry.indices
        for m in pmx.materials {
            let count = Int(max(m.faceCount, 0)) * 3
            if names.contains(m.name) { verts += idx[start..<min(start + count, idx.count)].map { Int($0) } }
            start += count
        }
        verts = Array(Set(verts)).sorted()
        guard !verts.isEmpty else { return 0 }
        let pos = pmx.geometry.positions
        func p(_ i: Int) -> SIMD3<Float> { SIMD3(pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]) }
        var sum = SIMD3<Float>.zero
        for i in verts { sum += p(i) }
        let centroid = sum / Float(verts.count)
        let halfWidth = verts.reduce(Float(0)) { max($0, abs(p($1).x - centroid.x)) }
        let center = centroid + SIMD3(0, 0, halfWidth * 0.9)
        for i in verts {
            let orig = normal(pmx.geometry.normals, i)
            let radial = Math.normalizeOrZero(p(i) - center)
            let n = Math.normalizeOrZero(orig * (1 - blend) + radial * blend)
            pmx.geometry.normals.replaceSubrange(i * 3..<i * 3 + 3, with: [n.x, n.y, n.z])
        }
        return verts.count
    }

    static func locked(_ j: PMXModel.Joint) -> Bool {
        [j.translationLowerLimit, j.translationUpperLimit, j.rotationLowerLimit, j.rotationUpperLimit]
            .allSatisfy { v in (0..<3).allSatisfy { abs(v[$0]) < 1e-6 } }
    }

    static func bodies(_ pmx: PMXModel, prefixes: [String]) -> Set<Int> {
        Set(pmx.rigidBodies.indices.filter { b in prefixes.contains { pmx.rigidBodies[b].name.hasPrefix($0) } })
    }

    /// 固定でないジョイントの回転の範囲を `factor` 倍にする。
    @discardableResult
    static func widenJoints(_ pmx: inout PMXModel, bodies: Set<Int>, factor: Float) -> Int {
        guard !bodies.isEmpty, factor > 1 else { return 0 }
        var changed = 0
        for k in pmx.joints.indices {
            let b = Int(pmx.joints[k].rigidBodyIndexB)
            guard bodies.contains(b), !locked(pmx.joints[k]) else { continue }
            pmx.joints[k].rotationLowerLimit *= factor
            pmx.joints[k].rotationUpperLimit *= factor
            changed += 1
        }
        return changed
    }

    /// `rigidifyLockedChains` より前に呼ぶ。
    @discardableResult
    static func loosenLockedJoints(_ pmx: inout PMXModel, bodies: Set<Int>, degrees: Float) -> Int {
        guard !bodies.isEmpty, degrees > 0 else { return 0 }
        let r = Math.radians(degrees)
        var changed = 0
        for k in pmx.joints.indices {
            let j = pmx.joints[k]
            let b = j.rigidBodyIndexB
            guard locked(j), bodies.contains(Int(b)) else { continue }
            pmx.joints[k].rotationLowerLimit = SIMD3(-r, -r / 3, -r)
            pmx.joints[k].rotationUpperLimit = SIMD3(r, r / 3, r)
            pmx.joints[k].springRotationFactor = SIMD3(repeating: 40)
            changed += 1
        }
        return changed
    }

    @discardableResult
    static func rigidifyLockedChains(_ pmx: inout PMXModel) -> Int {
        var changed = 0
        while true {
            var progress = false
            for j in pmx.joints where locked(j) {
                let (a, b) = (Int(j.rigidBodyIndexA), Int(j.rigidBodyIndexB))
                guard a >= 0, b >= 0, a < pmx.rigidBodies.count, b < pmx.rigidBodies.count else { continue }
                let sa = pmx.rigidBodies[a].mode == "static", sb = pmx.rigidBodies[b].mode == "static"
                let target: Int
                switch (sa, sb) {
                case (true, false): target = b
                case (false, true): target = a
                default: continue
                }
                if pmx.rigidBodies[target].boneIndex < 0 { continue }
                pmx.rigidBodies[target].mode = "static"
                changed += 1
                progress = true
            }
            if !progress { return changed }
        }
    }

    /// 揺れる剛体の先に完全固定でつながる鎖（`force` の剛体）を、その剛体の延長として骨で付いていかせる。
    /// 付いていく剛体は何とも当てず、ジョイントは外す。
    /// `candidates` は指定の候補の名前。髪の鎖（頭の下で頂点の付く骨）は指定がない限り候補にしない。
    static func attachLockedTails(_ pmx: inout PMXModel, force: Set<Int>) -> (attached: Set<Int>, candidates: [String]) {
        let bodies = pmx.rigidBodies
        let head = pmx.bones.firstIndex { $0.name == "頭" }
        var skinned = [Bool](repeating: false, count: pmx.bones.count)
        for (k, w) in zip(pmx.geometry.skinIndices, pmx.geometry.skinWeights) where w > 0 && Int(k) < skinned.count { skinned[Int(k)] = true }
        let model = pmx
        func underHead(_ bone: Int) -> Bool { bone == head || model.ancestors(of: bone).contains { $0 == head } }
        func forced(_ b: Int) -> Bool { force.contains(b) }
        var tail = Set<Int>(), parentOf: [Int: Int] = [:]
        while true {
            var progress = false
            for j in pmx.joints where locked(j) {
                let (a, b) = (Int(j.rigidBodyIndexA), Int(j.rigidBodyIndexB))
                guard a >= 0, b >= 0, a < bodies.count, b < bodies.count, !tail.contains(b), bodies[b].mode != "static",
                      bodies[a].mode != "static" || tail.contains(a) else { continue }
                let (ba, bb) = (Int(bodies[a].boneIndex), Int(bodies[b].boneIndex))
                guard ba >= 0, bb >= 0, bb < pmx.bones.count, Int(pmx.bones[bb].parentIndex) == ba,
                      forced(b) || !(skinned[bb] && underHead(bb)) else { continue }
                tail.insert(b)
                parentOf[b] = a
                progress = true
            }
            if !progress { break }
        }
        let candidates = Set(tail.map { String(bodies[$0].name.prefix { !$0.isNumber && $0 != "_" }) }).sorted()
        // 親が指定から外れた先は付け直せないので外さない
        tail = tail.filter(forced)
        tail = tail.filter { b in parentOf[b].map { tail.contains($0) || bodies[$0].mode != "static" } ?? false }
        guard !tail.isEmpty else { return ([], candidates) }
        for b in tail {
            pmx.rigidBodies[b].mode = "static"
            pmx.rigidBodies[b].mask = 0
        }
        pmx.joints.removeAll { tail.contains(Int($0.rigidBodyIndexA)) || tail.contains(Int($0.rigidBodyIndexB)) }
        return (tail, candidates)
    }

    @discardableResult
    static func removeBrokenJoints(_ pmx: inout PMXModel) -> Int {
        let n = Int32(pmx.rigidBodies.count), before = pmx.joints.count
        pmx.joints.removeAll { !((0..<n).contains($0.rigidBodyIndexA) && (0..<n).contains($0.rigidBodyIndexB)
                && $0.rigidBodyIndexA != $0.rigidBodyIndexB) }
        return before - pmx.joints.count
    }

    static func boundingRadius(_ r: PMXModel.RigidBody) -> Float {
        switch r.shape {
        case "sphere": r.size.x
        case "capsule": r.size.x + r.size.y * 0.5
        default: (r.size.x * r.size.x + r.size.y * r.size.y + r.size.z * r.size.z).squareRoot()
        }
    }

    @discardableResult
    static func excludeRestOverlaps(_ pmx: inout PMXModel) -> Int {
        let n = pmx.rigidBodies.count
        var pairs: [(Int, Int)] = []
        for j in pmx.joints {
            let (a, b) = (Int(j.rigidBodyIndexA), Int(j.rigidBodyIndexB))
            guard a >= 0, b >= 0, a < n, b < n, a != b else { continue }
            let ra = pmx.rigidBodies[a], rb = pmx.rigidBodies[b]
            if ra.mode == "static" || rb.mode == "static" || ra.group == rb.group || ra.group > 15 || rb.group > 15 { continue }
            let d = ra.position - rb.position
            let d2 = d.x * d.x + d.y * d.y + d.z * d.z
            let reach = (boundingRadius(ra) + boundingRadius(rb)) * 0.6
            let collides = ra.mask & (1 << UInt16(rb.group)) != 0 || rb.mask & (1 << UInt16(ra.group)) != 0
            if collides && d2 < reach * reach { pairs.append((a, b)) }
        }
        for (a, b) in pairs {
            let (ga, gb) = (pmx.rigidBodies[a].group, pmx.rigidBodies[b].group)
            pmx.rigidBodies[a].mask &= ~(1 << UInt16(gb))
            pmx.rigidBodies[b].mask &= ~(1 << UInt16(ga))
        }
        return pairs.count
    }

    @discardableResult
    static func widenLegColliders(_ pmx: inout PMXModel, legBones: [Int], scale: Float) -> Int {
        guard abs(scale - 1) >= 1e-3 else { return 0 }
        var changed = 0
        for k in pmx.rigidBodies.indices {
            let r = pmx.rigidBodies[k]
            guard r.mode == "static", r.boneIndex >= 0, legBones.contains(Int(r.boneIndex)) else { continue }
            pmx.rigidBodies[k].size.x *= scale
            if r.shape == "box" { pmx.rigidBodies[k].size.z *= scale }
            changed += 1
        }
        return changed
    }
}

import Foundation
