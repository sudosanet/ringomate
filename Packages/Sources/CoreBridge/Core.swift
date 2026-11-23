import Engine
import Foundation

/// `prepare` だけは別スレッドから呼んでよい。ほかはメインアクターから使う。
public final class Core: @unchecked Sendable {
    public struct Input {
        public enum Drag: Equatable {
            case none, hold(SIMD2<Float>), release
            case stand(SIMD2<Float>)
        }

        public typealias Motion = Slot

        public var look: SIMD2<Float>?
        public var drag: Drag
        public var hop: Float
        public var expressions: [Float]
        public var motion: Motion
        public var facing: Float
        public var walkVelocity: Float
        public var sleeping: Bool
        public var prop: PropKind?
        public var beat: SIMD3<Float>?
        public var beatClip: Float?
        public var song: (clipTime: Float, rate: Float)?
        public var point: SIMD2<Float>?
        public var surfaces: [SIMD3<Float>] = []

        public init(look: SIMD2<Float>? = nil, drag: Drag = .none, hop: Float = 0, expressions: [Float] = [],
                    motion: Motion = .idle, facing: Float = 0, walkVelocity: Float = 0, sleeping: Bool = false) {
            self.look = look
            self.drag = drag
            self.hop = hop
            self.expressions = expressions
            self.motion = motion
            self.facing = facing
            self.walkVelocity = walkVelocity
            self.sleeping = sleeping
        }
    }

    public struct Output {
        public var bones: Int
        public var root: SIMD2<Float>
        public var grounded: Bool
        public var motionDone: Bool
        public var frozen: Bool
        public var puffs: [SIMD3<Float>] = []
        public var boundsMin = SIMD2<Float>(0, 0)
        public var boundsMax = SIMD2<Float>(0, 0)
        public var onLedge = false
        public var floor: Float?
        public var head: SIMD2<Float>?
    }

    private let scene = Scene()

    public init() {}

    public func load(model: String, library: String? = nil) throws -> ModelData {
        let data = try prepare(model: model, library: library)
        commitLoad()
        return data
    }

    /// `commitLoad` は描画側へ新しいメッシュを渡すのと同時に呼ぶ。
    /// `progress` は裏のスレッドから呼ばれる（0〜1 と段階の説明）。
    public func prepare(model: String, library: String? = nil, progress: (@Sendable (Float, String) -> Void)? = nil) throws -> ModelData {
        try scene.load(model: URL(filePath: model), library: library.map { URL(filePath: $0) }, progress: progress)
    }

    public func commitLoad() {
        drain()
        scene.commitLoad()
    }

    public static func rules() -> (rules: [RuleInfo], errors: [String]) { Resolve.catalog() }

    public static func info(model: String) throws -> ModelInfo {
        try ModelInfo(URL(filePath: model))
    }

    public func textureBytes(_ i: Int) -> Data? {
        scene.textureBytes(i).map { Data($0) }
    }

    public func danceHasMouth(index: Int) -> Bool {
        scene.danceHasMouth(UInt16(index))
    }

    public func playComposed(_ keyframes: String) throws -> String {
        try scene.playComposed(keyframes)
    }

    public func assignSongDance(index: Int, path: String, front: Float? = nil) throws {
        try scene.assignSongDance(index: UInt16(index), path: URL(filePath: path), front: front)
    }

    public func crossScreen(dx: Float, width: Float, ground: Float) {
        drain()
        scene.crossScreen(dx: dx, width: width, ground: ground)
    }

    public func teleport(x: Float, y: Float) {
        drain()
        scene.teleport(x: x, y: y)
    }

    public func setStage(width: Float, ground: Float) {
        scene.setStage(width: width, ground: ground)
    }

    @discardableResult
    public func step(
        dt: Float, input: Input = Input(),
        skin: UnsafeMutableRawBufferPointer, positions: UnsafeMutableRawBufferPointer
    ) -> Output {
        run(dt: dt, inputs: Self.inputs(input), skin: skin, positions: positions)
    }

    private let worker = DispatchQueue(label: "ringomate.step", qos: .userInteractive)
    private var ahead: (skin: UnsafeMutableRawBufferPointer, positions: UnsafeMutableRawBufferPointer)?
    private var pending: Output?

    public func stepAhead(
        dt: Float, input: Input,
        skin: UnsafeMutableRawBufferPointer, positions: UnsafeMutableRawBufferPointer
    ) -> Output {
        let inputs = Self.inputs(input)
        guard skin.baseAddress != nil else {
            drain()
            return run(dt: dt, inputs: inputs, skin: skin, positions: positions)
        }
        if ahead?.skin.count != skin.count || ahead?.positions.count != positions.count {
            drain()
            ahead?.skin.deallocate()
            ahead?.positions.deallocate()
            ahead = (.allocate(byteCount: skin.count, alignment: 16), .allocate(byteCount: positions.count, alignment: 16))
        }
        guard let buffers = ahead else { return run(dt: dt, inputs: inputs, skin: skin, positions: positions) }
        let out: Output
        if let done = worker.sync(execute: { pending }) {
            skin.copyMemory(from: UnsafeRawBufferPointer(buffers.skin))
            positions.copyMemory(from: UnsafeRawBufferPointer(buffers.positions))
            out = done
        } else {
            out = run(dt: dt, inputs: inputs, skin: skin, positions: positions)
        }
        worker.async { [self] in
            pending = run(dt: dt, inputs: inputs, skin: buffers.skin, positions: buffers.positions)
        }
        return out
    }

    deinit {
        drain()
        ahead?.skin.deallocate()
        ahead?.positions.deallocate()
    }

    /// モデルを外す。次に使うのは `prepare`・`commitLoad` のあと
    public func unload() {
        drain()
        scene.unload()
        ahead?.skin.deallocate()
        ahead?.positions.deallocate()
        ahead = nil
    }

    public func drain() {
        worker.sync { pending = nil }
    }

    private static func inputs(_ input: Input) -> Scene.Inputs {
        var inputs = Scene.Inputs()
        inputs.look = input.look
        switch input.drag {
        case .none: inputs.drag = 0
        case let .hold(p): (inputs.drag, inputs.dragTo) = (1, p)
        case .release: inputs.drag = 2
        case let .stand(p): (inputs.drag, inputs.dragTo) = (3, p)
        }
        inputs.hop = input.hop
        inputs.motion = input.motion
        inputs.facing = input.facing
        inputs.prop = input.prop
        inputs.beat = input.beat.map { Beat(bpm: $0.x, phase: $0.y, energy: $0.z, clip: input.beatClip) }
        inputs.song = input.song.map { SongPlay(clipTime: $0.clipTime, rate: $0.rate) }
        inputs.point = input.point
        inputs.surfaces = input.surfaces
        inputs.walkVelocity = input.walkVelocity
        inputs.sleeping = input.sleeping
        for (i, v) in input.expressions.prefix(inputs.expressions.count).enumerated() { inputs.expressions[i] = v }
        return inputs
    }

    private func run(dt: Float, inputs: Scene.Inputs, skin: UnsafeMutableRawBufferPointer,
                     positions: UnsafeMutableRawBufferPointer) -> Output {
        let floats = { (b: UnsafeMutableRawBufferPointer) in
            UnsafeMutableBufferPointer(start: b.baseAddress?.assumingMemoryBound(to: Float.self), count: b.count / MemoryLayout<Float>.stride)
        }
        guard let (out, bones) = scene.step(dt, inputs, skin: floats(skin), positions: floats(positions)) else {
            return Output(bones: 0, root: .zero, grounded: false, motionDone: false, frozen: false)
        }
        return Output(bones: bones, root: out.root, grounded: out.grounded, motionDone: out.motionDone, frozen: out.frozen,
                      puffs: out.puffs, boundsMin: SIMD2(out.bounds[0], out.bounds[1]), boundsMax: SIMD2(out.bounds[2], out.bounds[3]),
                      onLedge: out.onLedge, floor: out.floor, head: out.head)
    }
}
