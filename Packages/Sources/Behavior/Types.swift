import Engine
import MascotCore
import simd

/// 座標はすべて主画面の左下を原点にした MMD 単位。
extension Mascot {
    public typealias Beat = MascotCore.Beat
    public typealias SongPlaying = MascotCore.SongPlaying
    public typealias Environment = MacEnvironment
    public typealias AgentState = MascotCore.AgentState
    public typealias FrameRate = MascotCore.FrameRate

    public enum Part: UInt8, Sendable { case head = 1, torso = 2, hand = 3, foot = 4 }

    public struct Pointer: Sendable {
        public var location: SIMD2<Float>
        public var part: Part?
        public var pressed: Bool
        public var released: Bool

        public init(location: SIMD2<Float>, part: Part?, pressed: Bool = false, released: Bool = false) {
            self.location = location
            self.part = part
            self.pressed = pressed
            self.released = released
        }
    }

    public struct Body: Sendable {
        public var root: SIMD2<Float>
        public var grounded: Bool
        public var height: Float
        /// ボーンの横の広がり。0 なら分からない。
        public var width: Float = 0
        /// 1 回きりのモーションを再生し終えた。
        public var motionDone = false
        /// 0 なら歩かない。
        public var walkSpeed: Float = 0
        /// 足元から座面まで。0 なら座らない。
        public var seatHeight: Float = 0
        /// 0 なら弾む歩きだけ。
        public var calmWalkSpeed: Float = 0
        /// 0 なら箱を運ばない。
        public var carryWalkSpeed: Float = 0
        /// 画面の下の床でない面に止まっている。
        public var onLedge = false

        public init(root: SIMD2<Float>, grounded: Bool, height: Float, motionDone: Bool = false,
                    walkSpeed: Float = 0, seatHeight: Float = 0, calmWalkSpeed: Float = 0,
                    carryWalkSpeed: Float = 0, width: Float = 0) {
            self.width = width
            self.calmWalkSpeed = calmWalkSpeed
            self.carryWalkSpeed = carryWalkSpeed
            self.root = root
            self.grounded = grounded
            self.height = height
            self.motionDone = motionDone
            self.walkSpeed = walkSpeed
            self.seatHeight = seatHeight
        }
    }

    /// ウィンドウの上端。
    public struct Surface: Equatable, Sendable {
        public var id: Int
        public var minX: Float
        public var maxX: Float
        public var top: Float
        /// ウィンドウの下端（足元と同じ座標）。
        public var bottom: Float
        /// 縁の横が隠れておらず、よじ登れる。
        public var climbLeft: Bool
        public var climbRight: Bool

        public init(id: Int, minX: Float, maxX: Float, top: Float, bottom: Float = -.infinity,
                    climbLeft: Bool = true, climbRight: Bool = true) {
            self.id = id
            self.minX = minX
            self.maxX = maxX
            self.top = top
            self.bottom = bottom
            self.climbLeft = climbLeft
            self.climbRight = climbRight
        }
    }

    public struct World: Sendable {
        public var surfaces: [Surface]
        public var width: Float
        public var userIdleSeconds: Double
        /// 現地時刻（0〜23）。
        public var hour: Int
        /// 全画面のアプリが前にあり、隅で静かにする。
        public var keepToCorner: Bool
        /// 端の先に歩いて渡れる画面がある。
        public var exitLeft: Bool
        public var exitRight: Bool
        public var env = Environment()
        /// 上に座れる物は `surfaces` にも同じ id で入る。
        public var things: [Thing] = []
        /// 足もとの帯を左から等分した列のごちゃごちゃ度（0〜1）。空なら分からない。
        public var busy: [Float] = []
        /// 頼めば `busy` を測れる。
        public var canLookForSpace = false

        public init(surfaces: [Surface] = [], width: Float = 100, userIdleSeconds: Double = 0, hour: Int = 12,
                    keepToCorner: Bool = false, exitLeft: Bool = false, exitRight: Bool = false) {
            self.exitLeft = exitLeft
            self.exitRight = exitRight
            self.surfaces = surfaces
            self.width = width
            self.userIdleSeconds = userIdleSeconds
            self.hour = hour
            self.keepToCorner = keepToCorner
        }
    }

    public struct Agent: Equatable, Sendable {
        public var state: AgentState
        /// 座れないか分からなければ nil。
        public var surfaceID: Int?
        /// ほとんど隠れているときは nil。
        public var window: ClosedRange<Float>?
        /// ターミナルより前にあって、足もとにかかる窓の x の範囲。
        public var blocked: [ClosedRange<Float>]

        public init(state: AgentState = .none, surfaceID: Int? = nil, window: ClosedRange<Float>? = nil,
                    blocked: [ClosedRange<Float>] = []) {
            self.blocked = blocked
            self.state = state
            self.surfaceID = surfaceID
            self.window = window
        }

        /// 承認待ち・失敗・終わった直後。
        public var calling: Bool { state.needsUser || state == .failed || state == .done }
    }

    public enum Drag: Equatable, Sendable {
        case none, hold(SIMD2<Float>), release
        /// 足元を固定するが、コアは空中のモーションにしない。
        case stand(SIMD2<Float>)
    }

    /// 仕草は `.gesture(番号)`（8 から図鑑）、振りは `.dance(番号)`。
    public typealias Motion = Slot

    public enum DanceMove: Equatable, Sendable {
        case move(Int)
        case recorded(Int)
        /// 次の小節の頭を待つ。
        case waiting
        /// 曲の位置に合わせて再生する。
        case song

        var isRecorded: Bool {
            if case .recorded = self { return true }
            return false
        }
    }

    /// エンジンの振りと同じ順。
    public enum DanceLegs: Int, CaseIterable, Sendable {
        case bounce, stepTouch, twist, kneePop, sideStep, kick, hop, sway
        case twoStep, boxStep, kickBallChange, grapevine, vStep, heelToe, charleston
        case rock, point, cross, hipRoll, chacha, march, tiptoe, heelTap

        var twoBars: Bool { self == .sideStep || self == .grapevine }
    }
    public enum DanceArms: Int, CaseIterable, Sendable {
        case pump, clap, point, overhead, wave, roll, hips, twinkle, swim, cat, heart, punch
        case peace, bunny, cheek, kiss, jazz, ganbare, burikko, headHeart, pray, hello

        static let cute: [DanceArms] = [.cat, .twinkle, .heart, .peace, .bunny, .cheek, .kiss, .burikko, .headHeart, .pray]
        static let energetic: [DanceArms] = [.pump, .clap, .overhead, .punch, .jazz, .ganbare, .point, .hello]
        static let calm: [DanceArms] = [.wave, .swim, .roll, .hips, .pray, .cheek]
        static let cool: [DanceArms] = [.point, .hips, .roll, .punch]
    }

    public typealias Prop = PropKind
    public typealias Expression = Engine.Expression

    /// `id` は負（ウィンドウと重ならない）。
    public struct Thing: Sendable, Equatable {
        public var id: Int
        public var name: String
        public var comment: String
        public var point: SIMD2<Float>

        public init(id: Int, name: String, comment: String, point: SIMD2<Float>) {
            (self.id, self.name, self.comment, self.point) = (id, name, comment, point)
        }
    }

    public struct Intent: Sendable {
        public var look: SIMD2<Float>?
        /// 右手で指さす点。
        public var point: SIMD2<Float>?
        public var drag: Drag = .none
        public var hop: Float = 0
        public var expressions = [Float](repeating: 0, count: Expression.allCases.count)
        public var motion: Motion = .idle
        public var facing: Float = 0
        public var walkVelocity: Float = 0
        public var sleeping = false
        /// -1: 左、1: 右、0: 渡らない。
        public var crossScreen: Int = 0
        /// 瞬間移動の行き先。
        public var warp: SIMD2<Float>?
        public var prop: Prop?
        public var beat: Beat?
        public var song: SongPlaying?
        /// 瞬間移動で消えている間。
        public var hidden = false
        /// 足もとの帯を測ってほしい。
        public var lookForSpace = false
        /// 煙の位置と大きさ（z）。
        public var puffs: [SIMD3<Float>] = []
        public var bubble: String?
        public var clicked = false
        public var frameRate: FrameRate = .idle
    }
}

extension PropKind {
    /// 椅子・ラグなどの置く小道具を除く。
    public static var held: [PropKind] { allCases.filter { $0.grip != nil } }

    public var motion: Slot {
        switch self {
        case .mug, .bottle, .iceCream, .onigiri, .lollipop, .flower, .toothbrush, .comb, .paintbrush: .holdFront
        case .balloon, .umbrella: .holdUp
        case .fan: .fanSelf
        case .teddy: .hugToy
        case .camera, .controller, .magnifier: .holdBoth
        case .headphones, .chair, .rug, .carry, .phone, .book: .idle
        }
    }

    /// AI に渡す名前（`hold` の道具の選択肢にもなる）。
    public var label: String {
        switch self {
        case .mug: "mug"
        case .bottle: "plastic bottle"
        case .iceCream: "soft-serve ice cream"
        case .onigiri: "rice ball"
        case .lollipop: "lollipop"
        case .flower: "flower"
        case .balloon: "balloon"
        case .umbrella: "umbrella"
        case .fan: "paper fan"
        case .teddy: "teddy bear"
        case .camera: "camera"
        case .controller: "game controller"
        case .magnifier: "magnifying glass"
        case .headphones: "headphones"
        case .toothbrush: "toothbrush"
        case .comb: "comb"
        case .paintbrush: "paintbrush"
        case .chair: "chair"
        case .rug: "rug"
        case .carry: "potted cactus"
        case .phone: "smartphone"
        case .book: "book"
        }
    }
}
