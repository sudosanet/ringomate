extension Mascot {
    static let busyThreshold: Float = 0.3

    /// 画面で体が占める横幅。
    func footprint(_ body: Body) -> Float {
        // ponytail: ボーンの外に出るメッシュを 1.2 倍で見込む。足りないモデルが出たら描いた範囲から取る
        body.width > 0 ? body.width * 1.2 : body.height * 0.5
    }

    /// 体の幅にかかる列のいちばん大きい値。
    func busyness(_ x: Float, body: Body, world: World) -> Float {
        let n = world.busy.count
        guard n > 0, world.width > 0 else { return 0 }
        let half = footprint(body) / 2
        let lo = min(max(Int((x - half) / world.width * Float(n)), 0), n - 1)
        let hi = min(max(Int((x + half) / world.width * Float(n)), lo), n - 1)
        return world.busy[lo...hi].max() ?? 0
    }

    func isBusy(_ x: Float, body: Body, world: World) -> Bool {
        busyness(x, body: body, world: world) >= Self.busyThreshold
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
        let margin = footprint(body) / 2
        let span = max(world.width - 2 * margin, 1)
        return (0..<8).map { margin + (Float($0) + random()) / 8 * span }
    }

    /// 空いている候補のうち、いちばん空いているところ。どこも空いていなければ nil。
    func freestX(_ candidates: [Float], body: Body, world: World) -> Float? {
        candidates.filter { !isBusy($0, body: body, world: world) }
            .min { busyness($0, body: body, world: world) < busyness($1, body: body, world: world) }
    }
}
