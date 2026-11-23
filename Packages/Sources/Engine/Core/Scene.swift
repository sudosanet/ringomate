import Foundation
import simd

public final class Scene: @unchecked Sendable {
    /// 座標は画面の左下を原点にした MMD 単位。
    public struct Inputs: Sendable {
        public var look: SIMD2<Float>?
        /// 0: なし、1: つかんで動かす（足元の目標位置）、2: 離す、3: ウィンドウの上に立つ（固定するが空中扱いしない）。
        public var drag: UInt32 = 0
        public var dragTo = SIMD2<Float>.zero
        public var hop: Float = 0
        public var expressions = [Float](repeating: 0, count: Expression.count)
        public var motion: Slot = .idle
        public var facing: Float = 0
        public var walkVelocity: Float = 0
        public var sleeping = false
        public var prop: PropKind?
        public var beat: Beat?
        public var song: SongPlay?
        public var point: SIMD2<Float>?
        public var surfaces: [SIMD3<Float>] = []

        public init() {}
    }

    public struct Output: Sendable {
        public var root: SIMD2<Float>
        public var grounded: Bool
        public var motionDone: Bool
        public var frozen: Bool
        /// x・y・大きさ。
        public var puffs: [SIMD3<Float>]
        /// 最小 x・y、最大 x・y（画面の空間）。
        public var bounds: [Float]
        public var onLedge = false
        public var floor: Float?
        public var head: SIMD2<Float>?
    }

    final class State {
        let character: Puppet
        var env: Environment
        let gestures: UInt8
        let gestureProps: [PropKind?]
        var falling = false, thrown = false
        var landLeft: Float = 0
        var airTime: Float = 0
        var perched = false

        init(character: Puppet, env: Environment, gestures: UInt8, gestureProps: [PropKind?]) {
            (self.character, self.env, self.gestures, self.gestureProps) = (character, env, gestures, gestureProps)
        }
    }

    var state: State?
    var pending: State?
    var stage = SIMD2<Float>(100, 0)
    let lock = NSLock()

    public init() {}

    public var character: Puppet? { lock.withLock { state?.character } }

    /// 0〜1 の進み具合と、いまの段階の説明。
    public typealias Progress = (Float, String) -> Void

    public func load(model url: URL, library: URL?, progress: Progress? = nil) throws -> ModelData {
        let t = Date()
        progress?(0, String(localized: "Reading the file", bundle: #bundle))
        let loaded = try LoadedModel.load(url)
        return try load(loaded, library: library, importSeconds: Date().timeIntervalSince(t), progress: progress)
    }

    func load(_ loaded: LoadedModel, library: URL?, importSeconds: Double = 0, progress: Progress? = nil) throws -> ModelData {
        var lap = Date(), laps: [String] = ["import \(Int(importSeconds * 1000))ms"]
        func mark(_ name: String) {
            laps.append("\(name) \(Int(Date().timeIntervalSince(lap) * 1000))ms")
            lap = Date()
        }
        // ponytail: 段階の重みは決め打ち（焼き込みのキャッシュがないときの目安）
        func report(_ from: Float, _ to: Float, _ stage: String) -> (Float) -> Void {
            { progress?(from + (to - from) * $0, stage) }
        }
        report(0.15, 0.2, String(localized: "Preparing the shape", bundle: #bundle))(0)
        var model = loaded
        if Optimize.enabled("vertex_cache") {
            Optimize.optimizeVertexCache(&model.pmx)
            model.key += "-vc1"
        }
        let face = model.faceMaterials.sorted().map { model.pmx.materials[$0].name }
        if Optimize.enabled("seam_normals") {
            let seams = Optimize.weldSeamNormals(&model.pmx, skip: face, maxDegrees: 40)
            if seams > 0 { model.diagnostics.append("seam normals averaged: \(seams) vertices") }
        }
        let faces = Optimize.enabled("face_normals") ? Optimize.faceNormals(&model.pmx, names: face) : 0
        if faces > 0 { model.diagnostics.append("face normals edited: \(faces) vertices") }
        mark("optimize")
        let cache = library.flatMap { BakeCacheFile.url(model, library: $0) }
        let clips: [(Slot, BakedClip)]
        if let cached = BakeCacheFile.read(cache, boneCount: model.pmx.bones.count) {
            model.diagnostics.append("motions: from the bake cache")
            clips = cached
        } else {
            clips = try MotionLibrary.bake(model, library: library, progress: report(0.2, 0.55, String(localized: "Fitting motions", bundle: #bundle)))
            BakeCacheFile.write(cache, clips)
        }
        mark("clips")
        report(0.55, 0.6, String(localized: "Preparing props", bundle: #bundle))(0)
        let gestures = UInt8(clips.filter { if case .gesture = $0.0 { true } else { false } }.count)
        if let library {
            let seat = clips.first { $0.0 == .sit }.flatMap { Props.seatHeight($0.1, model.pmx) }
            Props.add(to: &model, library: library, seat: seat)
        }
        mark("props")
        report(0.6, 0.65, String(localized: "Building the body", bundle: #bundle))(0)
        let c = Puppet(model)
        for (slot, clip) in clips { c.setBaked(slot, clip) }
        mark("character")
        let danceCache = cache?.deletingPathExtension().appendingPathExtension("dances")
        let dances = BakeCacheFile.read(danceCache, boneCount: model.pmx.bones.count)
        let built = Self.build(c, dances: dances, progress: report(0.65, 0.95, String(localized: "Making dances and gestures", bundle: #bundle)))
        if dances == nil { BakeCacheFile.write(danceCache, built) }
        mark("build")
        report(0.95, 1, String(localized: "Finishing up", bundle: #bundle))(0)
        var data = ModelData(c)
        data.poses = c.samplePoses(4)
        mark("data")
        data.diagnostics.append("load timing: " + laps.joined(separator: ", "))
        let stage = lock.withLock { self.stage }
        let home = SIMD2(max(stage.x - data.height * 0.6, data.height * 0.6), stage.y)
        var env = Environment(height: data.height, root: home)
        env.setStage(width: stage.x, ground: stage.y)
        var intent = Intent()
        intent.root = SIMD3(home, 0)
        c.teleport(intent)
        let props = c.gestureNames.map(PropKind.forGesture)
        lock.withLock { pending = State(character: c, env: env, gestures: gestures, gestureProps: props) }
        return data
    }

    @discardableResult
    static func build(_ c: Puppet, dances cached: [(Slot, BakedClip)]? = nil, progress: (Float) -> Void = { _ in }) -> [(Slot, BakedClip)] {
        c.relaxFingers()
        if let clip = c.buildHug() { c.setBaked(.hug, clip) }
        for (slot, style) in [(Slot.beatStep, 0), (.beatClap, 1), (.beatPoint, 2)] {
            if let clip = c.buildBeatDance(style) {
                c.setBaked(slot, clip)
                c.setTempo(slot, 120)
            }
        }
        // IK の覚えている値を残さない（キャッシュの有無で結果を変えない）
        var dances = cached ?? []
        if cached == nil {
            let history = c.eval.ikMemory
            for (l, legs) in Dance.legs.enumerated() {
                progress(Float(l) / Float(Dance.legs.count) * 0.8)
                for (a, arms) in Dance.arms.enumerated() {
                    if let clip = c.buildDance(legs, arms) { dances.append((.dance(Dance.index(legs: l, arms: a)), clip)) }
                }
            }
            c.eval.ikMemory = history
        }
        for (slot, clip) in dances {
            c.setBaked(slot, clip)
            c.setTempo(slot, 120)
        }
        progress(0.8)
        if let clip = c.buildClimb() { c.setBaked(.climb, clip) }
        if let clip = c.buildMantle() { c.setBaked(.mantle, clip) }
        if let clip = c.buildSitSwing() { c.setBaked(.sitSwing, clip) }
        for (slot, base, hold) in [(Slot.idlePhone, Slot.idle, Hold.phone), (.sitRead, .sit, Hold.book)]
            + Hold.styles.map({ ($0.0, Slot.idle, $0.1) }) {
            if let clip = c.buildHolding(base, hold) { c.setBaked(slot, clip) }
        }
        c.levelHeads()
        c.capturePropSpots()
        c.fitGround()
        return dances
    }

    public func danceHasMouth(_ index: UInt16) -> Bool { lock.withLock { state?.character.hasMouthKeys(.dance(index)) ?? false } }

    public func commitLoad() {
        lock.withLock {
            if let p = pending {
                state = p
                pending = nil
            }
        }
    }

    /// 読み込み済みと読み込み途中のモデルを捨てる（物理の world も一緒に壊れる）
    public func unload() {
        lock.withLock { (state, pending) = (nil, nil) }
    }

    public func setStage(width: Float, ground: Float) {
        lock.withLock {
            stage = SIMD2(width, ground)
            guard let st = state else { return }
            st.env.setStage(width: width, ground: ground)
            let r = st.env.root
            let margin: Float = 2
            if r.x < margin || r.x > width - margin || r.y < ground {
                let x = Math.clamp(r.x, margin, max(width - margin, margin))
                st.env.place(x, ground)
                var intent = Intent()
                intent.root = SIMD3(x, ground, 0)
                st.character.teleport(intent)
            }
        }
    }

    public func crossScreen(dx: Float, width: Float, ground: Float) {
        lock.withLock {
            stage = SIMD2(width, ground)
            guard let st = state else { return }
            let x = Math.clamp(st.env.root.x + dx, 1, max(width - 1, 1))
            st.env.setStage(width: width, ground: ground)
            st.env.place(x, ground)
            var intent = Intent()
            intent.root = SIMD3(x, ground, 0)
            st.character.teleport(intent)
        }
    }

    public func teleport(x: Float, y: Float) {
        lock.withLock {
            guard let st = state else { return }
            st.env.place(x, y)
            var intent = Intent()
            intent.root = SIMD3(x, y, 0)
            intent.facing = st.character.facing
            st.character.teleport(intent)
        }
    }

    @discardableResult
    public func playComposed(_ json: String) throws -> String {
        let keys = try Compose.keyframes(json: json)
        return try lock.withLock {
            guard let st = state else { throw Failure("no model") }
            guard let clip = st.character.buildComposed(keys) else { throw Failure("no usable motion") }
            st.character.setBaked(.composed, clip)
            return "\(clip.mapped) bones, \(clip.frames.count) frames"
        }
    }

    /// `front` は度。
    public func assignSongDance(index: UInt16, path: URL, front: Float?) throws {
        let bytes = try BVH.gunzipIfNeeded([UInt8](Data(contentsOf: path)))
        let name = path.path.lowercased()
        if name.hasSuffix(".vmd") || name.hasSuffix(".vmd.gz") {
            guard let puppet = character else { throw Failure("no model") }
            let clip = try puppet.makeVMD(bytes)
            try lock.withLock {
                guard state?.character === puppet else { throw Failure("the model changed while reading") }
                puppet.setVMD(.dance(index), clip)
            }
            return
        }
        var raw = name.hasSuffix(".glb") ? try BVH.readMotionGLB(bytes) : try BVH.parse(String(decoding: bytes, as: UTF8.self))
        if Optimize.enabled("dance_flips") { DanceFlips.repair(&raw) }
        let (skel, clip) = try BVH.clipRest(raw, name: "song", front: front)
        guard let puppet = character else { throw Failure("no model") }
        var baked = Retarget.bake(skel, clip, puppet.model.pmx, puppet.model.profile.aliases)
        let root = baked.takeRootX()
        baked.stayInPlace(1.5)
        try lock.withLock {
            guard state?.character === puppet else { throw Failure("the model changed while baking") }
            puppet.setBaked(.dance(index), baked)
            puppet.setRootTrack(.dance(index), root, fps: baked.fps)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    static let airSeconds: Float = 0.5

    public func step(_ dt: Float, _ inputs: Inputs) -> Output? {
        lock.withLock {
            guard let st = state else { return nil }
            let c = st.character
            st.env.setPlatforms(inputs.surfaces)
            if inputs.hop > 0 { st.env.hop(inputs.hop) }
            let perched = inputs.drag == 3
            if inputs.drag == 2 && st.perched { st.env.dropThrough() }
            st.perched = perched
            let drag: Environment.Drag = switch inputs.drag {
            case 1, 3: .hold(x: inputs.dragTo.x, y: inputs.dragTo.y)
            case 2: .release
            default: .none
            }
            st.env.walk(inputs.walkVelocity + c.rootMotion)
            let r = st.env.step(dt, drag)
            let requested = inputs.motion
            let free: Bool = switch requested {
            case .idle, .walk, .walkCalm, .gesture, .composed: true
            default: false
            }
            let v = st.env.velocity
            let speed = (v.x * v.x + v.y * v.y).squareRoot()
            st.airTime = st.env.airborne && !perched ? st.airTime + dt : 0
            let airborne = st.env.airborne && !st.env.held
            var air: Slot?
            if perched {
                (st.falling, st.thrown) = (false, false)
            } else if st.env.held {
                (st.falling, st.thrown) = (false, false)
                air = .fall
            } else if airborne && (st.airTime > Self.airSeconds || st.falling || speed > 45) {
                if !st.falling && !st.thrown {
                    st.thrown = speed > 45
                    st.falling = !st.thrown
                }
                air = st.thrown ? .thrown : .falling
            } else {
                if st.falling || st.thrown { st.landLeft = c.duration(of: .land) }
                (st.falling, st.thrown) = (false, false)
            }
            st.landLeft = max(st.landLeft - dt, 0)
            let motion: Slot
            let idleOrGesture: Bool = switch requested {
            case .idle, .gesture: true
            default: false
            }
            if free, let air {
                motion = air
            } else if free && st.landLeft > 0 && idleOrGesture {
                motion = .land
            } else if case let .gesture(i) = requested {
                motion = st.gestures == 0 ? .idle : .gesture(i % st.gestures)
            } else {
                motion = requested
            }
            var intent = Intent()
            intent.root = SIMD3(r, 0)
            intent.look = inputs.look.map { SIMD3($0, -40) }
            intent.expressions = inputs.expressions
            intent.motion = motion
            intent.facing = inputs.facing
            intent.sleeping = inputs.sleeping
            intent.held = st.env.held && !perched
            intent.beat = inputs.beat.flatMap { $0.bpm > 0 ? $0 : nil }
            intent.point = inputs.point.map { SIMD3($0, -10) }
            intent.song = inputs.song.flatMap { $0.clipTime >= 0 && $0.rate > 0 ? $0 : nil }
            intent.surfaces = inputs.surfaces + [SIMD3(-1.0e4, 1.0e4, st.env.ground)]
            if let k = inputs.prop, k.grip != nil {
                intent.prop = k
            } else if case let .gesture(i) = motion, Int(i) < st.gestureProps.count {
                intent.prop = st.gestureProps[Int(i)]
            }
            c.step(dt, intent)
            let lift = max(c.stature, 1) * 0.1
            let floor = intent.surfaces.filter { $0.x <= r.x && r.x <= $0.y && $0.z <= r.y + lift }.map(\.z).max()
            return Output(root: r, grounded: st.env.grounded, motionDone: c.motionFinished, frozen: c.frozen,
                          puffs: Array(c.takePuffs().prefix(4)), bounds: c.bounds, onLedge: st.env.onLedge, floor: floor, head: c.head)
        }
    }
}
