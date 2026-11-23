import simd

/// ponytail: 指・ねじりボーンは写さない（手首まで、指は UAL の指だけ）。
enum Retarget {
    /// (ソースの名前（UE Mannequin 系）, ターゲットの名前の候補（MMD 標準名）)
    static let humanoid: [(String, [String])] = {
        var t: [(String, [String])] = [
            ("pelvis", ["下半身"]), ("spine_01", ["上半身"]), ("spine_03", ["上半身2"]), ("neck_01", ["首"]), ("Head", ["頭"]),
            ("clavicle_l", ["左肩"]), ("upperarm_l", ["左腕"]), ("lowerarm_l", ["左ひじ"]), ("hand_l", ["左手首"]),
            ("clavicle_r", ["右肩"]), ("upperarm_r", ["右腕"]), ("lowerarm_r", ["右ひじ"]), ("hand_r", ["右手首"]),
            ("thigh_l", ["左足"]), ("calf_l", ["左ひざ"]), ("foot_l", ["左足首"]),
            ("thigh_r", ["右足"]), ("calf_r", ["右ひざ"]), ("foot_r", ["右足首"]),
        ]
        let fingers = [("thumb", "親指", ["０", "１", "２"], ["0", "1", "2"]), ("index", "人指", ["１", "２", "３"], ["1", "2", "3"]),
                       ("middle", "中指", ["１", "２", "３"], ["1", "2", "3"]), ("ring", "薬指", ["１", "２", "３"], ["1", "2", "3"]),
                       ("pinky", "小指", ["１", "２", "３"], ["1", "2", "3"])]
        for (side, jp) in [("l", "左"), ("r", "右")] {
            for (f, name, wide, narrow) in fingers {
                for k in 0..<3 { t.append(("\(f)_0\(k + 1)_\(side)", ["\(jp)\(name)\(wide[k])", "\(jp)\(name)\(narrow[k])"])) }
            }
        }
        return t
    }()

    /// (ボーン, 区間の先)
    static let segments: [(String, String)] = {
        var s: [(String, String)] = [("clavicle_l", "upperarm_l"), ("upperarm_l", "lowerarm_l"), ("lowerarm_l", "hand_l"),
                                     ("clavicle_r", "upperarm_r"), ("upperarm_r", "lowerarm_r"), ("lowerarm_r", "hand_r"),
                                     ("thigh_l", "calf_l"), ("calf_l", "foot_l"), ("thigh_r", "calf_r"), ("calf_r", "foot_r")]
        for side in ["l", "r"] {
            for f in ["thumb", "index", "middle", "ring", "pinky"] {
                s += [("\(f)_01_\(side)", "\(f)_02_\(side)"), ("\(f)_02_\(side)", "\(f)_03_\(side)"), ("\(f)_03_\(side)", "\(f)_04_leaf_\(side)")]
            }
        }
        return s
    }()

    static let footIK: [(String, [String])] = [("foot_l", ["左足ＩＫ", "左足IK"]), ("foot_r", ["右足ＩＫ", "右足IK"])]
    static let damped: [String: Float] = ["neck_01": 0.3, "Head": 0.3]

    struct Options: Sendable {
        /// 肘から先を体のほうへ寄せる角度（ラジアン）。
        var armAdduct: Float = 0
        /// 上腕ごと腕を下ろす角度（ラジアン、[左, 右]）。
        var shoulderAdduct: SIMD2<Float> = .zero
        /// 足 IK の目標を 1 周期の平均と接地の高さから作る。
        var cycleFeet = false
        /// 背骨の回転の倍率（0 は 1 と同じ）。
        var upright: Float = 0

        init() {}
    }

    /// glTF（右手系・+Z 前）→ MMD（左手系・−Z 前）: Z を反転する。
    static func convV(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, v.y, -v.z) }
    static func convQ(_ q: simd_quatf) -> simd_quatf { simd_quatf(ix: -q.imag.x, iy: -q.imag.y, iz: q.imag.z, r: q.real) }

    static func bone(_ pmx: PMXModel, _ aliases: Profile.Aliases, _ names: [String]) -> Int? {
        // 名前はバイト列で比べる（String の == は正規化するので遅い）
        for n in names {
            for a in aliases.bone(n) {
                let key = Array(a.utf8)
                if let i = pmx.bones.firstIndex(where: { $0.name.utf8.elementsEqual(key) }) { return i }
            }
        }
        return nil
    }

    /// 別名の骨（「头」など）を標準の名前（「頭」）に付け替える。標準の名前が既にあれば触らない。
    static func canonicalize(_ pmx: inout PMXModel, _ aliases: Profile.Aliases) -> [String] {
        var renamed: [String] = []
        let names = pmx.bones.map(\.name)
        for (standard, others) in aliases.bones.sorted(by: { $0.key < $1.key }) where !names.contains(standard) {
            guard let i = others.lazy.compactMap({ a in names.firstIndex(of: a) }).first else { continue }
            renamed.append("\(pmx.bones[i].name)→\(standard)")
            pmx.bones[i].name = standard
        }
        return renamed
    }

    static func worldMatrices(_ skel: SourceSkeleton, _ locals: [(SIMD3<Float>, simd_quatf)]) -> [simd_float4x4] {
        var w = [simd_float4x4](repeating: matrix_identity_float4x4, count: skel.names.count)
        for i in skel.names.indices {
            let l = Math.matrix(locals[i].1, locals[i].0)
            w[i] = skel.parents[i].map { Math.mul(w[$0], l) } ?? l
        }
        return w
    }

    static func rot(_ m: simd_float4x4) -> simd_quatf { simd_normalize(Math.rotationAxes(m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz)) }

    static func bake(_ skel: SourceSkeleton, _ clip: SourceClip, _ pmx: PMXModel, _ aliases: Profile.Aliases,
                            _ options: Options = Options()) -> BakedClip {
        func src(_ name: String) -> Int? { skel.names.firstIndex(of: name) }
        let bones = pmx.bones
        func tgt(_ names: [String]) -> Int? { bone(pmx, aliases, names) }
        func rest(_ i: Int) -> SIMD3<Float> { bones[i].position }
        let map: [(Int, Int)] = humanoid.compactMap { s, t in src(s).flatMap { a in tgt(t).map { (a, $0) } } }
        let targetOf = Dictionary(map, uniquingKeysWith: { _, b in b })
        let bindWorld = worldMatrices(skel, skel.bind)
        func bindPos(_ j: Int) -> SIMD3<Float> { convV(bindWorld[j].columns.3.xyz) }
        func bindRot(_ j: Int) -> simd_quatf { convQ(rot(bindWorld[j])) }

        var align: [Int: simd_quatf] = [:]
        for (a, b) in segments {
            guard let sa = src(a), let sb = src(b), let ta = targetOf[sa], let tb = targetOf[sb] else { continue }
            let dt = Math.normalizeOrZero(rest(tb) - rest(ta)), ds = Math.normalizeOrZero(bindPos(sb) - bindPos(sa))
            if dt != .zero && ds != .zero { align[ta] = Math.rotationArc(dt, ds) }
        }
        func leg(_ a: Int?, _ b: Int?, _ p: (Int) -> SIMD3<Float>) -> Float {
            guard let a, let b else { return 0 }
            return simd_length(p(a) - p(b))
        }
        let srcLeg = leg(src("thigh_l"), src("calf_l"), bindPos) + leg(src("calf_l"), src("foot_l"), bindPos)
        let tgtLeg = leg(tgt(["左足"]), tgt(["左ひざ"]), rest) + leg(tgt(["左ひざ"]), tgt(["左足首"]), rest)
        let scale: Float = srcLeg > 0 && tgtLeg > 0 ? tgtLeg / srcLeg : 12.5

        func parent(_ i: Int) -> Int? {
            let p = Int(bones[i].parentIndex)
            return p >= 0 && p < bones.count ? p : nil
        }
        func depth(_ start: Int) -> Int {
            var d = 0, i = start
            while let p = parent(i) {
                i = p
                d += 1
                if d > 512 { break }
            }
            return d
        }
        let order = bones.indices.map { ($0, depth($0)) }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.0)
        let center: (Int, Int)? = tgt(["センター"]).flatMap { c in src("pelvis").map { (c, $0) } }
        let feet: [(Int, Int, Int)] = footIK.compactMap { s, t in
            guard let s = src(s), let ik = tgt(t), let tb = targetOf[s] else { return nil }
            return (s, ik, tb)
        }
        let upright = options.upright > 0 ? options.upright : 1
        var damp: [Int: Float] = [:]
        for (s, ti) in map {
            let name = skel.names[s]
            if let k = damped[name] { damp[ti] = k } else if upright != 1, name == "spine_01" || name == "spine_03" { damp[ti] = upright }
        }
        var adduct: [Int: simd_quatf] = [:]
        for (s, ti) in map {
            let (side, angle): (Float, Float)
            switch skel.names[s] {
            case "upperarm_l": (side, angle) = (-1, options.shoulderAdduct.x)
            case "upperarm_r": (side, angle) = (1, options.shoulderAdduct.y)
            case "lowerarm_l", "hand_l": (side, angle) = (-1, options.shoulderAdduct.x + options.armAdduct)
            case "lowerarm_r", "hand_r": (side, angle) = (1, options.shoulderAdduct.y + options.armAdduct)
            default: continue
            }
            let a = side * angle
            adduct[ti] = simd_quatf(ix: 0, iy: 0, iz: sin(a * 0.5), r: cos(a * 0.5))
        }
        let fps: Float = 30
        let n = Int(max((clip.duration * fps).rounded(), 1)) + 1
        func sampleWorld(_ k: Int) -> [simd_float4x4] { worldMatrices(skel, clip.sample(skel, min(Float(k) / fps, clip.duration))) }
        var footFlat: [Int: simd_quatf] = [:]
        if options.cycleFeet {
            for (f, b) in [("foot_l", "ball_l"), ("foot_r", "ball_r")] {
                guard let f = src(f), let b = src(b) else { continue }
                var best: (Float, [simd_float4x4])?
                for k in 0..<n {
                    let w = sampleWorld(k)
                    let h = w[f].columns.3.y + w[b].columns.3.y
                    if best == nil || h < best!.0 { best = (h, w) }
                }
                if let (_, w) = best { footFlat[f] = convQ(rot(w[f])) }
            }
        }
        let footRef: [SIMD3<Float>] = feet.map { s, _, _ in
            guard options.cycleFeet else { return bindPos(s) }
            let ps = (0..<n).map { convV(sampleWorld($0)[s].columns.3.xyz) }
            var mean = SIMD3<Float>.zero
            for p in ps { mean += p }
            mean /= Float(ps.count)
            let low = ps.reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
            return SIMD3(mean.x, low, mean.z)
        }
        var cycleCenter: (Int, Float, SIMD3<Float>, Float)?
        if options.cycleFeet, !footRef.isEmpty, let thigh = src("thigh_l"), let pelvis = src("pelvis"),
           let l = tgt(["左足"]), let ankle = tgt(["左足首"]) {
            let ground = footRef.reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
            var mean = SIMD3<Float>.zero
            for k in 0..<n { mean += convV(sampleWorld(k)[pelvis].columns.3.xyz) }
            mean /= Float(n)
            cycleCenter = (thigh, ground, mean, rest(l).y - rest(ankle).y)
        }

        var frames: [BakedClip.Frame] = []
        frames.reserveCapacity(n)
        for k in 0..<n {
            let w = sampleWorld(k)
            var worldRot: [Int: simd_quatf] = [:]
            for (s, ti) in map {
                let reference = footFlat[s] ?? bindRot(s)
                let delta = Math.mul(convQ(rot(w[s])), Math.inverse(reference))
                worldRot[ti] = Math.mul(Math.mul(adduct[ti] ?? Math.identity, delta), align[ti] ?? Math.identity)
            }
            var solved: [Int: simd_quatf] = [:]
            var rotations: [(Int, simd_quatf)] = []
            for i in order {
                let parentWorld = parent(i).flatMap { solved[$0] } ?? Math.identity
                if let wr = worldRot[i] {
                    var local = simd_normalize(Math.mul(Math.inverse(parentWorld), wr))
                    if let k = damp[i] { local = Math.slerp(Math.identity, local, k) }
                    rotations.append((i, local))
                    solved[i] = Math.mul(parentWorld, local)
                } else {
                    solved[i] = parentWorld
                }
            }
            func pos(_ j: Int) -> SIMD3<Float> { convV(w[j].columns.3.xyz) }
            let c: (Int, SIMD3<Float>)? = center.map { c, p in
                if let (thigh, ground, mean, hip) = cycleCenter {
                    let d = (pos(p) - mean) * scale
                    return (c, SIMD3(d.x, (pos(thigh).y - ground) * scale - hip, d.z))
                }
                return (c, (pos(p) - bindPos(p)) * scale)
            }
            frames.append(BakedClip.Frame(rotations: rotations, center: c,
                                          feet: zip(feet, footRef).map { f, r in (f.1, (pos(f.0) - r) * scale) }))
        }
        let speed = clip.groundSpeed ?? groundSpeed(skel, clip, feet.map(\.0))
        return BakedClip(name: clip.name, frames: frames, fps: fps, groundSpeed: speed * scale, mapped: map.count + feet.count)
    }

    /// 接地している足が後ろへ下がる速さ（中央値、ソース単位/s）。
    static func groundSpeed(_ skel: SourceSkeleton, _ clip: SourceClip, _ feet: [Int]) -> Float {
        guard feet.count >= 2, clip.duration > 0 else { return 0 }
        let steps = 60
        let dt = clip.duration / Float(steps)
        func at(_ t: Float) -> [SIMD3<Float>] {
            let w = worldMatrices(skel, clip.sample(skel, t))
            return feet.map { convV(w[$0].columns.3.xyz) }
        }
        var speeds: [Float] = []
        var prev = at(0)
        for k in 1...steps {
            let cur = at(Float(k) * dt)
            let low = cur[0].y <= cur[1].y ? 0 : 1
            speeds.append((cur[low].z - prev[low].z) / dt)
            prev = cur
        }
        speeds.sort()
        return max(speeds[speeds.count / 2], 0)
    }
}

extension BakedClip {
    public var duration: Float { vmd?.duration ?? Float(max(frames.count - 1, 0)) / fps }

    /// センターの横の移動をクリップから抜き、頭のコマからの横の移動（コマごと）を返す。
    mutating func takeRootX() -> [Float] {
        let xs = frames.map { $0.center?.1.x ?? 0 }
        guard let x0 = xs.first else { return [] }
        let half = max(Int(0.1 * fps), 1), n = xs.count
        let track: [Float] = (0..<n).map { i in
            let (a, b) = (max(i - half, 0), min(i + half, n - 1))
            return xs[a...b].reduce(0, +) / Float(b - a + 1) - x0
        }
        for (k, d) in track.enumerated() {
            if frames[k].center != nil { frames[k].center!.1.x -= d }
            for f in frames[k].feet.indices { frames[k].feet[f].1.x -= d }
        }
        return track
    }

    /// センターの水平の移動（前後 `window` 秒の平均）をセンターと足 IK から引く。
    mutating func stayInPlace(_ window: Float) {
        let xz = frames.map { f in f.center.map { SIMD3($0.1.x, 0, $0.1.z) } ?? .zero }
        guard !xz.isEmpty else { return }
        let half = max(Int(window * fps) / 2, 1), n = xz.count
        let smooth: [SIMD3<Float>] = (0..<n).map { i in
            let (a, b) = (max(i - half, 0), min(i + half, n - 1))
            var s = SIMD3<Float>.zero
            for v in xz[a...b] { s += v }
            return s / Float(b - a + 1)
        }
        for k in frames.indices {
            let d = smooth[k] - smooth[0]
            if frames[k].center != nil { frames[k].center!.1 -= d }
            for f in frames[k].feet.indices { frames[k].feet[f].1 -= d }
        }
    }
}
