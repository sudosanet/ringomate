import CJolt
/// 座標は画面の左下が原点、x 右・y 上、MMD 単位。
struct Environment {
    enum Drag: Sendable, Equatable {
        case none
        case hold(x: Float, y: Float)
        case release
    }

    static let gravity: Float = -122
    static let maxThrow: Float = 150

    var pos: SIMD2<Float>
    var vel = SIMD2<Float>.zero
    var ground: Float = 0
    private(set) var held = false
    var walkSpeed: Float = 0
    private let jolt: JoltEnvironment
    /// −1 は画面の下の床、−2 は何にも乗っていない。
    private(set) var support: Int32 = -2
    private var dropFrom: Float?

    init(height: Float, root: SIMD2<Float>) {
        pos = root
        jolt = JoltEnvironment(radius: max(height * 0.15, 0.5), height: height * 0.8, gravity: Self.gravity, friction: 0.4,
                               restitution: 0.15, damping: 0.05)
        jolt.place(root, .zero)
    }

    mutating func setStage(width: Float, ground: Float) {
        self.ground = ground
        jolt.setStage(width: width, ground: ground)
    }

    mutating func setPlatforms(_ surfaces: [SIMD3<Float>]) {
        if let top = dropFrom, pos.y < top - 0.5 { dropFrom = nil }
        let ignore = dropFrom.flatMap { top in surfaces.firstIndex { abs($0.z - top) < 0.05 && $0.x <= pos.x && pos.x <= $0.y } }
        jolt.setPlatforms(surfaces, ignore: ignore.map(Int32.init) ?? -1)
    }

    mutating func dropThrough() { dropFrom = pos.y }

    mutating func step(_ dt: Float, _ drag: Drag) -> SIMD2<Float> {
        switch drag {
        case let .hold(x, y):
            held = true
            let t = max(dt, 1e-4)
            vel = SIMD2((x - pos.x) / t, (y - pos.y) / t)
            if dt > 0 { pos = SIMD2(x, y) }
            jolt.place(pos, .zero)
            support = -2
            return pos
        case .release, .none:
            if held {
                vel = SIMD2(Math.clamp(vel.x, -Self.maxThrow, Self.maxThrow), Math.clamp(vel.y, -Self.maxThrow, Self.maxThrow))
                held = false
                jolt.place(pos, vel)
            }
        }
        if dt <= 0 { return pos }
        jolt.step(dt, steps: Int32(max((dt * 120).rounded(), 1)), walk: walkSpeed)
        (pos, vel, support) = jolt.state()
        return pos
    }

    mutating func walk(_ vx: Float) { walkSpeed = vx }

    mutating func hop(_ speed: Float) {
        guard grounded else { return }
        vel.y = speed
        jolt.place(pos, vel)
        support = -2
    }

    mutating func place(_ x: Float, _ y: Float) {
        pos = SIMD2(x, y)
        vel = .zero
        jolt.place(pos, .zero)
    }

    var onLedge: Bool { grounded && support >= 0 }

    var root: SIMD2<Float> { pos }
    var velocity: SIMD2<Float> { vel }
    var airborne: Bool { held || abs(vel.y) >= 2 }
    var grounded: Bool { !held && support != -2 && abs(vel.y) < 2 }
}

final class JoltEnvironment {
    private let env: OpaquePointer

    init(radius: Float, height: Float, gravity: Float, friction: Float, restitution: Float, damping: Float) {
        env = jolt_env_create(radius, height, gravity, friction, restitution, damping)
    }

    deinit { jolt_env_destroy(env) }

    func setStage(width: Float, ground: Float) { jolt_env_set_stage(env, width, ground) }

    func setPlatforms(_ surfaces: [SIMD3<Float>], ignore: Int32) {
        let flat = surfaces.flatMap { [$0.x, $0.y, $0.z] }
        flat.withUnsafeBufferPointer { jolt_env_set_platforms(env, $0.baseAddress, Int32(surfaces.count), ignore) }
    }

    func place(_ p: SIMD2<Float>, _ v: SIMD2<Float>) { jolt_env_place(env, p.x, p.y, v.x, v.y) }

    func step(_ dt: Float, steps: Int32, walk: Float) { jolt_env_step(env, dt, steps, walk) }

    func state() -> (SIMD2<Float>, SIMD2<Float>, Int32) {
        var p = SIMD2<Float>.zero, v = SIMD2<Float>.zero, s: Int32 = -2
        withUnsafeMutablePointer(to: &p) { pp in
            withUnsafeMutablePointer(to: &v) { vp in
                pp.withMemoryRebound(to: Float.self, capacity: 2) { p2 in
                    vp.withMemoryRebound(to: Float.self, capacity: 2) { v2 in jolt_env_get(env, p2, v2, &s) }
                }
            }
        }
        return (p, v, s)
    }
}
