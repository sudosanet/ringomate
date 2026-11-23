import simd

/// 共通表情。強さは 0〜1。
public enum Expression: Int, CaseIterable, Sendable {
    case smile, surprise, calm, blush, mouthOpen, eyesClosed, angry, troubled, wink, mouthI, mouthU, mouthE, mouthO
    case browSerious, browJoy, browDown

    public static let count = 16

    /// 先にあるほど優先。`a+b` はそのモーフがないとき近いモーフを合成して代わりにする。
    static let names: [[String]] = [
        ["笑い", "にこり", "笑顔", "happy", "Joy", "joy"],
        ["びっくり", "驚き", "surprised", "Surprised"],
        ["なごみ", "にこやか", "細目", "relaxed", "笑い"],
        ["照れ", "赤面", "頬染め", "ほほ染め", "てれ"],
        ["あ", "a", "aa", "A"],
        ["まばたき", "blink", "Blink"],
        ["怒り", "angry", "Angry", "真面目+じと目", "怒る+ジト目", "真面目+ｷﾘｯ"],
        ["困る", "sorrow", "Sorrow", "sad", "困り眉", "下+じと目"],
        ["ウィンク", "ウィンク２", "blinkLeft", "blink_l", "Blink_L"],
        ["い", "i", "ih", "I"],
        ["う", "u", "ou", "U"],
        ["え", "e", "ee", "E"],
        ["お", "o", "oh", "O"],
        ["真面目", "キリッ", "ｷﾘｯ", "serious", "Serious"],
        ["喜ぶ", "上", "嬉しい", "browUp", "BrowUp", "brow_up"],
        ["下", "browDown", "BrowDown", "brow_down"],
    ]
}

enum Air { case held, falling, thrown }

struct Procedural {
    static let blinkNames = ["まばたき", "blink", "Blink"]
    static let blinkDuration: Float = 0.16

    var expressions: [[Int]]
    var blink: Int?
    private(set) var head: Int?
    var neck: Int?, eyes: Int?, chest: Int?, upper: Int?, lower: Int?
    var shoulders: [Int?]
    var feetIK: [Int?]
    private(set) var roots: [Int]
    var air: Float = 0
    var airMode = Air.held
    var floor: Float = 0
    var velocity = SIMD3<Float>.zero
    var calm: Float = 1
    var glance: [Float] = [0, 0]
    var nextGlance: Float = 3
    var saccade: [Float] = [0, 0]
    var nextSaccade: Float = 0.7
    private(set) var drowsy: Float = 0
    var petted: Float = 0
    var keys: [(Int, SIMD3<Float>)]
    var tails: [Int]
    var cheer: Float = 0, gloom: Float = 0, wag: Float = 0
    var groovePhase: Float = 0, groove: Float = 0
    var center: Int?
    var time: Float = 0
    var breathPhase: Float = 0
    var nextBlink: Float = 2
    var blinkStart: Float = -1
    var doubleBlink = false
    var rng: UInt32 = 0x9e37_79b9
    var gaze: [Float] = [0, 0]
    var eyeGaze: [Float] = [0, 0]
    var missing: [String] = []

    static func morph(_ pmx: PMXModel, _ aliases: Profile.Aliases, _ names: [String]) -> Int? {
        for n in names { for a in aliases.morph(n) { if let i = pmx.morphs.firstIndex(where: { $0.name == a }) { return i } } }
        return nil
    }

    static func bone(_ pmx: PMXModel, _ aliases: Profile.Aliases, _ name: String) -> Int? { Retarget.bone(pmx, aliases, [name]) }

    init(_ pmx: PMXModel, _ aliases: Profile.Aliases) {
        expressions = Expression.names.map { names in
            for c in names {
                let parts = c.split(separator: "+", omittingEmptySubsequences: false).map { Self.morph(pmx, aliases, [String($0)]) }
                if parts.allSatisfy({ $0 != nil }) { return parts.map { $0! } }
            }
            return []
        }
        missing = zip(expressions, Expression.names).filter { $0.0.isEmpty }.map { "expression not found: \($0.1[0])" }
        blink = Self.morph(pmx, aliases, Self.blinkNames)
        if blink == nil { missing.append("blink morph not found") }
        let b = { Self.bone(pmx, aliases, $0) }
        head = b("頭")
        if head == nil { missing.append("head bone 頭 not found (no gaze)") }
        neck = b("首")
        eyes = b("両目")
        chest = b("上半身2") ?? b("上半身")
        upper = b("上半身")
        lower = b("下半身")
        shoulders = [b("左肩"), b("右肩")]
        feetIK = [b("左足ＩＫ") ?? b("左足IK"), b("右足ＩＫ") ?? b("右足IK")]
        roots = pmx.bones.indices.filter { pmx.bones[$0].parentIndex < 0 }
        tails = Self.tailRoots(pmx)
        keys = Self.windKeys(pmx)
        center = b("センター")
    }

    mutating func random() -> Float {
        rng ^= rng << 13
        rng ^= rng >> 17
        rng ^= rng << 5
        return Float(rng) / Float(UInt32.max)
    }

    mutating func advance(_ dt: Float, idle: Bool, air a: Air?, velocity v: SIMD3<Float>) {
        time += dt
        // 位相は毎フレーム足す（`sin(time / 周期)` だと周期が変わる間に位相が飛んで震える）
        breathPhase = (breathPhase + dt * Math.tau / (3.6 + 2.4 * drowsy)).truncatingRemainder(dividingBy: Math.tau)
        let k = 1 - exp(-dt * 2)
        calm += ((idle ? 1 : 0) - calm) * k
        air += ((a != nil ? 1 : 0) - air) * min(k * 2, 1)
        if let a { airMode = a }
        velocity += (v - velocity) * min(k * 3, 1)
        if time >= nextGlance {
            if random() < 0.35 {
                glance = [0, 0]
            } else {
                let x = (random() - 0.5) * 0.7
                glance = [x, (random() - 0.35) * 0.25]
            }
            nextGlance = time + 2.5 + random() * 4
        }
        if time >= nextSaccade {
            let x = (random() - 0.5) * 0.1
            saccade = [x, (random() - 0.5) * 0.06]
            nextSaccade = time + 0.4 + random() * 1.6 + drowsy * 2
        }
        if time >= nextBlink {
            blinkStart = time
            doubleBlink = random() < 0.2
            let pause = doubleBlink ? Self.blinkDuration * 2.2 : 2 + random() * 4
            nextBlink = time + pause
        }
    }

    func blinkWeight() -> Float {
        let t = (time - blinkStart) / Self.blinkDuration
        return t >= 0 && t < 1 ? 1 - abs(t * 2 - 1) : 0
    }

    mutating func feel(_ dt: Float, _ e: [Float]) {
        let c = { (x: Expression) in Math.clamp(e[x.rawValue], 0, 1) }
        var k = 1 - exp(-dt * 3)
        drowsy += (c(.eyesClosed) - drowsy) * k
        petted += (c(.calm) - petted) * k
        let cheerWant = min(c(.smile) + c(.mouthOpen) * 0.5 + petted, 1)
        let gloomWant = max(c(.troubled), c(.angry))
        k = 1 - exp(-dt * 1.5)
        cheer += (cheerWant - cheer) * k
        gloom += (gloomWant - gloom) * k
        let walking = min(simd_length(SIMD3(velocity.x, 0, velocity.z)) / 20, 1)
        let hz = (0.5 + 1.5 * cheer + 0.4 * walking) * (1 - 0.5 * gloom) * (1 - 0.6 * drowsy)
        wag = (wag + dt * Math.tau * hz).truncatingRemainder(dividingBy: Math.tau * 64)
    }

    mutating func groove(_ dt: Float, _ beat: (phase: Float, energy: Float)?, on: Bool) {
        var want: Float = 0
        if let beat, on {
            groovePhase = beat.phase
            want = Math.clamp(beat.energy, 0, 1)
        }
        groove += (want - groove) * (1 - exp(-dt * 3))
    }

    func bounce(_ height: Float) -> (Int, SIMD3<Float>)? {
        if groove < 0.01 { return nil }
        let down = pow((1 + cos(groovePhase * Math.tau)) / 2, 1.5)
        guard let center else { return nil }
        return (center, SIMD3(0, -down * height * 0.018 * groove, 0))
    }

    mutating func sitOnFloor(_ dt: Float, _ on: Bool) {
        let k = 1 - exp(-dt * 3)
        floor += ((on ? 1 : 0) - floor) * k
    }

    func tail() -> simd_quatf {
        let amp = (0.12 + 0.28 * cheer) * (1 - 0.6 * gloom) * (1 - 0.7 * drowsy) * (1 - 0.8 * floor)
        let lift = -0.25 * cheer + 0.35 * gloom + 0.25 * drowsy - 0.4 * air - 0.8 * floor
        return Math.mul(Math.rotY(sin(wag) * amp), Math.rotX(lift))
    }

    func mouthMorphs() -> [Int] {
        [Expression.mouthOpen, .mouthI, .mouthU, .mouthE, .mouthO].flatMap { expressions[$0.rawValue] }
    }

    func morphWeights(_ e: [Float]) -> [(Int, Float)] {
        func eye(_ w: Float) -> Float { Math.clamp((w - 0.5) * 5, 0, 1) }
        var out: [(Int, Float)] = []
        for (i, ms) in expressions.enumerated() {
            for m in ms {
                let w = i == Expression.smile.rawValue || i == Expression.calm.rawValue ? eye(e[i]) : Math.clamp(e[i], 0, 1)
                if let k = out.firstIndex(where: { $0.0 == m }) { out[k].1 = max(out[k].1, w) } else { out.append((m, w)) }
            }
        }
        let eyesClosed = eye(max(e[Expression.calm.rawValue], e[Expression.smile.rawValue]))
        if let b = blink {
            let w = blinkWeight() * Math.clamp(1 - eyesClosed, 0, 1)
            if let k = out.firstIndex(where: { $0.0 == b }) { out[k].1 = max(out[k].1, w) } else { out.append((b, w)) }
        }
        return out
    }

    func life() -> [(Int, simd_quatf)] {
        let tau = Math.tau
        let breath = sin(breathPhase) * (1 + 0.6 * drowsy)
        let shift = sin(time * tau / 8) * calm
        var out: [(Int, simd_quatf)] = []
        func push(_ b: Int?, _ q: simd_quatf) { if let b { out.append((b, q)) } }
        push(chest, Math.rotX(breath * 0.025))
        push(shoulders[0], Math.rotZ(breath * 0.02))
        push(shoulders[1], Math.rotZ(-breath * 0.02))
        push(lower, Math.rotZ(shift * 0.04))
        push(upper, Math.rotZ(-shift * 0.03))
        switch airMode {
        case .held:
            let swing = sin(time * tau / 1.4) * air
            push(lower, Math.rotX(swing * 0.2))
            push(upper, Math.rotX(-swing * 0.06))
        case .falling:
            let phase = time * tau * 1.8
            push(shoulders[0], Math.rotZ(sin(phase) * 0.3 * air))
            push(shoulders[1], Math.rotZ(-sin(phase + 1.9) * 0.3 * air))
            push(upper, Math.rotX(0.12 * air))
        case .thrown:
            let v = Math.clampLengthMax(velocity / 80, 1) * air
            push(lower, Math.mul(Math.rotZ(-v.x * 0.5), Math.rotX(v.y * 0.3)))
            push(upper, Math.rotZ(-v.x * 0.25))
        }
        for (k, axis) in keys { push(k, Math.axisAngle(axis, (time * tau * 0.15).truncatingRemainder(dividingBy: tau))) }
        for t in tails { push(t, tail()) }
        if groove > 0.01 {
            let nod = ((1 + cos(groovePhase * tau)) / 2) * groove
            push(neck, Math.rotX(-nod * 0.08))
            push(upper, Math.rotZ(sin(groovePhase * Float.pi) * 0.03 * groove))
        }
        push(head, Math.rotZ(-gaze[0] * 0.35 * calm + shift * 0.04 + petted * 0.14))
        return out
    }

    func kick() -> [(Int, SIMD3<Float>)] {
        if airMode == .falling {
            return zip(feetIK, [Float(1.8), 0.8]).compactMap { b, up in b.map { ($0, SIMD3(0, up * air, up * 0.8 * air)) } }
        }
        if airMode != .held { return [] }
        let phase = time * Math.tau / 0.9
        return feetIK.enumerated().compactMap { k, b in
            let s = sin(phase + Float(k) * Float.pi) * air
            return b.map { ($0, SIMD3(0, max(s, 0) * 1.5, -s * 2)) }
        }
    }

    func sway() -> SIMD3<Float> {
        let shift = sin(time * Math.tau / 8) * calm
        return SIMD3(shift * 0.15, 0, 0)
    }

    /// `target` はモデル空間（z は視点側が負）。
    mutating func gaze(_ dt: Float, head headWorld: SIMD3<Float>?, target: SIMD3<Float>?) -> [(Int, simd_quatf)] {
        let goal: [Float]
        if let h = headWorld, let t = target {
            let d = t - h
            let depth = max(-d.z, 10)
            goal = [Math.clamp(-atan2(d.x, depth), -0.6, 0.6), Math.clamp(atan2(d.y, depth), -0.35, 0.35)]
        } else {
            goal = glance.map { $0 * calm }
        }
        // 上下を広げると瞳のハイライトがまぶたに隠れる
        let range: [Float] = [0.3, 0.1]
        let hasEyes = eyes != nil
        let headGoal = (0..<2).map { i -> Float in
            hasEyes ? Math.signum(goal[i]) * max(abs(goal[i]) - range[i] * 0.6, 0) : goal[i] * 0.65
        }
        let slow = 1 - exp(-dt * 3), fast = 1 - exp(-dt * 18)
        for i in 0..<2 {
            gaze[i] += (headGoal[i] - gaze[i]) * slow
            eyeGaze[i] += (goal[i] - eyeGaze[i]) * fast
        }
        func rot(_ v: [Float]) -> simd_quatf { Math.mul(Math.rotY(v[0]), Math.rotX(v[1])) }
        let body = gaze
        let eyeRot = (0..<2).map { i in Math.clamp(eyeGaze[i] - body[i] + saccade[i], -range[i], range[i]) }
        let jitter: Float = hasEyes ? 0 : 0.25
        let headRot = (0..<2).map { i in body[i] * 0.7 + saccade[i] * jitter }
        return [(head, rot(headRot)), (neck, rot(body.map { $0 * 0.3 })), (eyes, rot(eyeRot))].compactMap { b, q in b.map { ($0, q) } }
    }

    static func windKeys(_ pmx: PMXModel) -> [(Int, SIMD3<Float>)] {
        pmx.bones.indices.compactMap { i in
            let n = pmx.bones[i].name
            let axis = pmx.bones[i].fixedAxis.flatMap { simd_length($0) > 1e-3 ? $0 : nil }
            let named = ["ゼンマイ", "发条", "發條", "ぜんまい"].contains { Profile.contains(n, $0) }
            guard named || (n.hasPrefix("Key") && axis != nil) else { return nil }
            return (i, simd_normalize(axis ?? SIMD3(0, 0, 1)))
        }
    }

    static func tailRoots(_ pmx: PMXModel) -> [Int] {
        let bones = pmx.bones
        func isTail(_ i: Int) -> Bool {
            let n = bones[i].name.lowercased()
            return ["尻尾", "しっぽ", "シッポ", "尾", "tail"].contains { Profile.contains(n, $0) }
                && !["pony", "twin", "ポニー", "ツイン"].contains { Profile.contains(n, $0) }
        }
        return bones.indices.filter { i in
            guard isTail(i) else { return false }
            let p = Int(bones[i].parentIndex)
            return p < 0 || p >= bones.count || !isTail(p)
        }
    }

    /// 頂点ごとの部位（1: 頭、2: 胴、3: 手、4: 足）。
    static func vertexParts(_ pmx: PMXModel, _ aliases: Profile.Aliases) -> [UInt8] {
        let bones = pmx.bones
        func standard(_ name: String) -> String { aliases.bones.first { $0.value.contains(name) }?.key ?? name }
        let partOfBone: [UInt8] = bones.indices.map { i in
            var b = i, guardCount = 0
            while b >= 0 && b < bones.count && guardCount < 256 {
                let name = standard(bones[b].name)
                if name == "頭" || name == "首" { return 1 }
                if Profile.contains(name, "手首") { return 3 }
                if name == "左足" || name == "右足" || Profile.contains(name, "ひざ") || Profile.contains(name, "足首") { return 4 }
                b = Int(bones[b].parentIndex)
                guardCount += 1
            }
            return 2
        }
        let g = pmx.geometry
        return (0..<g.positions.count / 3).map { v in
            var k = 0
            for j in 1..<4 where g.skinWeights[v * 4 + j] >= g.skinWeights[v * 4 + k] { k = j }
            let b = Int(g.skinIndices[v * 4 + k])
            return b < partOfBone.count ? partOfBone[b] : 2
        }
    }
}
