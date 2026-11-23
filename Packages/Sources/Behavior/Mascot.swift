import MascotCore
import Foundation
import simd

/// 行動 AI。UI にも描画にも依存しない。
public final class Mascot {
    enum State: Equatable {
        case idle
        case pressing(start: SIMD2<Float>, part: Part, grab: SIMD2<Float>)
        case dragging(grab: SIMD2<Float>)
        case falling
        case reacting(Reaction, left: Float)
    }

    enum Reaction: Equatable { case giggle, surprised, petted, landed, waving }

    var state: State = .idle
    var activity: Activity = .standing(left: 3)
    var needs = Needs()
    var boredom: Float {
        get { needs.boredom }
        set { needs.boredom = newValue }
    }
    var sleepiness: Float {
        get { needs.sleepiness }
        set { needs.sleepiness = newValue }
    }
    var lastPointer: SIMD2<Float>?
    var userActive = false
    var pendingGesture: Int?
    var pendingVisit: Int?
    var visited: Set<Int> = []
    var lastVisit: Float = -1000
    var draggedAway = false
    /// どかされたときの呼び出し。状態が変わるまでは呼びに行かない。
    var dismissedCall: AgentState?
    var spaceAskedAt: Float?
    var lookRequested = false
    var greeted = false
    var wasAsleep = false
    var releaseY: Float?
    var flicker: (expression: Expression, weight: Float, left: Float)?
    var nextFlicker: Float = 5
    // コアの同梱の仕草の数と同じ
    static let gestureCount = 8
    var lastRoot: SIMD2<Float>?
    var lastRootSpeed: Float?
    static let frameDt: Float = 1.0 / 60.0
    var facing: Float = 0
    var expressions = [Float](repeating: 0, count: Expression.allCases.count)
    var strokes: [Float] = []
    var lastStrokeDirection: Float = 0
    var lastLocation: SIMD2<Float>?
    var lastAgent = AgentState.none
    var speech: String?
    var speechLeft: Float = 0
    /// 声で話すセリフ。口は声に合わせるので、吹き出しの口パクはしない。
    var speechVoiced = false

    /// MCP・App Intents から頼める演出。
    public enum Performance: String, CaseIterable, Sendable {
        case wave, bigWave, bow, beckon, reply, bothHandsWave, cheer, dance, nod, stretch, hop
    }

    var pendingHop: Float = 0

    /// 端末内の言語モデルのツールが頼む行動。
    public enum Request: Equatable, Sendable {
        case gesture(String), prop(Prop), sit, dance
    }

    var pendingRequest: (request: Request, at: Float)?

    /// `内容:演じ分け` の形。
    public var gestureNames: [String] = []
    /// 曲の id → 振りの番号。
    public var songDances: [String: Int] = [:]
    /// `[あ, い, う, え, お]`。
    public var lips: [Float]?
    var lipState: [Float] = [0, 0, 0, 0, 0]
    /// 1 なら口は声（歌）だけで動き、表情の口は使わない。
    var voiceMouth: Float = 0
    var recentGestures: [Int] = []

    var acting: (weights: [Float], left: Float)?

    var agentTimer: Float = 0
    var time: Float = 0
    var sitRequested = false
    var hugRequested = false
    var dozeUntil: Float = -1
    /// 立って待つ時間に掛ける。
    public var restScale: Float = 1
    var idleMotion: Motion = .idle
    var gestureProp: Prop?
    var danceLegs: DanceLegs?
    var recentArms: [DanceArms] = []
    var danceBeats = 0
    var lastDancePhase: Float = 0
    var lastHopPhase: Float = 0
    var danceFacing: Float = 0
    var danceMood = 0
    var faceBeat = 0
    var facePhase: Float = 0
    var danceTurn: (start: Int, from: Float, to: Float, beats: Float)?
    var danceRest: Float = 0
    var phraseBars = 0
    var danceSection = 0
    var sectionChanged = false
    var lastBeatInBar: Int?
    var noticeGesture: Int?
    var pendingNotice: String?
    var lastProp: Prop?
    var routeNext: Int?
    struct Perch: Equatable { var surface: Int; var x: Float }
    var perch: Perch?
    var perchSit = false
    var sitT: Float = 0
    /// 承認待ちの間に出す吹き出し。
    public var permissionLine: String?
    var phoneLeft: Float = 0
    var phoneTime: Float = 0
    var sitMotion: Motion = .sit
    var walkMotion: Motion?
    let random: () -> Float

    static let dragThreshold: Float = 0.6
    static let strokesToPet = 3
    static let strokeWindow: Float = 1.2
    static let waveSeconds: Float = 3.0

    /// - Parameter random: 0〜1 の乱数（テストで差し込む）。
    public init(random: @escaping () -> Float = { Float.random(in: 0..<1) }) {
        self.random = random
    }

    public func update(dt: Float, pointer: Pointer, body: Body, world: World = World(), agent: Agent = Agent()) -> Intent {
        let agent = unlessDismissed(agent)
        time += dt
        var intent = Intent()
        var target = [Float](repeating: 0, count: Expression.allCases.count)
        let moved = lastLocation.map { pointer.location - $0 } ?? .zero
        lastLocation = pointer.location
        lastPointer = pointer.location
        let touched = pointer.part != nil || pointer.pressed
        tickReaction(dt: dt)
        if pendingHop > 0 {
            intent.hop = pendingHop
            pendingHop = 0
        }

        if simd_length(pointer.location - body.root) < body.height * 4 {
            intent.look = pointer.location
        }

        if let r = lastRoot, dt > 0 { lastRootSpeed = simd_length(body.root - r) / dt }
        lastRoot = body.root
        greet(body: body)
        react(pointer: pointer, moved: moved, body: body, intent: &intent, target: &target)
        updateDesires(dt: dt, world: world, touched: touched)

        let heldBefore = activity.holdsBody || perch != nil
        if state == .idle || isReacting {
            act(dt: dt, body: body, world: world, agent: agent, intent: &intent, target: &target)
        } else {
            activity = .standing(left: 2)
            perch = nil
        }
        // 固定していた活動から抜けたら、つまんでいない限り必ず離す
        if heldBefore, !activity.holdsBody, perch == nil, intent.drag == .none, !isDragging {
            intent.drag = .release
            if case .standing = activity { activity = .dropping }
        }
        if intent.motion == .idlePhone { intent.look = body.root + [0, -body.height * 0.5] }
        expressAgent(dt: dt, agent: agent, body: body, intent: &intent, target: &target)
        speechLeft = max(0, speechLeft - dt)
        if intent.bubble == nil, speechLeft > 0, let speech { intent.bubble = speech }
        expressMood(dt: dt, pointer: pointer, body: body, target: &target)
        if intent.bubble != nil, lips == nil, !speechVoiced {
            let vowels: [Expression] = [.mouthOpen, .mouthI, .mouthU, .mouthE, .mouthO]
            let beat = time / 0.16
            let vowel = vowels[Int(beat * 1.7) % vowels.count]
            let open = max(0, sin(beat.truncatingRemainder(dividingBy: 1) * .pi)) * 0.7
            target[vowel.rawValue] = max(target[vowel.rawValue], open)
        }
        if case .reacting(.waving, _) = state, case .standing = activity {
            intent.motion = .wave
            intent.walkVelocity = 0
            intent.facing = 0
        }

        let dancing: Bool = { if case .dancing = activity { return true }; return false }()
        let k = 1 - exp(-dt * (dancing ? 25 : 4.5))
        facing += (intent.facing - facing) * k
        intent.facing = facing
        if abs(facing - targetFacing(intent)) > 0.35 { intent.walkVelocity = 0 }

        let moving = expressions.indices.first {
            $0 != Expression.eyesClosed.rawValue && abs(target[$0] - expressions[$0]) > 0.02
        }
        let expressive = moving != nil
        let movingText = moving.map { "expression \(Expression(rawValue: $0).map { "\($0)" } ?? "\($0)") \(String(format: "%.2f→%.2f", expressions[$0], target[$0]))" } ?? ""
        let ke = 1 - exp(-dt * 10)
        for i in expressions.indices { expressions[i] += (target[i] - expressions[i]) * ke }
        intent.expressions = expressions
        let mouths = [Expression.mouthOpen, .mouthI, .mouthU, .mouthE, .mouthO].map(\.rawValue)
        let want = (lips ?? [0, 0, 0, 0, 0]).map { $0 * 0.85 }
        voiceMouth += ((lips == nil ? 0 : 1) - voiceMouth) * (1 - exp(-dt * 12))
        for (k, i) in mouths.enumerated() {
            let rate: Float = want[k] > lipState[k] ? 40 : 16
            lipState[k] += (want[k] - lipState[k]) * (1 - exp(-dt * rate))
            let face = max(intent.expressions[i], lipState[k])
            intent.expressions[i] = face + (lipState[k] - face) * voiceMouth
        }
        let busy = state != .idle || pointer.part != nil || expressive
            || activity.moving || agent.state.needsUser
        busyReason = state != .idle ? "state \(state)" : pointer.part != nil ? "pointer"
            : activity.moving ? "moving" : agent.state.needsUser ? "agent"
            : movingText
        intent.frameRate = intent.sleeping && !busy ? .sleep : busy ? .active : activity.still ? .still : .idle
        intent.lookForSpace = lookRequested
        lookRequested = false
        return intent
    }

    /// フレームレートを上げている理由（診断用）。
    public private(set) var busyReason = ""

    var lastHeard: (any: Float, each: [SoundEvent: Float]) = (-.infinity, [:])

}
