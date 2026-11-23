import simd

/// 服のメッシュの表面（フード・袖など）に髪を当てる。間引いた頂点から法線の外側へ、浅いめり込みだけ押す。
/// ponytail: 頂点は一番重い骨だけに付ける。ずれが目立つなら重みで混ぜる。
struct HairSurface {
    struct Point {
        var bone: Int
        var p: SIMD3<Float>, n: SIMD3<Float>
    }

    private(set) var points: [Point] = []
    /// 鎖・点ごとに、止まっているときから内側にある表面の点（少ないので配列）。
    private(set) var skip: [[[Int32]]] = []
    let r: Float

    init(_ pmx: PMXModel, chains: [HairChains.Chain], excluded: (Int) -> Bool) {
        let g = pmx.geometry, bones = pmx.bones
        let count = g.positions.count / 3
        let height = stride(from: 1, to: g.positions.count, by: 3).map { g.positions[$0] }.max() ?? 20
        let vox = height * 0.012
        r = vox * 0.8
        guard !chains.isEmpty, g.skinIndices.count >= count * 4, g.normals.count >= count * 3 else { return }
        var reach: [(SIMD3<Float>, Float)] = chains.map { ch in (ch.rest[0], ch.len.reduce(0, +) + 2 * (ch.radius.max() ?? 0)) }
        reach = reach.filter { $0.1 > 0 }
        var seen = Set<SIMD3<Int32>>()
        for v in 0..<count {
            var best = 0, bw: Float = -1
            for s in 0..<4 where g.skinWeights[v * 4 + s] > bw { (best, bw) = (s, g.skinWeights[v * 4 + s]) }
            let bone = Int(g.skinIndices[v * 4 + best])
            guard bw > 0.8, bone < bones.count, !excluded(bone) else { continue }
            let p = SIMD3(g.positions[v * 3], g.positions[v * 3 + 1], g.positions[v * 3 + 2])
            guard reach.contains(where: { simd_distance($0.0, p) < $0.1 }) else { continue }
            let key = SIMD3<Int32>(Int32((p.x / vox).rounded(.down)), Int32((p.y / vox).rounded(.down)), Int32((p.z / vox).rounded(.down)))
            guard seen.insert(key).inserted else { continue }
            let n = SIMD3(g.normals[v * 3], g.normals[v * 3 + 1], g.normals[v * 3 + 2])
            guard simd_length(n) > 1e-4 else { continue }
            points.append(Point(bone: bone, p: p - bones[bone].position, n: simd_normalize(n)))
        }
        skip = chains.map { ch in
            ch.rest.indices.map { i in
                points.indices.filter { k in
                    let d = ch.rest[i] - (points[k].p + bones[points[k].bone].position)
                    return simd_length(d) < r + ch.radius[i] && simd_dot(d, points[k].n) < ch.radius[i]
                }.map(Int32.init)
            }
        }
    }

    struct Posed {
        var p: [SIMD3<Float>], n: [SIMD3<Float>]
        var grid: CellGrid
    }

    var isEmpty: Bool { points.isEmpty }

    /// 揺れものの骨は解いたあとの姿勢（`targets`）。
    func posed(_ world: [simd_float4x4], _ targets: [simd_float4x4?], maxRadius: Float) -> Posed {
        var p: [SIMD3<Float>] = [], n: [SIMD3<Float>] = []
        p.reserveCapacity(points.count)
        n.reserveCapacity(points.count)
        for s in points {
            let m = s.bone < world.count ? (s.bone < targets.count ? targets[s.bone] ?? world[s.bone] : world[s.bone]) : matrix_identity_float4x4
            p.append(Math.point(m, s.p))
            n.append(simd_normalize(Math.rotate(Math.rotationOf(m), s.n)))
        }
        return Posed(p: p, n: n, grid: CellGrid(p, cell: r + maxRadius))
    }

    /// 1 回に `cap` まで。
    func push(_ x: inout SIMD3<Float>, chain c: Int, point i: Int, radius: Float, cap: Float,
              _ posed: Posed) -> SIMD3<Float> {
        var touch = SIMD3<Float>.zero
        let skip = self.skip[c][i]
        let start = x
        posed.grid.near(start) { k in
            guard !skip.contains(Int32(k)) else { return }
            let (v, n) = (posed.p[k], posed.n[k])
            let d = x - v
            let depth = radius - simd_dot(d, n)
            // 深すぎる（裏側の髪）ものは押さない
            guard depth > 0, depth < radius + r * 0.5, simd_length_squared(d) < (r + radius) * (r + radius) else { return }
            x += n * min(depth, cap)
            touch += n
        }
        return touch
    }
}

/// 点を立方体のセルに分けて、あるセルとその周り 26 個のセルの点を引く（鍵は 3 軸を詰めた Int64）。
struct CellGrid {
    let cell: Float
    private var cells: [Int64: [Int32]] = [:]

    init(_ points: [SIMD3<Float>], cell: Float) {
        self.cell = cell
        cells.reserveCapacity(points.count)
        for (i, p) in points.enumerated() { cells[Self.key(Self.coord(p, cell)), default: []].append(Int32(i)) }
    }

    static func coord(_ p: SIMD3<Float>, _ cell: Float) -> SIMD3<Int32> {
        SIMD3(Int32((p.x / cell).rounded(.down)), Int32((p.y / cell).rounded(.down)), Int32((p.z / cell).rounded(.down)))
    }

    /// 各軸 21 ビット（±100 万セル）。
    static func key(_ c: SIMD3<Int32>) -> Int64 {
        let bias: Int64 = 1 << 20, mask: Int64 = (1 << 21) - 1
        return ((Int64(c.x) + bias) & mask) << 42 | ((Int64(c.y) + bias) & mask) << 21 | ((Int64(c.z) + bias) & mask)
    }

    /// 点の番号を、セルの順（dx・dy・dz、同じセルの中は番号の昇順）で渡す。
    func near(_ x: SIMD3<Float>, _ body: (Int) -> Void) {
        let c = Self.coord(x, cell)
        for dx in Int32(-1)...1 { for dy in Int32(-1)...1 { for dz in Int32(-1)...1 {
            guard let list = cells[Self.key(c &+ SIMD3(dx, dy, dz))] else { continue }
            for k in list { body(Int(k)) }
        } } }
    }
}
