import Foundation
import simd

final class PhysicsWorld {
    enum Mode { case `static`, dynamic, dynamicBone, unknown }

    struct Binding {
        var bone: Int?
        var mode: Mode
        var bodyFromBone: (SIMD3<Float>, simd_quatf)
        var boneFromBody: (SIMD3<Float>, simd_quatf)
    }

    /// 形は 0 球・1 箱・2 カプセル（C の API と同じ）。
    struct BodySpec {
        var shape: Int32
        var size: SIMD3<Float>
        var position: SIMD3<Float>
        var rotation: simd_quatf
        var mass: Float
        var linearDamping: Float, angularDamping: Float, friction: Float, restitution: Float
        var group: UInt8
        var mask: UInt16
    }

    struct JointSpec {
        var a: Int32, b: Int32
        var position: SIMD3<Float>
        /// PMX のオイラー角（Ry·Rx·Rz）。
        var euler: SIMD3<Float>
        var translationLower: SIMD3<Float>, translationUpper: SIMD3<Float>
        var rotationLower: SIMD3<Float>, rotationUpper: SIMD3<Float>
        var springTranslation: SIMD3<Float>, springRotation: SIMD3<Float>
        var side = false
    }

    struct BuildError: Error, CustomStringConvertible { var description: String }

    let engine: JoltEngine
    private(set) var bindings: [Binding]
    let jointsUnsupported: Int
    private(set) var notes: [String] = []
    var floorIndex: Int? { engine.floorIndex }
    var floorHalf = SIMD3<Float>.zero
    var hair: HairChains?

    init(_ pmx: PMXModel, attached: Set<Int> = [], tuning: Profile.PhysicsTuning = .init()) throws {
        var bodies: [BodySpec] = []
        var bindings: [Binding] = []
        for (i, b) in pmx.rigidBodies.enumerated() {
            let (kind, size): (Int32, SIMD3<Float>) = switch b.shape {
            case "sphere": (0, SIMD3(b.size.x, 0, 0))
            case "box": (1, b.size)
            case "capsule": (2, SIMD3(b.size.x, b.size.y, 0))
            default: throw BuildError(description: "unsupported PMX rigid body shape `\(b.shape)` at index \(i)")
            }
            let q = Math.quatEulerYXZ(b.rotation.y, b.rotation.x, b.rotation.z)
            let mode: Mode = switch b.mode {
            case "static": .static
            case "dynamic": .dynamic
            case "dynamicBone": .dynamicBone
            default: .unknown
            }
            let source: Float = b.mode == "static" ? 0 : b.mass
            // 1e6 は鎖が有限のままでいられる上限
            let mass: Float = mode == .static ? 0 : (source > 0 ? min(source, 1e6) : 0)
            bodies.append(BodySpec(shape: kind, size: size, position: b.position, rotation: q, mass: mass,
                                   linearDamping: b.linearDamping, angularDamping: b.angularDamping, friction: b.friction,
                                   restitution: b.restitution, group: b.group, mask: b.mask))
            let bodyBind = Math.matrix(q, b.position)
            let valid = b.boneIndex >= 0 && Int(b.boneIndex) < pmx.bones.count
            let fromBone: simd_float4x4, toBone: simd_float4x4
            if valid {
                let boneBind = Math.translation(pmx.bones[Int(b.boneIndex)].position)
                fromBone = Math.mul(Math.inverse(boneBind), bodyBind)
                toBone = Math.mul(Math.inverse(bodyBind), boneBind)
            } else {
                (fromBone, toBone) = (bodyBind, Math.inverse(bodyBind))
            }
            bindings.append(Binding(bone: b.boneIndex >= 0 ? Int(b.boneIndex) : nil, mode: mode,
                                    bodyFromBone: Math.transform(fromBone), boneFromBody: Math.transform(toBone)))
        }
        var joints: [JointSpec] = []
        var unsupported = 0
        for j in pmx.joints {
            guard j.kind == "generic6dofSpring" else {
                unsupported += 1
                continue
            }
            guard j.rigidBodyIndexA >= 0, j.rigidBodyIndexB >= 0, Int(j.rigidBodyIndexA) < bodies.count,
                  Int(j.rigidBodyIndexB) < bodies.count else { continue }
            let (ba, bb) = (bindings[Int(j.rigidBodyIndexA)].bone, bindings[Int(j.rigidBodyIndexB)].bone)
            let parentOf = { (b: Int?) -> Int? in b.flatMap { $0 < pmx.bones.count && pmx.bones[$0].parentIndex >= 0 ? Int(pmx.bones[$0].parentIndex) : nil } }
            let side = bodies[Int(j.rigidBodyIndexA)].mass > 0 && bodies[Int(j.rigidBodyIndexB)].mass > 0 && ba != nil && bb != nil
                && parentOf(bb) != ba && parentOf(ba) != bb
            joints.append(JointSpec(a: j.rigidBodyIndexA, b: j.rigidBodyIndexB, position: j.position, euler: j.rotation,
                                    translationLower: j.translationLowerLimit, translationUpper: j.translationUpperLimit,
                                    rotationLower: j.rotationLowerLimit, rotationUpper: j.rotationUpperLimit,
                                    springTranslation: j.springTranslationFactor, springRotation: j.springRotationFactor, side: side))
        }
        let chains = HairChains(pmx, bindings, skip: attached, wider: (tuning.hairColliders, tuning.hairColliderScale))
        if !chains.isEmpty {
            for i in chains.bodies {
                bodies[i].mass = 0
                bodies[i].mask = 0
                bindings[i].mode = .static
            }
            hair = chains
        }
        var counts = [Int](repeating: 0, count: 16)
        for b in bodies where b.mass > 0 {
            for g in 0..<16 where b.mask & (UInt16(1) << UInt16(g)) != 0 { counts[g] += 1 }
        }
        let best = counts.indices.max { counts[$0] != counts[$1] ? counts[$0] < counts[$1] : $0 > $1 } ?? 0
        engine = try JoltEngine(&bodies, &bindings, joints, floorGroup: counts[best] > 0 ? UInt8(best) : nil)
        notes = engine.notes
        if let hair { notes.append("physics: \(hair.chains.count) hair chains (\(hair.bodies.count) bodies) solved as strands") }
        self.bindings = bindings
        jointsUnsupported = unsupported
    }

    func feed(_ bones: [simd_float4x4], all: Bool = false, dynamicBone: Bool = false) {
        for (i, b) in bindings.enumerated() {
            guard all || b.mode == .static || (dynamicBone && b.mode == .dynamicBone), let bone = b.bone, bone < bones.count else { continue }
            let boneWorld = Math.transformMatrix(Math.transform(bones[bone]))
            let (p, q) = Math.transform(Math.mul(boneWorld, Math.transformMatrix(b.bodyFromBone)))
            engine.setTransform(i, p, q)
        }
    }

    /// 種類 2 = MMD の「物理 + ボーン位置合わせ」。
    func rotationOnly(boneCount: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: boneCount)
        for b in bindings where b.mode == .dynamicBone { if let bone = b.bone, bone < boneCount { out[bone] = true } }
        return out
    }

    /// 同じ骨に剛体がいくつかあれば後のもの。
    func readback(boneCount: Int) -> [simd_float4x4?] {
        var out = [simd_float4x4?](repeating: nil, count: boneCount)
        for (i, b) in bindings.enumerated() {
            guard b.mode == .dynamic || b.mode == .dynamicBone, let bone = b.bone, bone < boneCount else { continue }
            let (p, q) = engine.transform(i)
            out[bone] = Math.transformMatrix(Math.transform(Math.mul(Math.matrix(q, p), Math.transformMatrix(b.boneFromBody))))
        }
        return out
    }
}

struct PhysicsClock {
    var substep: Float = 1.0 / 120
    var maxSubsteps: UInt32 = 8
    var accumulator: Float = 0

    mutating func configure(substep s: Float, max: UInt32) {
        substep = s.isFinite && s > 0 ? s : 1.0 / 120
        maxSubsteps = Swift.max(max, 1)
        accumulator = min(accumulator, substep * Float(maxSubsteps))
    }

    mutating func advance(_ dt: Float) -> UInt32 {
        let clamped = !dt.isFinite || dt <= 0 ? 0 : min(dt, substep * Float(maxSubsteps))
        accumulator += clamped
        var n: UInt32 = 0
        while accumulator + .ulpOfOne >= substep && n < maxSubsteps {
            accumulator -= substep
            n += 1
        }
        if n == maxSubsteps { accumulator = min(accumulator, substep) }
        return n
    }
}

extension Puppet {
    func buildPhysics() -> [String] {
        guard !model.pmx.rigidBodies.isEmpty else { return [] }
        var lines: [String] = []
        do {
            let w = try PhysicsWorld(model.pmx, attached: attachedBodies, tuning: model.profile.physics)
            lines += w.notes
            if w.jointsUnsupported > 0 { lines.append("physics: \(w.jointsUnsupported) joints skipped (unsupported type)") }
            physics = w
            eval.pose.resetLocal()
            eval.evaluate()
            resetPhysics()
        } catch {
            lines.append("physics disabled: \(error)")
        }
        return lines
    }

    func disablePhysics() { physics = nil }

    func resetPhysics() {
        guard let w = physics else { return }
        lastTargets = []
        clock.accumulator = 0
        w.engine.reset()
        w.feed(eval.pose.world, all: true)
        w.engine.settle()
        w.engine.step(1.0 / 60, 2)
        w.feed(eval.pose.world)
        w.engine.settle()
        w.hair?.reset(eval.pose.world, bones: model.pmx.bones)
        eval.applyPhysics(w.readback(boneCount: runtime.boneCount), rotationOnly: w.rotationOnly(boneCount: runtime.boneCount))
        eval.evaluateAfterPhysics()
    }

    func stepPhysics(_ dt: Float, accel: SIMD3<Float>, surfaces: [SIMD3<Float>] = []) {
        guard let w = physics else {
            eval.evaluate()
            return
        }
        let n = max((dt * hz).rounded(.toNearestOrAwayFromZero), 1)
        substep = dt / n
        clock.configure(substep: substep, max: UInt32(n) + 1)
        clock.accumulator = 0
        var a = accel
        if case .dance = player.current { a.y *= 0.3 }
        w.engine.setGravity(Math.rotate(Math.rotY(-facing), Self.gravity - a))
        eval.evaluateBeforePhysics()
        let steps = clock.advance(dt)
        w.feed(eval.pose.world)
        let floor = placeFloor(w, surfaces)
        if steps > 0 { w.engine.step(clock.substep * Float(steps), Int32(steps)) }
        var targets = w.readback(boneCount: runtime.boneCount)
        if w.hair != nil {
            let toLocal = Math.rotY(-facing)
            w.hair!.solve(dt, eval.pose.world, bones: model.pmx.bones, gravity: Math.rotate(toLocal, Self.gravity),
                          accel: Math.rotate(toLocal, a), floor: floor, targets: &targets)
        }
        smoothForHighFrameRate(&targets, dt)
        eval.applyPhysics(targets, rotationOnly: w.rotationOnly(boneCount: runtime.boneCount))
        eval.evaluateAfterPhysics()
        if restReach == nil { restReach = reach() * 3 }
        if let r = restReach, reach() > r {
            physicsRestarts += 1
            eval.evaluateBeforePhysics()
            resetPhysics()
            eval.evaluate()
        }
    }

    /// 120Hz の画面では、刻みごとの行き来が見えないよう前のフレームの結果と半分ずつならす（揺れものは 1 フレーム遅れる）。
    func smoothForHighFrameRate(_ targets: inout [simd_float4x4?], _ dt: Float) {
        guard dt < 1.0 / 90, Optimize.enabled("physics_smooth") else {
            lastTargets = []
            return
        }
        let raw = targets
        if lastTargets.count == targets.count {
            for b in targets.indices {
                guard let now = targets[b], let before = lastTargets[b] else { continue }
                let p = Math.lerp(before.columns.3.xyz, now.columns.3.xyz, 0.5)
                targets[b] = Math.matrix(simd_normalize(Math.slerp(Math.rotationOf(before), Math.rotationOf(now), 0.5)), p)
            }
        }
        lastTargets = raw
    }

    /// `surfaces` は (左端, 右端, 上端)、画面の座標。
    @discardableResult
    func placeFloor(_ w: PhysicsWorld, _ surfaces: [SIMD3<Float>]) -> Float? {
        guard let i = w.floorIndex else { return nil }
        let lift = max(stature, 1) * 0.1
        guard let s = surfaces.filter({ $0.x <= root.x && root.x <= $0.y && $0.z <= root.y + lift }).max(by: { $0.z < $1.z }) else { return nil }
        let thick: Float = 2
        let half = SIMD3(min((s.y - s.x) / 2, 1000), thick, 50)
        if half != w.floorHalf {
            w.floorHalf = half
            w.engine.setBox(i, half)
        }
        let world = SIMD3((s.x + s.y) / 2, s.z - thick, 0)
        let local = Math.rotate(Math.rotY(-facing), world - root - SIMD3(0, ground - drop, 0))
        w.engine.setTransform(i, local, Math.rotY(-facing))
        return s.z - root.y - (ground - drop)
    }

    func reach() -> Float {
        var far: Float = 0
        for m in eval.pose.world {
            let p = m.columns.3.xyz
            if !(p.x.isFinite && p.y.isFinite && p.z.isFinite) { return .infinity }
            if p.y > -1.0e3 { far = max(far, simd_length(p)) }
        }
        return far
    }
}

extension Evaluator {
    /// `rotationOnly` の骨は位置をアニメのまま、回転だけ物理から取る。
    func applyPhysics(_ targets: [simd_float4x4?], rotationOnly: [Bool] = []) {
        guard targets.contains(where: { $0 != nil }) else { return }
        for (b, t) in targets.prefix(model.boneCount).enumerated() {
            guard let t else { continue }
            pose.world[b] = t
            transform[b] = Math.mulTranslation(t, -model.restWorld[b])
        }
        var visited = [Bool](repeating: false, count: model.boneCount)
        func visit(_ b: Int) {
            guard !visited[b] else { return }
            visited[b] = true
            let p = model.parents[b]
            if p >= 0 { visit(p) }
            if let k = model.appendOfBone[b] { visit(model.appends[k].source) }
            updateAppend(b)
            if b < targets.count, let t = targets[b] {
                let parentInverse = p >= 0 ? Math.inverse(pose.world[p]) : matrix_identity_float4x4
                let (scale, r, translation) = Math.scaleRotationTranslation(Math.mul(parentInverse, t))
                var rotation = r
                var offset = translation - model.restLocal[b]
                if let k = model.appendOfBone[b] {
                    if model.appends[k].rotation { rotation = Math.mul(rotation, Math.inverse(pose.appendRotations[b])) }
                    if model.appends[k].translation { offset -= pose.appendOffsets[b] }
                }
                if !(b < rotationOnly.count && rotationOnly[b]) { pose.localOffsets[b] = offset }
                pose.localRotations[b] = simd_normalize(rotation)
                pose.localScales[b] = scale
            }
            updateWorld(b)
        }
        for b in model.evalOrder { visit(b) }
        updateWorldFrom(0)
    }
}
