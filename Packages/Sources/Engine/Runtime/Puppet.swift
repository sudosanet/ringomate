import Foundation
import simd

/// 座標は画面の左下を原点にした MMD 単位。
public struct Intent: Sendable {
    public var root = SIMD3<Float>.zero
    public var look: SIMD3<Float>?
    /// `Expression` の順。
    public var expressions = [Float](repeating: 0, count: Expression.count)
    public var motion = Slot.idle
    /// Y 軸回り、ラジアン。
    public var facing: Float = 0
    public var sleeping = false
    /// ウィンドウの座面に固定されているときも true。
    public var held = false
    public var prop: PropKind?
    public var beat: Beat?
    public var point: SIMD3<Float>?
    public var song: SongPlay?
    /// (左端, 右端, 上端)、画面の座標。
    public var surfaces: [SIMD3<Float>] = []

    public init() {}
}

public struct SongPlay: Sendable, Equatable {
    public var clipTime: Float, rate: Float
    public init(clipTime: Float, rate: Float) { (self.clipTime, self.rate) = (clipTime, rate) }
}

public struct Beat: Sendable, Equatable {
    public var bpm: Float, phase: Float, energy: Float
    /// 組んだ振りのクリップの中でいるべき位置（拍）。
    public var clip: Float?
    public init(bpm: Float, phase: Float, energy: Float, clip: Float?) {
        (self.bpm, self.phase, self.energy, self.clip) = (bpm, phase, energy, clip)
    }
}

public final class Puppet {
    static let settleSeconds: Float = 2
    static let settleEpsilon: Float = 0.005
    static let gravity = SIMD3<Float>(0, -98, 0)
    static let maxRootAccel: Float = 600

    public let model: LoadedModel
    let runtime: RuntimeModel
    let eval: Evaluator
    var tempos: [Slot: Float?] = [:]
    var faceSlots: Set<Slot> = []
    var clipFace: Float = 0
    var mouthSlots: Set<Slot> = []
    var rate: Float = 1
    var feetRef: [(Int, Float)] = []
    var drop: Float = 0, dropSpeed: Float = 0, lastGap: Float = 0, leap: Float = 0, stature: Float = 0
    var motions: [Slot: BakedClip] = [:]
    var player = Player()
    let toeIKs: [Int]
    let legIKs: [Int]
    let kneeSeeds: [(Int, simd_quatf)]
    let danceWobble: [(Int, SIMD3<Float>, Float)]
    var danceTime: Float = 0
    var settled: Float = 0
    var lastPositions: [SIMD3<Float>] = []
    let vertexMorphs: [Int]
    var procedural: Procedural
    var root = SIMD3<Float>.zero
    public internal(set) var facing: Float = 0
    var rootVelocity: SIMD3<Float>?
    var rootTracks: [Slot: ([Float], Float)] = [:]
    internal(set) var rootMotion: Float = 0
    var headLevel: [Slot: simd_quatf] = [:]
    var headCorrection = Math.identity
    var pointWeight: Float = 0
    var pointTarget = SIMD3<Float>.zero
    lazy var body: BodyShape? = bodyShape()
    var ground: Float = 0
    var bust: Bust
    var props: PropPlacement
    var puffs: [SIMD3<Float>] = []
    public var diagnostics: [String] = []
    var physics: PhysicsWorld?
    var physicsRestarts = 0
    /// ならす前の前のフレームの物理の結果。
    var lastTargets: [simd_float4x4?] = []
    var attachedBodies: Set<Int> = []
    var clock = PhysicsClock()
    let hz = Puppet.physicsHz()
    var substep: Float = 1.0 / 120
    var restReach: Float?

    /// 骨の評価は物理の直しの前の PMX から作る。
    public init(_ loaded: LoadedModel) {
        var model = loaded
        let runtime = RuntimeModel(model.pmx)
        self.runtime = runtime
        eval = Evaluator(runtime)
        var diagnostics: [String] = []
        let aliases = model.profile.aliases
        func bone(_ n: String) -> Int? { Retarget.bone(model.pmx, aliases, [n]) }
        if Optimize.enabled("physics_fix") {
            let broken = Optimize.removeBrokenJoints(&model.pmx)
            if broken > 0 { diagnostics.append("physics: removed \(broken) broken or duplicate joints") }
            let overlaps = Optimize.excludeRestOverlaps(&model.pmx)
            if overlaps > 0 {
                diagnostics.append("physics: \(overlaps) linked rigid-body pairs overlapping at rest no longer collide")
            }
            let legs = ["左足", "右足", "左ひざ", "右ひざ", "左足D", "右足D", "左ひざD", "右ひざD"].compactMap(bone)
            let scale = model.profile.physics.legColliderScale
            let widened = Optimize.widenLegColliders(&model.pmx, legBones: legs, scale: scale)
            if widened > 0 { diagnostics.append("physics: leg colliders x\(scale) (\(widened) bodies)") }
            let tuning = model.profile.physics
            let wider = Optimize.widenJoints(&model.pmx, bodies: Optimize.bodies(model.pmx, prefixes: tuning.widen), factor: tuning.widenFactor)
            if wider > 0 { diagnostics.append("physics: \(wider) joints widened ×\(tuning.widenFactor) (profile)") }
            let loosened = Optimize.loosenLockedJoints(&model.pmx, bodies: Optimize.bodies(model.pmx, prefixes: tuning.loosen), degrees: tuning.loosenDegrees)
            if loosened > 0 { diagnostics.append("physics: \(loosened) locked joints loosened (profile)") }
        }
        bust = Bust(&model.pmx)
        if !bust.bones.isEmpty {
            diagnostics.append("bust: \(bust.bones.map { model.pmx.bones[$0].name }.joined(separator: ", ")) (spring, bust bodies follow bones)")
        }
        if Optimize.enabled("attach_locked") {
            let (tails, candidates) = Optimize.attachLockedTails(&model.pmx, force: Optimize.bodies(model.pmx, prefixes: model.profile.physics.attach))
            attachedBodies = tails
            if !tails.isEmpty { diagnostics.append("physics: \(tails.count) rigid bodies locked to a swinging body now ride on it (physics.attach)") }
            if !candidates.isEmpty { diagnostics.append("physics: locked tails on swinging bodies (physics.attach candidates): \(candidates.joined(separator: ", "))") }
        }
        let rigid = Optimize.enabled("rigidify") ? Optimize.rigidifyLockedChains(&model.pmx) : 0
        if rigid > 0 { diagnostics.append("physics: \(rigid) rigid bodies on fully locked joints now follow their bones") }
        let physicsLines = diagnostics.count
        vertexMorphs = model.pmx.morphs.indices.filter { model.pmx.morphs[$0].kind == "vertex" && !model.pmx.morphs[$0].vertexOffsets.isEmpty }
        procedural = Procedural(model.pmx, aliases)
        let propList: [(PropKind, Int, SIMD3<Float>)] = PropKind.allCases.compactMap { k in
            model.pmx.bones.firstIndex { $0.name == k.boneName }.map { (k, $0, model.pmx.bones[$0].position) }
        }
        let wrists = ["左手首", "右手首", "左中指１", "右中指１"].map(bone)
        let height = Self.height(model.pmx)
        let knuckles = ["右人指１", "右小指１"].map(bone)
        props = PropPlacement(propList, wrists: wrists, knuckles: knuckles, height: height)
        diagnostics += self.procedural.missing
        toeIKs = runtime.toeIKs
        legIKs = ["左足ＩＫ", "左足IK", "右足ＩＫ", "右足IK"].compactMap { runtime.ikSolver(named: $0) }
        kneeSeeds = model.pmx.bones.filter { ["左足ＩＫ", "左足IK", "右足ＩＫ", "右足IK"].contains($0.name) }.compactMap(\.ik)
            .flatMap(\.links).compactMap { l in
                guard let lim = l.limits, l.boneIndex >= 0 else { return nil }
                let mid = (lim.lower.x + lim.upper.x) / 2
                return abs(mid) > 0.05 ? (Int(l.boneIndex), Math.rotX(0.08 * Math.signum(mid))) : nil
            }
        let wobble: [(String, SIMD3<Float>)] = [
            ("上半身", SIMD3(0.03, 0.05, 0.035)), ("上半身2", SIMD3(0.025, 0.03, 0.02)), ("首", SIMD3(0.03, 0.04, 0.04)),
            ("頭", SIMD3(0.04, 0.06, 0.06)), ("左肩", SIMD3(0, 0, 0.05)), ("右肩", SIMD3(0, 0, 0.05)),
            ("左腕", SIMD3(0.05, 0.04, 0.05)), ("右腕", SIMD3(0.05, 0.04, 0.05)),
        ]
        danceWobble = wobble.enumerated().compactMap { i, w in bone(w.0).map { ($0, w.1, Float(i) * 3.7) } }
        self.model = model
        self.diagnostics = diagnostics
        self.diagnostics.insert(contentsOf: buildPhysics(), at: physicsLines)
    }


    static func height(_ pmx: PMXModel) -> Float {
        stride(from: 1, to: pmx.geometry.positions.count, by: 3).reduce(Float(0)) { max($0, pmx.geometry.positions[$1]) }
    }

    public var height: Float { Self.height(model.pmx) }
    public var boneCount: Int { runtime.boneCount }

    func setBaked(_ slot: Slot, _ clip: BakedClip) {
        diagnostics.append("motion \(slot) <- \(clip.name) (\(clip.mapped) bones mapped)")
        motions[slot] = clip
    }

    /// `track` はコマごとの横の移動（MMD 単位）。
    func setRootTrack(_ slot: Slot, _ track: [Float], fps: Float) { rootTracks[slot] = (track, fps) }

    func setTempo(_ slot: Slot, _ bpm: Float) { tempos[slot] = .some(bpm) }

    /// 秒、なければ 0。
    public func duration(of slot: Slot) -> Float { motions[slot]?.duration ?? 0 }

    /// 足が滑らない前進速度（MMD 単位/s、なければ 0）。
    public func walkSpeed(of slot: Slot) -> Float { motions[slot]?.groundSpeed ?? 0 }
    public var walkSpeed: Float { walkSpeed(of: .walk) }

    /// 足元から座面までの高さ。
    public var seatHeight: Float? { motions[.sit].flatMap { Props.seatHeight($0, model.pmx) } }

    /// (x, y, 大きさ)、画面の空間。
    func takePuffs() -> [SIMD3<Float>] {
        defer { puffs = [] }
        return puffs
    }

    var motionFinished: Bool { player.finished(motions) }

    public var gestureNames: [String] {
        var out: [String] = []
        for i in 0...255 {
            guard let m = motions[.gesture(UInt8(i))] else { break }
            out.append(m.name)
        }
        return out
    }

    func hasMouthKeys(_ slot: Slot) -> Bool { mouthSlots.contains(slot) }

    /// 評価のあとは戻さないので、`teleport` の前に呼ぶ。
    func samplePoses(_ perMotion: Int) -> [[simd_float4x4]] {
        var out: [[simd_float4x4]] = []
        for slot in [Slot.idle, .walk, .sit, .sitDown, .wave, .fall, .falling, .thrown, .land] where motions[slot] != nil {
            let duration = motions[slot]!.duration
            for k in 0..<perMotion {
                var p = Player()
                p.request(slot)
                p.advance(duration * Float(k) / Float(perMotion), motions)
                p.advance(1, motions)
                p.apply(motions, &eval.pose, toeIKs: toeIKs)
                props.hide(&eval.pose)
                eval.expandMorphs()
                eval.evaluate()
                out.append(eval.pose.skinning)
            }
        }
        return out
    }

    var vertexParts: [UInt8] { Procedural.vertexParts(model.pmx, model.profile.aliases) }

    /// 画面の空間の xy の最小と最大。隠した小道具は数えない。
    public var bounds: [Float] {
        let place = self.place()
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for m in eval.pose.world {
            let p = m.columns.3.xyz
            if p.y < -1.0e3 { continue }
            let q = Math.point(place, p)
            lo = simd_min(lo, SIMD2(q.x, q.y))
            hi = simd_max(hi, SIMD2(q.x, q.y))
        }
        return lo.x > hi.x ? [root.x, root.y, root.x, root.y] : [lo.x, lo.y, hi.x, hi.y]
    }

    /// 頭のボーンの、画面の空間の xy。
    public var head: SIMD2<Float>? {
        guard let h = procedural.head, h < eval.pose.world.count else { return nil }
        let q = Math.point(place(), eval.pose.world[h].columns.3.xyz)
        return SIMD2(q.x, q.y)
    }

    /// 眠ったまま止まっている（描画のフレームレートを落としてよい）。
    public var frozen: Bool { settled >= Self.settleSeconds }

    func place() -> simd_float4x4 { Math.matrix(Math.rotY(facing), root + SIMD3(0, 1, 0) * (ground - drop)) }

    static func physicsHz() -> Float {
        guard let v = Flags.value("MASCOT_PHYSICS_HZ").flatMap(Float.init), v >= 30, v <= 480 else { return 60 }
        return v
    }
}
