/// 番号（`code`）は焼き込みのキャッシュにだけ使う。
public enum Slot: Hashable, Sendable {
    case idle, walk, sitDown, sit, standUp
    /// 空中（つままれている・落ちている）。
    case fall
    case wave
    /// 落ち着いた歩き。なければ `walk`。
    case walkCalm
    /// 落とされて落ちている・投げられて飛んでいる。なければ `fall`。
    case falling, thrown
    case land
    case idlePhone
    /// 箱を抱えて歩く。なければ `walk`。
    case walkCarry
    /// 座って本を読む。なければ `sit`。
    case sitRead
    case stretch
    /// 体育座り。
    case hug
    case climb
    /// 端末内のモデルが組み立てたモーション。
    case composed
    /// 縁を乗り越える。
    case mantle
    /// 手に持つ小道具の待機。
    case holdFront, holdUp, fanSelf, hugToy, holdBoth
    /// 120 BPM で 1 小節のループ。
    case beatStep, beatClap, beatPoint
    /// 縁に座って脚をぷらぷら。
    case sitSwing
    case gesture(UInt8)
    case dance(UInt16)

    static let fixed: [(Slot, UInt32)] = [
        (.idle, 0), (.walk, 1), (.sitDown, 2), (.sit, 3), (.standUp, 4), (.fall, 5), (.wave, 6), (.walkCalm, 7),
        (.falling, 8), (.thrown, 9), (.land, 18), (.idlePhone, 22), (.walkCarry, 26), (.sitRead, 27), (.stretch, 28),
        (.hug, 29), (.climb, 30), (.composed, 31), (.mantle, 32), (.holdFront, 33), (.holdUp, 34), (.fanSelf, 35),
        (.hugToy, 36), (.holdBoth, 37), (.beatStep, 38), (.beatClap, 39), (.beatPoint, 40), (.sitSwing, 41),
    ]

    /// 仕草は 1000 + 何番目、振りは 10000 + 何番目。
    public var code: UInt32 {
        switch self {
        case let .gesture(i): 1000 + UInt32(i)
        case let .dance(i): 10000 + UInt32(i)
        default: Self.fixed.first { $0.0 == self }!.1
        }
    }

    public init?(code v: UInt32) {
        switch v {
        case 1000...1255: self = .gesture(UInt8(v - 1000))
        case 10000...10999: self = .dance(UInt16(v - 10000))
        default:
            guard let s = Self.fixed.first(where: { $0.1 == v }) else { return nil }
            self = s.0
        }
    }

    var looping: Bool {
        switch self {
        case .sitDown, .standUp, .wave, .land, .stretch, .composed, .mantle, .gesture: false
        default: true
        }
    }
}
