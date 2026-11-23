@testable import Engine
import Foundation
import simd
import Testing

/// ローカルの検証モデルを決まった場面で動かし、指標を JSON に書く。`SWEEP_MODEL` があるときだけ動く。
/// `SWEEP_OUT`（書き出し先）・`SWEEP_N`（開始位相をずらす回数）・`SWEEP_SONGS`（曲の踊りのフォルダ）。
@Test func modelSweep() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["SWEEP_MODEL"] else { return }
    let runs = Int(env["SWEEP_N"] ?? "") ?? 3
    let songs = URL(filePath: env["SWEEP_SONGS"] ?? Assets.url("build/Build/Products/Debug/RingoMate.app/Contents/Resources/songs").path)
    let scene = Scene()
    let started = Date()
    let data = try scene.load(model: URL(filePath: path), library: Assets.library)
    scene.commitLoad()
    let c = try #require(scene.character)
    var out: [String: Any] = [
        "model": URL(filePath: path).lastPathComponent,
        "loadMs": Int(Date().timeIntervalSince(started) * 1000),
        "height": data.height,
        "static": Sweep.staticFacts(c, data),
    ]
    var dances: [(String, Slot)] = []
    for (k, song) in ["idol-yoasobi", "gimme-gimme"].enumerated() {
        let file = songs.appending(path: "\(song)/dance.glb")
        guard FileManager.default.fileExists(atPath: file.path) else { continue }
        let slot = UInt16(Puppet.builtDances + k)
        try scene.assignSongDance(index: slot, path: file, front: nil)
        dances.append((song, .dance(slot)))
    }
    var scenarios: [String: Any] = [:]
    for scenario in Sweep.scenarios(c, dances) {
        for hz in [60, 120] {
            let results = (0..<runs).map { Sweep.run(c, scenario, dt: 1 / Float(hz), phase: $0, height: data.height) }
            scenarios["\(scenario.name)@\(hz)"] = results
        }
    }
    out["scenarios"] = scenarios
    let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    let dir = URL(filePath: env["SWEEP_OUT"] ?? FileManager.default.temporaryDirectory.path)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try json.write(to: dir.appending(path: "\(URL(filePath: path).lastPathComponent).json"))
}

enum Sweep {
    struct Scenario {
        var name: String
        /// 場面の中の時刻から、その瞬間の意図。
        var steps: [(seconds: Float, intent: (Float) -> Intent)]
    }

    static func scenarios(_ c: Puppet, _ dances: [(String, Slot)]) -> [Scenario] {
        let speed = max(c.walkSpeed, 1)
        func hold(_ m: Slot) -> (Float) -> Intent { { _ in var i = Intent(); i.motion = m; return i } }
        var list = [
            Scenario(name: "idle", steps: [(8, hold(.idle))]),
            Scenario(name: "walk", steps: [(6, { t in
                var i = Intent()
                i.motion = .walk
                i.facing = .pi / 2
                i.root = SIMD3(speed * t, 0, 0)
                return i
            })]),
            Scenario(name: "sit", steps: [(2, hold(.sitDown)), (2, hold(.sit)), (2, hold(.standUp))]),
            Scenario(name: "wave", steps: [(4, hold(.wave))]),
            Scenario(name: "turn", steps: [(6, { t in
                var i = Intent()
                let k = Int(t / 2), f = Math.clamp((t - Float(k) * 2) / 0.4, 0, 1)
                i.facing = (Float(k) + f) * .pi
                return i
            })]),
            Scenario(name: "held", steps: [(3, { t in
                var i = Intent()
                i.motion = .fall
                i.held = true
                i.root = SIMD3(sin(t * 7) * 3, 2 + sin(t * 11) * 2, 0)
                return i
            })]),
        ]
        list += dances.map { name, slot in Scenario(name: name, steps: [(17, hold(slot))]) }
        return list
    }

    /// 足→ひざ・ひざ→足首（左右）と、そこに主に乗る頂点の軸からの距離の中央値。
    static func legCapsules(_ pmx: PMXModel) -> [(Int, Int, Float)] {
        let g = pmx.geometry, n = g.positions.count / 3
        func bone(_ name: String) -> Int? { pmx.bones.firstIndex { $0.name == name } }
        var out: [(Int, Int, Float)] = []
        for side in ["左", "右"] {
            for (x, y) in [("足", "ひざ"), ("ひざ", "足首")] {
                guard let a = bone(side + x), let b = bone(side + y) else { continue }
                let (pa, pb) = (pmx.bones[a].position, pmx.bones[b].position)
                let owners = Set([a, bone(side + x + "D")].compactMap { $0 })
                var ds: [Float] = []
                for v in 0..<n {
                    var best: (Float, Int) = (0, -1)
                    for k in 0..<4 where g.skinWeights[v * 4 + k] > best.0 { best = (g.skinWeights[v * 4 + k], Int(g.skinIndices[v * 4 + k])) }
                    guard owners.contains(best.1) else { continue }
                    let q = SIMD3(g.positions[v * 3], g.positions[v * 3 + 1], g.positions[v * 3 + 2])
                    let ab = pb - pa, u = simd_dot(q - pa, ab) / max(simd_dot(ab, ab), 1e-8)
                    if u > 0.2 && u < 0.8 { ds.append(simd_distance(q, pa + ab * u)) }
                }
                if !ds.isEmpty { out.append((a, b, ds.sorted()[ds.count / 2])) }
            }
        }
        return out
    }

    /// 揺れものの骨に主に乗る頂点（多いときは 3000 個に間引く）。
    static func clothVertices(_ pmx: PMXModel, _ cloth: Set<Int>) -> [Int] {
        let g = pmx.geometry, n = g.positions.count / 3
        var out: [Int] = []
        for v in 0..<n {
            var best: (Float, Int) = (0, -1)
            for k in 0..<4 where g.skinWeights[v * 4 + k] > best.0 { best = (g.skinWeights[v * 4 + k], Int(g.skinIndices[v * 4 + k])) }
            if cloth.contains(best.1) { out.append(v) }
        }
        let step = max(out.count / 3000, 1)
        return stride(from: 0, to: out.count, by: step).map { out[$0] }
    }

    static func physicsBones(_ c: Puppet) -> (dyn: Set<Int>, hair: Set<Int>) {
        let dyn = Set(c.physics?.bindings.compactMap { $0.mode != .static ? $0.bone : nil } ?? [])
        let hair = Set(c.physics?.hair?.chains.flatMap(\.bones) ?? [])
        return (dyn, hair)
    }

    static func staticFacts(_ c: Puppet, _ data: ModelData) -> [String: Any] {
        let pmx = c.model.pmx
        let chains = c.physics?.hair?.chains ?? []
        return [
            "profile": c.model.profile.name,
            "face": data.materials.filter(\.face).map(\.name),
            "hidden": data.materials.filter(\.hiddenRemoval).map(\.name),
            "bangs": data.materials.filter(\.bangs).map(\.name),
            "seeThrough": data.materials.filter(\.seeThrough).map(\.name),
            "bust": c.bust.sides.map { pmx.bones[$0.bone].name },
            "chains": chains.map { "\(pmx.bones[$0.bones[0]].name)×\($0.bones.count)" },
            "rods": chains.reduce(0) { $0 + $1.rods.count },
            "bodies": pmx.rigidBodies.count,
            "diagnostics": data.diagnostics.filter { $0.hasPrefix("physics") || $0.hasPrefix("skeleton") || $0.hasPrefix("bust") },
        ]
    }

    static func run(_ c: Puppet, _ s: Scenario, dt: Float, phase: Int, height h: Float) -> [String: Any] {
        let pmx = c.model.pmx
        let (dyn, hair) = physicsBones(c)
        let chains = c.physics?.hair?.chains ?? []
        let colliders = c.physics?.hair?.colliders ?? []
        let n = c.eval.pose.world.count
        let parents = pmx.bones.map { Int($0.parentIndex) }
        // 前の場面の動きを残さない（待機へ切り替えて 1 秒）。位相は待機の長さでずらす
        let warm = Intent()
        c.teleport(warm)
        for _ in 0..<(Int(1 / dt) + phase * 7) { c.step(dt, warm) }
        let restarts0 = c.physicsRestarts
        var prevPos = c.eval.pose.world.map { $0.columns.3.xyz }
        var prevRot = c.eval.pose.world.map { Math.rotationOf($0) }
        var prevLocal = c.eval.pose.localRotations
        var frames = 0, nan = 0, badWorld = 0, badLocal = 0
        var cause = ["drive": 0, "parent": 0, "physics": 0]
        var jump: (Float, Int) = (0, 0)
        var stretchMax: Float = 1, stretchFrames = 0
        var swaySum = [Float](repeating: 0, count: chains.count)
        var tipDev: [[SIMD3<Float>]] = Array(repeating: [], count: chains.count)
        var penetration: Float = 0
        var bustMax: Float = 0, bustSum: Float = 0
        // Jolt の揺れもの（髪の鎖を除く）の、親に対する回転の大きさ
        let authored = Set(pmx.rigidBodies.filter { $0.mode != "static" && $0.boneIndex >= 0 }.map { Int($0.boneIndex) })
        let cloth = authored.subtracting(hair).filter { $0 < n }.sorted()
        var joltSwing: Float = 0
        // 布の頂点が脚のカプセル（太さは脚のメッシュ）に入る深さ
        let legs = Sweep.legCapsules(pmx)
        let clothVerts = Sweep.clothVertices(pmx, Set(cloth))
        var legPenetration: Float = 0
        var stepTime: Double = 0, worst: Double = 0
        let fastMove = h * 10 * dt, fastTurn = Float.pi / 3 * dt * 60
        for (seconds, intent) in s.steps {
            var t: Float = 0
            while t < seconds {
                let started = Date()
                c.step(dt, intent(t))
                let e = Date().timeIntervalSince(started)
                stepTime += e
                worst = max(worst, e)
                t += dt
                frames += 1
                let world = c.eval.pose.world
                let pos = world.map { $0.columns.3.xyz }
                let rot = world.map { Math.rotationOf($0) }
                let local = c.eval.pose.localRotations
                if pos.contains(where: { !($0.x.isFinite && $0.y.isFinite && $0.z.isFinite) }) { nan += 1 }
                var driveJump = false
                for b in 0..<n where !dyn.contains(b) && !hair.contains(b) && simd_distance(pos[b], prevPos[b]) > fastMove { driveJump = true }
                var bw = false, bl = false, fromParent = false
                for b in 0..<n {
                    let move = simd_distance(pos[b], prevPos[b])
                    if move > jump.0 && frames > 2 { jump = (move, b) }
                    guard dyn.contains(b) || hair.contains(b) else { continue }
                    if move > fastMove || Math.angleBetween(prevRot[b], rot[b]) > fastTurn {
                        bw = true
                        let p = parents[b]
                        if p >= 0, !dyn.contains(p), !hair.contains(p), Math.angleBetween(prevRot[p], rot[p]) > fastTurn { fromParent = true }
                    }
                    if Math.angleBetween(prevLocal[b], local[b]) > fastTurn { bl = true }
                }
                if bw {
                    badWorld += 1
                    cause[driveJump ? "drive" : fromParent ? "parent" : "physics", default: 0] += 1
                }
                if bl { badLocal += 1 }
                var worstStretch: Float = 1
                for (k, ch) in chains.enumerated() where ch.p.count == ch.rest.count {
                    let pw = world[ch.parent], base = pmx.bones[ch.parent].position
                    let anim = ch.rest.map { Math.point(pw, $0 - base) }
                    var angle: Float = 0
                    for j in 0..<(ch.p.count - 1) {
                        let d = ch.p[j + 1] - ch.p[j], a = anim[j + 1] - anim[j]
                        worstStretch = max(worstStretch, simd_length(d) / ch.len[j])
                        if simd_length(d) > 1e-6, simd_length(a) > 1e-6 {
                            angle += acos(Math.clamp(simd_dot(simd_normalize(d), simd_normalize(a)), -1, 1))
                        }
                    }
                    swaySum[k] += angle / Float(ch.p.count - 1) * 180 / .pi
                    tipDev[k].append(ch.p.last! - anim.last!)
                    // めり込みは重いので 4 フレームに 1 回（4 倍して足す）
                    for (j, q) in ch.p.enumerated() where frames % 4 == 0 {
                        for col in colliders where col.bone < world.count && !col.moving {
                            let a = Math.point(world[col.bone], col.a), b = Math.point(world[col.bone], col.b)
                            let ab = b - a, u = simd_dot(ab, ab) > 1e-8 ? Math.clamp(simd_dot(q - a, ab) / simd_dot(ab, ab), 0, 1) : 0
                            let depth = col.r + ch.radius[j] - simd_distance(q, a + ab * u)
                            if depth > 0 { penetration += 4 * depth / h }
                        }
                    }
                }
                stretchMax = max(stretchMax, worstStretch)
                if worstStretch > 1.2 { stretchFrames += 1 }
                let bust = c.bust.offsets.map { simd_length($0.1) / h }.max() ?? 0
                bustMax = max(bustMax, bust)
                bustSum += bust
                if !legs.isEmpty && !clothVerts.isEmpty && frames % 4 == 0 {
                    let skin = c.eval.pose.skinning, g = pmx.geometry
                    var depth: Float = 0
                    for v in clothVerts {
                        let p = SIMD4(g.positions[v * 3], g.positions[v * 3 + 1], g.positions[v * 3 + 2], 1)
                        var q = SIMD3<Float>.zero
                        for k in 0..<4 where g.skinWeights[v * 4 + k] > 0 {
                            q += (skin[Int(g.skinIndices[v * 4 + k])] * p).xyz * g.skinWeights[v * 4 + k]
                        }
                        for (a, b, r) in legs {
                            let (pa, pb) = (world[a].columns.3.xyz, world[b].columns.3.xyz)
                            let ab = pb - pa, u = Math.clamp(simd_dot(q - pa, ab) / max(simd_dot(ab, ab), 1e-8), 0, 1)
                            depth += max(0, r - simd_distance(q, pa + ab * u))
                        }
                    }
                    legPenetration += 4 * depth / h / Float(clothVerts.count)
                }
                if !cloth.isEmpty {
                    var a: Float = 0
                    for b in cloth { a += 2 * acos(min(abs(local[b].real), 1)) }
                    joltSwing += a / Float(cloth.count) * 180 / .pi
                }
                prevPos = pos
                prevRot = rot
                prevLocal = local
            }
        }
        let sway = swaySum.map { $0 / Float(max(frames, 1)) }
        // 高い周波数: 揺れのずれの 2 階差分（アニメの動きは引いてある）
        let jitter = tipDev.enumerated().map { k, dev -> Float in
            guard dev.count > 2 else { return 0 }
            var sum: Float = 0
            for i in 1..<(dev.count - 1) { sum += simd_length(dev[i + 1] - 2 * dev[i] + dev[i - 1]) }
            return sum / Float(dev.count - 2) / max(chains[k].len.reduce(0, +), 1e-3)
        }
        return [
            "frames": frames,
            "restarts": c.physicsRestarts - restarts0,
            "nan": nan,
            "badWorld": badWorld,
            "badLocal": badLocal,
            "cause": cause,
            "jump": jump.0 / h,
            "jumpBone": pmx.bones[jump.1].name,
            "stretchMax": stretchMax,
            "stretchFrames": stretchFrames,
            "sway": sway,
            "frozen": sway.filter { $0 < 0.5 }.count,
            "jitter": jitter,
            "penetration": penetration / Float(max(frames, 1)),
            "joltSwing": joltSwing / Float(max(frames, 1)),
            "legPenetration": legPenetration / Float(max(frames, 1)),
            "bustMax": bustMax,
            "bustMean": bustSum / Float(max(frames, 1)),
            "msAvg": stepTime / Double(max(frames, 1)) * 1000,
            "msWorst": worst * 1000,
        ]
    }
}
