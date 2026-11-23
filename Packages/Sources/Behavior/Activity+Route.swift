import simd

extension Mascot {
    func tooFarToWalk(_ dx: Float, body: Body, world: World) -> Bool {
        abs(dx) > max(body.height * 6, world.width * 0.45)
    }
    static let hopSeconds: Float = 0.8
    static let hopChance: Float = 0.5

    func hopTarget(from s: Surface, among surfaces: [Surface], body: Body) -> Surface? {
        surfaces
            .filter { $0.id != s.id && abs($0.top - s.top) < body.height * 0.8 }
            .map { t in (t, max(t.minX - s.maxX, s.minX - t.maxX)) }
            .filter { $0.1 > -body.height && $0.1 < body.height * 1.2 }
            .min { $0.1 < $1.1 }?.0
    }
    // コアの Mantle のクリップの長さと同じ
    static let mantleSeconds: Float = 0.8

    func climbSides(_ s: Surface, body: Body, world: World) -> [Float] {
        let gap = body.height * 0.3, margin = body.height * 0.4
        guard s.bottom - body.root.y <= jumpReach(body: body) else { return [] }
        return [(s.minX - gap, s.climbLeft), (s.maxX + gap, s.climbRight)]
            .filter { $0.1 && $0.0 > margin && $0.0 < world.width - margin }
            .map(\.0)
    }

    func approachX(_ s: Surface, body: Body, world: World) -> Float {
        climbSides(s, body: body, world: world).min { abs($0 - body.root.x) < abs($1 - body.root.x) } ?? (s.minX + s.maxX) / 2
    }

    func climbable(_ s: Surface, body: Body, world: World) -> Bool {
        !climbSides(s, body: body, world: world).isEmpty
    }

    func jumpReach(body: Body) -> Float { body.height * 0.9 }

    func route(to s: Surface, surfaces: [Surface], body: Body, world: World) -> Activity {
        routeNext = nil
        perchSit = true
        if climbable(s, body: body, world: world) {
            return .walking(to: approachX(s, body: body, world: world), then: s.id)
        }
        let edge = body.height * 0.4
        if s.top - body.root.y <= jumpReach(body: body) {
            return .walking(to: min(max(body.root.x, s.minX + edge), s.maxX - edge), then: s.id)
        }
        let via = surfaces
            .filter { $0.id != s.id && climbable($0, body: body, world: world) && hopTarget(from: $0, among: [s], body: body) != nil }
            .min { abs(approachX($0, body: body, world: world) - body.root.x) < abs(approachX($1, body: body, world: world) - body.root.x) }
        if let via {
            routeNext = s.id
            return .walking(to: approachX(via, body: body, world: world), then: via.id)
        }
        return .walking(to: body.root.x, then: s.id)
    }

    /// 診断用: 次のフレームでいちばん近い座れる場所へ向かう。
    public func requestSit() { sitRequested = true }

    /// 診断用: その場で体育座りし、`doze` 秒眠る。
    public func requestHug(doze: Float = 0) {
        hugRequested = true
        dozeUntil = time + doze
    }
    static let sleepThreshold: Float = 0.7
}
