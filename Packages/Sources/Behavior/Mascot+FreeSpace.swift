extension Mascot {
    static let busyThreshold: Float = 0.3

    /// 体の幅にかかる列のいちばん大きい値。
    func busyness(_ x: Float, body: Body, world: World) -> Float {
        let n = world.busy.count
        guard n > 0, world.width > 0 else { return 0 }
        let half = body.height / 2
        let lo = min(max(Int((x - half) / world.width * Float(n)), 0), n - 1)
        let hi = min(max(Int((x + half) / world.width * Float(n)), lo), n - 1)
        return world.busy[lo...hi].max() ?? 0
    }

    /// 地面の行き先を決める前に、測っていなければ測りを頼んで少し待つ。
    func shouldWaitForSpace(_ world: World) -> Bool {
        guard world.canLookForSpace, world.busy.isEmpty else { return false }
        if let at = spaceAskedAt, time - at < 3 { return false }
        spaceAskedAt = time
        lookRequested = true
        return true
    }

    /// 地面に均等に置いた候補（少しずらす）。
    func groundCandidates(body: Body, world: World) -> [Float] {
        let margin = body.height
        let span = max(world.width - 2 * margin, 1)
        return (0..<8).map { margin + (Float($0) + random()) / 8 * span }
    }

    func freestX(_ candidates: [Float], body: Body, world: World) -> Float? {
        candidates.min { busyness($0, body: body, world: world) < busyness($1, body: body, world: world) }
    }
}
