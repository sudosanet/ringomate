import CJolt
import Foundation
import simd

final class JoltEngine {
    let world: OpaquePointer
    private(set) var notes: [String] = []
    private(set) var floorIndex: Int?

    static func knobs() -> [String: Float] {
        guard let v = Flags.value("MASCOT_JOLT") else { return [:] }
        var out: [String: Float] = [:]
        for part in v.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, let x = Float(kv[1]) { out[kv[0]] = x }
        }
        return out
    }

    init(_ bodies: inout [PhysicsWorld.BodySpec], _ bindings: inout [PhysicsWorld.Binding], _ joints: [PhysicsWorld.JointSpec],
         floorGroup: UInt8?) throws {
        let k = Self.knobs()
        var t = jolt_puppet_tuning()
        t.spring_frequency_scale = k["freq"] ?? 0
        t.spring_frequency_min = k["fmin"] ?? 0
        t.spring_frequency_max = k["fmax"] ?? 0
        t.spring_damping = k["damp"] ?? 0
        t.max_angular_velocity = k["wmax"] ?? 0
        t.max_linear_velocity = k["vmax"] ?? 0
        t.inertia_multiplier = k["inertia"] ?? 0
        t.penetration_slop = k["slop"] ?? 0
        t.speculative_distance = k["spec"] ?? 0
        t.velocity_steps = Int32(k["vel"] ?? 0)
        t.position_steps = Int32(k["pos"] ?? 0)
        t.threads = Int32(k["threads"] ?? 0)
        let ccd: Int32 = (k["ccd"] ?? 0) > 0 ? 1 : 0

        var anchored = 0
        for i in bodies.indices where bodies[i].mass >= 1000 && bindings[i].bone != nil {
            bodies[i].mass = 0
            bindings[i].mode = .static
            anchored += 1
        }
        if anchored > 0 { notes.append("physics: \(anchored) very heavy bodies follow their bones (jolt)") }
        guard let w = jolt_puppet_world_create(&t, Int32(bodies.count + 1)) else {
            throw PhysicsWorld.BuildError(description: "jolt: could not create the world")
        }
        world = w
        func t3(_ v: SIMD3<Float>) -> (Float, Float, Float) { (v.x, v.y, v.z) }
        func t4(_ q: simd_quatf) -> (Float, Float, Float, Float) { (q.imag.x, q.imag.y, q.imag.z, q.real) }
        for (i, b) in bodies.enumerated() {
            var d = jolt_puppet_body_desc()
            d.shape = b.shape
            d.size = t3(b.size)
            d.position = t3(b.position)
            d.rotation = t4(b.rotation)
            d.mass = b.mass
            d.linear_damping = b.linearDamping
            d.angular_damping = b.angularDamping
            d.friction = b.friction
            d.restitution = b.restitution
            d.group = UInt16(1) << UInt16(min(b.group, 15))
            d.mask = b.mask
            d.ccd = b.mass > 0 ? ccd : 0
            guard jolt_puppet_world_add_body(w, &d) == Int32(i) else {
                jolt_puppet_world_destroy(w)
                throw PhysicsWorld.BuildError(description: "jolt: could not add rigid body \(i)")
            }
        }
        if let floorGroup {
            var d = jolt_puppet_body_desc()
            d.shape = 1
            d.size = (1, 1, 1)
            d.position = (0, -1.0e4, 0)
            d.rotation = (0, 0, 0, 1)
            d.friction = 0.5
            d.group = UInt16(1) << UInt16(min(floorGroup, 15))
            d.mask = 0xffff
            let index = jolt_puppet_world_add_body(w, &d)
            if index >= 0 { floorIndex = Int(index) }
        }
        var skipped = 0
        for j in joints {
            var d = jolt_puppet_joint_desc()
            d.body_a = j.a
            d.body_b = j.b
            d.position = t3(j.position)
            // PMX のジョイントの向きは Ry·Rx·Rz
            d.rotation = t4(Math.quatEulerYXZ(j.euler.y, j.euler.x, j.euler.z))
            d.translation_lower = t3(j.translationLower)
            d.translation_upper = t3(j.translationUpper)
            d.rotation_lower = t3(j.rotationLower)
            d.rotation_upper = t3(j.rotationUpper)
            d.spring_translation = t3(j.springTranslation)
            d.spring_rotation = t3(j.springRotation)
            d.side = j.side && (k["side"] ?? 1) != 0 ? 1 : 0
            if jolt_puppet_world_add_joint(w, &d) < 0 { skipped += 1 }
        }
        if skipped > 0 { notes.append("physics: \(skipped) joints could not be added (jolt)") }
        jolt_puppet_world_finish(w)
        notes.append("physics: jolt")
    }

    deinit { jolt_puppet_world_destroy(world) }

    /// キネマティックは次の `step` でそこへ動かし、動く剛体はすぐ移す。
    func setTransform(_ i: Int, _ p: SIMD3<Float>, _ q: simd_quatf) {
        var pos = SIMD4(p, 0), rot = q.vector
        withUnsafePointer(to: &pos) { pp in
            withUnsafePointer(to: &rot) { rp in
                pp.withMemoryRebound(to: Float.self, capacity: 4) { p4 in
                    rp.withMemoryRebound(to: Float.self, capacity: 4) { r4 in jolt_puppet_world_set_transform(world, Int32(i), p4, r4) }
                }
            }
        }
    }

    func transform(_ i: Int) -> (SIMD3<Float>, simd_quatf) {
        var pos = SIMD4<Float>(0, 0, 0, 0), rot = SIMD4<Float>(0, 0, 0, 1)
        withUnsafeMutablePointer(to: &pos) { pp in
            withUnsafeMutablePointer(to: &rot) { rp in
                pp.withMemoryRebound(to: Float.self, capacity: 4) { p4 in
                    rp.withMemoryRebound(to: Float.self, capacity: 4) { r4 in jolt_puppet_world_get_transform(world, Int32(i), p4, r4) }
                }
            }
        }
        return (SIMD3(pos.x, pos.y, pos.z), simd_quatf(vector: rot))
    }

    func step(_ dt: Float, _ substeps: Int32) { jolt_puppet_world_step(world, dt, substeps) }
    func settle() { jolt_puppet_world_settle(world) }
    func reset() { jolt_puppet_world_reset(world) }

    func setBox(_ i: Int, _ half: SIMD3<Float>) {
        var h = SIMD4(half, 0)
        withUnsafePointer(to: &h) { $0.withMemoryRebound(to: Float.self, capacity: 4) { jolt_puppet_world_set_box(world, Int32(i), $0) } }
    }

    func setGravity(_ g: SIMD3<Float>) {
        var v = [g.x, g.y, g.z]
        jolt_puppet_world_set_gravity(world, &v)
    }
}
