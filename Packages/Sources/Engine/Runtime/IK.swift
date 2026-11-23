import simd

/// mmd-anim-runtime の移植。
struct IKScratch {
    var base: [simd_quatf] = [], baseIK: [simd_quatf] = [], ik: [simd_quatf] = []
    var states: [ChainLinkState] = []
}

struct ChainLinkState {
    var rotationMatrix: simd_float4x4?
}

extension Evaluator {
    static func translation(_ m: simd_float4x4) -> SIMD3<Float> { m.columns.3.xyz }

    /// D3DX と同じ足し算の順。
    static func normalizeIK(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let x = v.x * v.x, y = v.y * v.y, z = v.z * v.z
        return SIMD3(v.x * (1 / ((y + x) + z).squareRoot()), v.y * (1 / ((z + y) + x).squareRoot()),
                     v.z * (1 / ((x + z) + y).squareRoot()))
    }

    static func iterations(_ authored: Int, _ angle: Float) -> Int {
        let minimum = angle.isFinite && angle > 0 ? Int(min(4 * Float.pi / angle, 360)) : 0
        return max(max(authored, minimum), 1)
    }

    func solveIK(_ index: Int) {
        guard pose.ikEnabled[index] else { return }
        let solver = model.ikSolvers[index]
        let (ikBone, target) = (solver.ikBone, solver.targetBone)
        let iterationCount = Self.iterations(solver.iterationCount, solver.limitAngle)
        let limitAngle = max(solver.limitAngle, 0)
        let tolerance: Float = 1e-4
        let links = solver.links
        pose.appendRotations[target] = Math.identity
        ikScratch.base = links.map { pose.localRotations[$0.bone] }
        ikScratch.baseIK = links.map { pose.ikRotations[$0.bone] }
        ikScratch.ik = ikScratch.base
        ikScratch.states = Array(repeating: ChainLinkState(), count: links.count)
        applyLinkRotations(links)

        func distance() -> Float { simd_length(Self.translation(pose.world[target]) - Self.translation(pose.world[ikBone])) }
        iterations: for iteration in 0..<iterationCount {
            if distance() <= tolerance { break }
            for (li, link) in links.enumerated() {
                let bone = link.bone
                if bone == target { continue }
                let linkWorld = pose.world[bone]
                let linkPos = Self.translation(linkWorld)
                let effPos = Self.translation(pose.world[target]), ikPos = Self.translation(pose.world[ikBone])
                let toEffector = effPos - linkPos, toTarget = ikPos - linkPos
                if simd_dot(toEffector, toEffector) <= .ulpOfOne || simd_dot(toTarget, toTarget) <= .ulpOfOne { continue }
                let gap = Self.normalizeIK(linkPos - effPos) - Self.normalizeIK(linkPos - ikPos)
                if simd_dot(gap, gap) < 1e-7 {
                    break iterations
                }
                // 付与に頼る鎖は前の評価の回転から続ける（最初の一歩だけ）
                if iteration == 0, let previous = ikHistory[bone] {
                    let base = ikScratch.base[li]
                    ikScratch.ik[li] = MMDMath.multiply(base, previous)
                }
                let p = model.parents[bone]
                var ik = ikScratch.ik[li], state = ikScratch.states[li]
                Self.linkStep(effector: linkPos - effPos, target: linkPos - ikPos,
                              parent: p >= 0 ? pose.world[p] : matrix_identity_float4x4,
                              ik: &ik,
                              state: &state, limit: link.limit, iteration: iteration,
                              iterationCount: iterationCount, limitAngle: limitAngle * Float(li + 1),
                              fixedAxis: model.fixedAxis[bone])
                ikScratch.ik[li] = ik
                ikScratch.states[li] = state
                if ikHistory[bone] != nil { ikHistory[bone] = ikScratch.ik[li] }
                applyLinkRotations(links)
                updateAfterLinkChange(index, links)
            }
            if distance() <= tolerance { break }
        }
        applyLinkRotations(links)
        updateAfterLinkChange(index, links)
    }

    func applyLinkRotations(_ links: [RuntimeModel.IKLink]) {
        for (i, link) in links.enumerated() {
            let s = ikScratch
            pose.ikRotations[link.bone] = simd_normalize(Math.mul(Math.mul(s.ik[i], Math.inverse(s.base[i])), s.baseIK[i]))
            pose.localRotations[link.bone] = s.ik[i]
        }
    }

    func updateAfterLinkChange(_ index: Int, _ links: [RuntimeModel.IKLink]) {
        if ikUpdateBones[index] == nil { ikUpdateBones[index] = computeUpdateBones(index) }
        let target = model.ikSolvers[index].targetBone
        for bone in ikUpdateBones[index]! {
            updateAppend(bone, except: target)
            let m = links.firstIndex { $0.bone == bone }.flatMap { ikScratch.states[$0].rotationMatrix }
            updateWorld(bone, rotationMatrix: m)
        }
    }

    func computeUpdateBones(_ index: Int) -> [Int] {
        let s = model.ikSolvers[index]
        let links = s.links.map(\.bone)
        var start = min(model.evalPosition[s.ikBone], model.evalPosition[s.targetBone])
        for b in [s.ikBone, s.targetBone] + links {
            start = min(start, model.evalPosition[b])
            var c = b
            while c >= 0 {
                start = min(start, model.evalPosition[c])
                c = model.parents[c]
            }
        }
        start = expandStart(start)
        func inScope(_ b: Int) -> Bool {
            if b == s.ikBone || b == s.targetBone || links.contains(b) { return true }
            if model.isAncestor(b, of: s.ikBone) || model.isAncestor(b, of: s.targetBone) || model.isAncestor(s.targetBone, of: b) {
                return true
            }
            return links.contains { model.isAncestor(b, of: $0) || model.isAncestor($0, of: b) }
        }
        var roots: [Int] = []
        while true {
            var changed = false
            for a in model.appends {
                let sourceChanged = inScope(a.source) || roots.contains { a.source == $0 || model.isAncestor($0, of: a.source) }
                if sourceChanged && !roots.contains(a.target) {
                    roots.append(a.target)
                    changed = true
                }
            }
            if !changed { break }
        }
        var out: [Int] = []
        for b in model.evalOrder[start...] {
            if b != s.targetBone && !links.contains(b) && model.ikSolvers.contains(where: { $0.targetBone == b }) { continue }
            if inScope(b) || roots.contains(where: { b == $0 || model.isAncestor($0, of: b) }) { out.append(b) }
        }
        return out
    }

    static func singleAxis(_ limit: (min: SIMD3<Float>, max: SIMD3<Float>)?) -> Int? {
        guard let l = limit else { return nil }
        func has(_ i: Int) -> Bool { l.min[i] != 0 || l.max[i] != 0 }
        if has(0), !has(1), !has(2) { return 0 }
        if has(1), !has(0), !has(2) { return 1 }
        if has(2), !has(0), !has(1) { return 2 }
        return nil
    }

    // swiftlint:disable:next function_parameter_count
    static func linkStep(effector: SIMD3<Float>, target: SIMD3<Float>, parent: simd_float4x4,
                         ik: inout simd_quatf, state: inout ChainLinkState,
                         limit: (min: SIMD3<Float>, max: SIMD3<Float>)?, iteration: Int, iterationCount: Int,
                         limitAngle: Float, fixedAxis: SIMD3<Float>?) {
        if let limit {
            if let f = fixedAxis, !(f.x.isFinite && f.y.isFinite && f.z.isFinite) || simd_dot(f, f) <= .ulpOfOne { return }
            limitedStep(effector: effector, target: target, parent: parent, ik: &ik, state: &state, limit: limit, iteration: iteration,
                        iterationCount: iterationCount, limitAngle: limitAngle, fixedAxis: fixedAxis)
            return
        }
        let base = Math.identity
        let current = MMDMath.multiply(base, ik)
        if let solved = worldStep(effector, target, parent, current, limitAngle, fixedAxis) {
            ik = MMDMath.multiply(Math.inverse(base), solved)
            return
        }
        // ponytail: 親の行列が回転だけでないときの、局所の座標での一歩（PMX では起きない）は写していない
    }

    static func worldStep(_ effector: SIMD3<Float>, _ target: SIMD3<Float>, _ parent: simd_float4x4, _ current: simd_quatf,
                          _ limit: Float, _ fixedAxis: SIMD3<Float>?) -> simd_quatf? {
        if let f = fixedAxis, !(f.x.isFinite && f.y.isFinite && f.z.isFinite) || abs(simd_dot(f, f) - 1) > 2e-4 {
            return nil
        }
        let basis = Math.mat3(parent)
        let check = basis.transpose * basis - matrix_identity_float3x3
        for c in 0..<3 { for r in 0..<3 where !check[c][r].isFinite || abs(check[c][r]) > 1e-4 { return nil } }
        let a = normalizeIK(effector), b = normalizeIK(target)
        let c = simd_cross(a, b)
        let m = parent
        var axis = SIMD3((m[0][0] * c.x + m[0][1] * c.y) + m[0][2] * c.z, (m[1][0] * c.x + m[1][1] * c.y) + m[1][2] * c.z,
                         (m[2][0] * c.x + m[2][1] * c.y) + m[2][2] * c.z)
        if simd_dot(axis, axis) < 1e-10 || !(axis.x.isFinite && axis.y.isFinite && axis.z.isFinite) { return nil }
        axis = normalizeIK(axis)
        let dot = min(max((a.x * b.x + a.y * b.y) + a.z * b.z, -1), 1)
        var align: Float = 1
        if let f = fixedAxis {
            align = (f.y * axis.y + f.x * axis.x) + f.z * axis.z
            axis = f
        }
        var half = (acos(dot) * 0.5) * align
        if limit > 0 { half = min(max(half, -limit * 0.5), limit * 0.5) }
        let s = sin(half)
        return MMDMath.multiply(current, simd_quatf(ix: axis.x * s, iy: axis.y * s, iz: axis.z * s, r: cos(half)))
    }

    static func limitedStep(effector: SIMD3<Float>, target: SIMD3<Float>, parent: simd_float4x4, ik: inout simd_quatf, state: inout ChainLinkState,
                            limit: (min: SIMD3<Float>, max: SIMD3<Float>), iteration: Int, iterationCount: Int,
                            limitAngle: Float, fixedAxis: SIMD3<Float>?) {
        let base = Math.identity
        let current = MMDMath.multiply(base, ik)
        let single = singleAxis(limit)
        let a = normalizeIK(effector), b = normalizeIK(target)
        let c = simd_cross(a, b)
        let m = parent
        let cross = SIMD3((m[0][0] * c.x + m[0][1] * c.y) + m[0][2] * c.z, (m[1][0] * c.x + m[1][1] * c.y) + m[1][2] * c.z,
                          (m[2][0] * c.x + m[2][1] * c.y) + m[2][2] * c.z)
        var angle = acos(min(max((a.x * b.x + a.y * b.y) + a.z * b.z, -1), 1))
        let normalizedCross = simd_dot(cross, cross) > 0 ? normalizeIK(cross) : cross
        let reflect = iteration < iterationCount / 2
        var axis: SIMD3<Float>
        if let i = single, reflect {
            var v = SIMD3<Float>(0, 0, 0)
            v[i] = 1
            axis = simd_dot(cross, v) < 0 ? -v : v
        } else if let f = fixedAxis {
            let fixed = simd_normalize(f)
            angle *= simd_dot(fixed, normalizedCross)
            axis = fixed
        } else {
            axis = normalizedCross
        }
        if limitAngle > 0 { angle = min(max(angle, -limitAngle), limitAngle) }
        if simd_dot(axis, axis) <= .ulpOfOne { return }
        let candidate = MMDMath.multiply(current, Math.axisAngle(axis, angle))
        let halfPi = Float(bitPattern: 0x3fc9_0fd8)
        let order = limit.min.x > -halfPi && limit.max.x < halfPi ? 0 : limit.min.y > -halfPi && limit.max.y < halfPi ? 1 : 2
        let r = MMDMath.rotationMatrix(candidate)
        let mm = [r[0][0], r[0][1], r[0][2], r[0][3], r[1][0], r[1][1], r[1][2], r[1][3], r[2][0], r[2][1], r[2][2], r[2][3]]
        let cap = Float(bitPattern: 0x3fc4_9803)
        var angles: SIMD3<Float>
        switch order {
        case 0:
            let x = min(max(asin(-mm[9]), -cap), cap), cx = cos(x)
            angles = SIMD3(x, MMDMath.atan2(mm[8] / cx, mm[10] / cx), MMDMath.atan2(mm[1] / cx, mm[5] / cx))
        case 1:
            let y = min(max(asin(-mm[2]), -cap), cap), cy = cos(y)
            angles = SIMD3(MMDMath.atan2(mm[6] / cy, mm[10] / cy), y, MMDMath.atan2(mm[1] / cy, mm[0] / cy))
        default:
            let z = min(max(asin(-mm[4]), -cap), cap), cz = cos(z)
            angles = SIMD3(MMDMath.atan2(mm[6] / cz, mm[5] / cz), MMDMath.atan2(mm[8] / cz, mm[0] / cz), z)
        }
        for i in 0..<3 {
            let (lo, hi) = (limit.min[i], limit.max[i])
            if angles[i] < lo {
                let rr = 2 * lo - angles[i]
                angles[i] = reflect && rr <= hi ? rr : lo
            }
            if angles[i] > hi {
                let rr = 2 * hi - angles[i]
                angles[i] = reflect && rr >= lo ? rr : hi
            }
        }
        let mx = MMDMath.axisRotation(0, angles.x), my = MMDMath.axisRotation(1, angles.y), mz = MMDMath.axisRotation(2, angles.z)
        let composed = order == 0 ? Math.mul(my, Math.mul(mx, mz)) : order == 1 ? Math.mul(mz, Math.mul(my, mx)) : Math.mul(mx, Math.mul(mz, my))
        let q = MMDMath.quaternion(composed)
        state.rotationMatrix = composed
        ik = MMDMath.multiply(Math.inverse(base), q)
    }
}
