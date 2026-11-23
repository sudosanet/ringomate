import Foundation
import simd

extension HairChains {
    mutating func reset(_ world: [simd_float4x4], bones: [PMXModel.Bone]) {
        for c in chains.indices {
            let w = world[chains[c].parent]
            let base = bones[chains[c].parent].position
            chains[c].p = chains[c].rest.map { Math.point(w, $0 - base) }
            chains[c].prev = chains[c].p
            chains[c].lastRoot = chains[c].p.first
        }
    }

    /// `gravity`・`accel`・`floor` はモデルの空間。
    mutating func solve(_ dt: Float, _ world: [simd_float4x4], bones: [PMXModel.Bone], gravity: SIMD3<Float>, accel: SIMD3<Float>,
                        floor: Float?, targets: inout [simd_float4x4?]) {
        guard dt > 0 else { return }
        let t = tuning
        let n = t.substeps
        let h = dt / Float(n)
        let g = gravity - accel * t.world
        let ratio = lastH > 0 && Optimize.enabled("hair_time_fix") ? min(max(h / lastH, 0.25), 4) : 1
        defer { lastH = h }
        let caps: [(SIMD3<Float>, SIMD3<Float>, Float)] = colliders.map { c in
            guard c.bone < world.count else { return (.zero, .zero, 0) }
            let m = c.moving && c.bone < targets.count ? targets[c.bone] ?? world[c.bone] : world[c.bone]
            return (Math.point(m, c.a), Math.point(m, c.b), c.r)
        }
        let surfacePose = surface?.posed(world, targets, maxRadius: chains.compactMap { $0.radius.max() }.max() ?? 0)
        var solved: [Int: simd_float4x4] = [:]
        for c in chains.indices {
            var ch = chains[c]
            if ch.p.count != ch.rest.count { continue }
            let pw = solved[ch.parent] ?? world[ch.parent]
            let base = bones[ch.parent].position
            let root = Math.point(pw, ch.rest[0] - base)
            let anim = ch.rest.map { Math.point(pw, $0 - base) }
            let start = ch.lastRoot ?? root
            let frame0 = Math.rotationOf(pw)
            var interior = Set<Int>()
            for r in ch.rods where r.tip - r.root > 1 { for k in (r.root + 1)..<r.tip { interior.insert(k) } }
            for s in 1...n {
                let f = Float(s) / Float(n)
                for i in 1..<ch.p.count where !interior.contains(i) {
                    let v = (ch.p[i] - ch.prev[i]) * exp(-h * ch.damp[i]) * (s == 1 ? ratio : 1)
                    ch.prev[i] = ch.p[i]
                    ch.p[i] += v + g * (h * h)
                }
                ch.p[0] = start + (root - start) * f
                ch.prev[0] = ch.p[0]
                var touch = [SIMD3<Float>](repeating: .zero, count: ch.p.count)
                for i in 1..<ch.p.count {
                    for k in ch.hits where t.hit > 0 {
                        let (a, b, r) = caps[k]
                        let ab = b - a
                        let u = simd_dot(ab, ab) > 1e-8 ? min(max(simd_dot(ch.p[i] - a, ab) / simd_dot(ab, ab), 0), 1) : 0
                        let q = a + ab * u, d = ch.p[i] - q
                        let dist = simd_length(d), allowed = ch.allow[i][k], need = allowed.isNaN ? r + ch.radius[i] : allowed
                        // 1 刻みに半径の `push` 倍まで（速く動く腕に一気に押されて先が飛ぶ）
                        if dist < need && dist > 1e-6 {
                            ch.p[i] += d * (min(need - dist, ch.radius[i] * t.push) / dist)
                            touch[i] += d / dist
                        }
                    }
                    if let surface, let surfacePose, t.hit > 0 {
                        touch[i] += surface.push(&ch.p[i], chain: c, point: i, radius: ch.radius[i], cap: ch.radius[i] * t.push, surfacePose)
                    }
                    if let floor, ch.p[i].y < floor + ch.radius[i] {
                        ch.p[i].y = floor + ch.radius[i]
                        touch[i].y += 1
                    }
                }
                // 形の目標はアニメの姿勢での形で、揺れた結果から作らない（長い鎖で揺れが増幅する）
                for _ in 0..<2 {
                    var i = 0
                    while i < ch.p.count - 1 {
                        let rod = ch.rods.first { $0.root == i }
                        let j = rod?.tip ?? i + 1
                        let offset = anim[j] - anim[i]
                        let want = offset / max(simd_length(offset), 1e-6)
                        // 寄せたぶんは前の位置も動かして勢いにしない（勢いにすると減衰のない硬いばねになって震える）
                        let k = 1 - exp(-h * ch.stiff[i + 1] * 0.5)
                        let pull = (ch.p[i] + offset - ch.p[j]) * k
                        ch.p[j] += pull
                        ch.prev[j] += pull
                        var d = ch.p[j] - ch.p[i]
                        let length = simd_length(d)
                        if length > 1e-6 {
                            d /= length
                            let coneCos = rod?.cone ?? ch.cone[min(i, ch.cone.count - 1)]
                            if simd_dot(d, want) < coneCos {
                                let goal = Self.rotate(want, toward: d, cos: coneCos)
                                ch.p[j] = ch.p[i] + simd_normalize(d + (goal - d) * 0.5) * length
                            }
                        }
                        let e = ch.p[j] - ch.p[i], l = simd_length(e), rest = simd_length(offset)
                        if l > 1e-6 {
                            let wi: Float = i == 0 ? 0 : 1 + Float(i) * 0.1, wj: Float = 1 + Float(j) * 0.1
                            let corr = e * ((l - rest) / l / (wi + wj))
                            ch.p[i] += corr * wi
                            ch.p[j] -= corr * wj
                        }
                        if j > i + 1 {
                            let now = ch.p[j] - ch.p[i]
                            let turn = simd_length(now) > 1e-6 && simd_dot(want, simd_normalize(now)) > -0.999
                                ? simd_normalize(simd_quatf(from: want, to: simd_normalize(now))) : Math.identity
                            for m in (i + 1)..<j {
                                ch.p[m] = ch.p[i] + turn.act(anim[m] - anim[i])
                                ch.prev[m] = ch.p[m]
                            }
                        }
                        i = j
                    }
                }
                // 押し出しを勢いにすると弾んで震えるので、当たった向きの成分を消す（横すべりは残す）
                for i in 1..<ch.p.count where touch[i] != .zero {
                    let nrm = simd_normalize(touch[i]), v = ch.p[i] - ch.prev[i]
                    ch.prev[i] = ch.p[i] - (v - nrm * max(simd_dot(v, nrm), 0))
                }
            }
            ch.lastRoot = root
            var frame = frame0
            for (i, b) in ch.bones.enumerated() {
                let want = frame.act(ch.dir[i])
                let e = ch.p[i + 1] - ch.p[i]
                // ほぼ真逆の向きへの回転は定まらないので回さない
                if simd_length(e) > 1e-6, simd_dot(want, simd_normalize(e)) > -0.999 {
                    frame = simd_normalize(simd_quatf(from: want, to: simd_normalize(e)) * frame)
                }
                let m = Math.matrix(frame, ch.p[i])
                targets[b] = m
                solved[b] = m
            }
            chains[c] = ch
        }
    }

    static func rotate(_ want: SIMD3<Float>, toward d: SIMD3<Float>, cos c: Float) -> SIMD3<Float> {
        let side = d - want * simd_dot(d, want)
        guard simd_length(side) > 1e-6 else { return want }
        let s = (1 - c * c).squareRoot()
        return simd_normalize(want * c + simd_normalize(side) * s)
    }
}
