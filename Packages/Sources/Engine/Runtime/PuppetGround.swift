import simd

extension Puppet {
    /// モーションごとの頭の平均の向きを測り、正面へ向ける回転を覚える。
    func levelHeads() {
        guard let head = procedural.head, model.pmx.bones[head].parentIndex >= 0 else { return }
        let parent = Int(model.pmx.bones[head].parentIndex)
        for slot in [Slot.idle, .walk, .walkCalm, .walkCarry, .sit] {
            guard let d = motions[slot]?.duration else { continue }
            var forward = SIMD3<Float>.zero
            var parentRot = Math.identity
            for k in 0..<4 {
                var p = Player()
                p.request(slot)
                p.advance(d * (Float(k) + 0.5) / 4, motions)
                p.advance(1, motions)
                p.apply(motions, &eval.pose, toeIKs: toeIKs)
                eval.evaluate()
                let w = eval.pose.world
                forward += Math.normalizeOrZero(Math.transformVector(w[head], SIMD3(0, 0, -1)))
                parentRot = Math.rotationOf(w[parent])
            }
            let fix = Math.rotationArc(Math.normalize(forward, or: SIMD3(0, 0, -1)), SIMD3(0, 0, -1))
            headLevel[slot] = simd_normalize(Math.mul(Math.mul(Math.inverse(parentRot), fix), parentRot))
        }
    }

    /// 待機の姿勢の最低の頂点が床に来るよう描く高さを上下する（身長の 1 割まで）。
    func fitGround() {
        guard let d = motions[.idle]?.duration else { return }
        var p = Player()
        p.request(.idle)
        p.advance(d * 0.5, motions)
        p.advance(1, motions)
        p.apply(motions, &eval.pose, toeIKs: toeIKs)
        props.hide(&eval.pose)
        eval.evaluate()
        let mats = eval.pose.skinning
        let g = model.pmx.geometry
        var lowest = Float.greatestFiniteMagnitude, highest = -Float.greatestFiniteMagnitude
        for v in 0..<g.positions.count / 3 {
            let pos = SIMD3(g.positions[v * 3], g.positions[v * 3 + 1], g.positions[v * 3 + 2])
            var y: Float = 0
            for k in 0..<4 {
                let w = v * 4 + k < g.skinWeights.count ? g.skinWeights[v * 4 + k] : 0
                if w > 0 {
                    let b = Int(g.skinIndices[v * 4 + k])
                    y += w * (b < mats.count ? Math.point(mats[b], pos).y : pos.y)
                }
            }
            if y > -1.0e3 {
                lowest = min(lowest, y)
                highest = max(highest, y)
            }
        }
        if lowest.isFinite && highest > lowest {
            stature = highest - lowest
            let limit = (highest - lowest) * 0.1
            ground = Math.clamp(-lowest, -limit, limit)
            if props.seat != nil { props.seat!.y = -ground }
            if props.rug != nil { props.rug!.y = -ground }
            diagnostics.append("ground: lifted \(String(format: "%.2f", ground)) (lowest vertex in idle)")
        }
        let world = eval.pose.world
        feetRef = ["左足首", "左つま先", "右足首", "右つま先"].compactMap { n in
            guard let b = model.pmx.bones.firstIndex(where: { $0.name == n }), b < world.count else { return nil }
            return (b, world[b].columns.3.y)
        }
        if feetRef.count == 4 {
            let floor = feetRef[0].1
            for n in ["左手首", "右手首"] {
                if let b = model.pmx.bones.firstIndex(where: { $0.name == n }) { feetRef.append((b, floor)) }
            }
        }
    }

    func feetGap() -> Float? {
        guard feetRef.count >= 4 else { return nil }
        let world = eval.pose.world
        func up(_ k: Int) -> Float {
            let (b, y) = feetRef[k]
            return b < world.count ? world[b].columns.3.y - y : 0
        }
        let feet = min(min(up(0), up(1)), min(up(2), up(3)))
        return (4..<feetRef.count).map(up).reduce(feet) { min($0, $1) }
    }

    /// クリップ自身のジャンプは跳んでいる間（1 秒まで）下ろさない。
    func settleFeet(_ dt: Float) {
        let standing: Bool = switch player.current {
        case .idle, .walk, .walkCalm, .walkCarry, .wave, .gesture, .composed, .stretch, .idlePhone, .land, .dance: true
        default: false
        }
        let gap = standing && Optimize.enabled("settle_feet") ? feetGap() : nil
        let rising = gap.map { ($0 - lastGap) / max(dt, 1e-4) } ?? 0
        let groundLine = 0.01 * stature
        if let g = gap, g > groundLine, lastGap <= groundLine, rising > 0.8 * stature {
            leap = 1
        } else if let g = gap, g > 0 {
            leap = max(leap - dt, 0)
        } else {
            leap = 0
        }
        lastGap = gap ?? 0
        if let g = gap, leap <= 0 {
            if g > 0 {
                if drop < g {
                    dropSpeed += -Self.gravity.y * dt
                    drop = min(drop + dropSpeed * dt, g)
                } else {
                    drop = g
                    dropSpeed = 0
                }
            } else {
                drop = 0
                dropSpeed = 0
            }
        } else {
            drop *= exp(-dt * 6)
            dropSpeed = 0
        }
    }

    /// 椅子は座った姿勢の腰の真下、ラグは体育座りの腰の下。
    func capturePropSpots() {
        func at(_ slot: Slot) -> SIMD3<Float>? {
            guard let d = motions[slot]?.duration else { return nil }
            var p = Player()
            p.request(slot)
            p.advance(d * 0.5, motions)
            p.advance(1, motions)
            p.apply(motions, &eval.pose, toeIKs: toeIKs)
            eval.evaluate()
            guard let b = Retarget.bone(model.pmx, model.profile.aliases, ["下半身"]), b < eval.pose.world.count else { return nil }
            let h = eval.pose.world[b].columns.3.xyz
            return SIMD3(h.x, 0, h.z)
        }
        props.seat = at(.sit)
        props.rug = at(.hug)
    }

    static func fkLegs(_ slot: Slot) -> Bool {
        switch slot {
        case .hug, .climb, .mantle, .sitSwing: true
        default: false
        }
    }

    /// フェードの元を前フレームの脚（切るとき）・足首の位置（戻すとき）にしないと、足 IK を切り替える瞬間に脚が跳ぶ。
    func smoothLegIKSwitch(leavingFK: Bool) {
        let world = eval.pose.world
        let bones = model.pmx.bones
        func rotOf(_ b: Int) -> simd_quatf {
            let r = Math.rotationOf(world[b])
            let p = Int(bones[b].parentIndex)
            guard p >= 0, p < world.count else { return simd_normalize(r) }
            return simd_normalize(Math.mul(Math.inverse(Math.rotationOf(world[p])), r))
        }
        var rot: [(Int, simd_quatf)] = []
        var off: [(Int, SIMD3<Float>)] = []
        for k in legIKs where k < runtime.ikSolvers.count {
            let solver = runtime.ikSolvers[k]
            if leavingFK {
                guard solver.targetBone < world.count, solver.ikBone < bones.count else { continue }
                off.append((solver.ikBone, world[solver.targetBone].columns.3.xyz - bones[solver.ikBone].position))
            } else {
                for l in solver.links { rot.append((l.bone, rotOf(l.bone))) }
                rot.append((solver.targetBone, rotOf(solver.targetBone)))
            }
        }
        player.patchFrom(rotations: rot, offsets: off)
    }
}
