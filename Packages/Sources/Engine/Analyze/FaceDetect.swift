import simd

/// 顔とそのパーツ（目・眉・まつ毛）の材質を形から見つける。
enum FaceDetect {
    struct Stats {
        /// 頭だけに付く頂点（揺れものの骨を除く）の割合。
        var head: Float
        /// 前（−Z）を向く頂点の割合。
        var front: Float
        /// 表情モーフが動かす頂点の割合。
        var moved: Float
        var area: Float
        var center: SIMD3<Float>
        var opaque: Bool
        /// 目の骨（左目・右目・両目とその子）に付く頂点の割合。
        var eye: Float
    }

    static func stats(_ pmx: PMXModel) -> (stats: [Stats?], head: SIMD3<Float>)? {
        let bones = pmx.bones, g = pmx.geometry
        guard let head = bones.firstIndex(where: { $0.name == "頭" }) else { return nil }
        let swinging = Set(pmx.rigidBodies.filter { $0.mode != "static" && $0.boneIndex >= 0 }.map { Int($0.boneIndex) })
        var underHead = [Bool?](repeating: nil, count: bones.count)
        func inHead(_ b: Int) -> Bool {
            if let known = underHead[b] { return known }
            var x = b, steps = 0, result = false
            while x >= 0 && steps < 256 {
                if x == head { result = true; break }
                if swinging.contains(x) { break }
                x = Int(bones[x].parentIndex)
                steps += 1
            }
            underHead[b] = result
            return result
        }
        let count = g.positions.count / 3
        let perVertex = max(g.skinIndices.count / max(count, 1), 1)
        let eyeRoots = Set(["左目", "右目", "両目"].compactMap { n in bones.firstIndex { $0.name == n } })
        func onEye(_ b: Int) -> Bool {
            var x = b, steps = 0
            while x >= 0 && steps < 8 {
                if eyeRoots.contains(x) { return true }
                x = Int(bones[x].parentIndex)
                steps += 1
            }
            return false
        }
        var headVertex = [Bool](repeating: false, count: count), eyeVertex = [Bool](repeating: false, count: count)
        for v in 0..<count {
            var best: (Float, Int) = (-1, -1)
            for k in 0..<perVertex where g.skinWeights[v * perVertex + k] > best.0 {
                best = (g.skinWeights[v * perVertex + k], Int(g.skinIndices[v * perVertex + k]))
            }
            headVertex[v] = best.1 >= 0 && best.1 < bones.count && inHead(best.1)
            eyeVertex[v] = best.1 >= 0 && best.1 < bones.count && onEye(best.1)
        }
        var moved = [Bool](repeating: false, count: count)
        let faceMorphs = pmx.morphs.filter { $0.kind == "vertex" && ($0.panel == "mouth" || $0.panel == "eye") }
        for m in faceMorphs.isEmpty ? pmx.morphs.filter({ $0.kind == "vertex" }) : faceMorphs {
            for o in m.vertexOffsets where Int(o.vertexIndex) < count && simd_length(o.position) > 1e-5 { moved[Int(o.vertexIndex)] = true }
        }
        func p(_ v: Int) -> SIMD3<Float> { SIMD3(g.positions[v * 3], g.positions[v * 3 + 1], g.positions[v * 3 + 2]) }
        var start = 0
        let out = pmx.materials.map { mat -> Stats? in
            let n = Int(mat.faceCount) * 3
            defer { start += n }
            guard n > 0 else { return nil }
            let tri = g.indices[start..<start + n].map(Int.init)
            let verts = Set(tri)
            var area: Float = 0
            for t in stride(from: 0, to: tri.count - 2, by: 3) where headVertex[tri[t]] {
                area += simd_length(simd_cross(p(tri[t + 1]) - p(tri[t]), p(tri[t + 2]) - p(tri[t]))) / 2
            }
            var inside = 0, front = 0, move = 0, eye = 0, center = SIMD3<Float>.zero
            for v in verts {
                if eyeVertex[v] { eye += 1 }
                if headVertex[v] { inside += 1 }
                if g.normals[v * 3 + 2] < -0.5 { front += 1 }
                if moved[v] { move += 1 }
                center += p(v)
            }
            let total = Float(verts.count)
            return Stats(head: Float(inside) / total, front: Float(front) / total, moved: Float(move) / total, area: area,
                         center: center / total, opaque: mat.diffuse.w > 0.98, eye: Float(eye) / total)
        }
        return (out, bones[head].position)
    }

    /// 頭だけに付く不透明な材質で、前向きの割合 0.35〜0.9（平たい瞳・まつ毛は 0.9 超）、表情で 15% 以上動き、
    /// 頭より前で、前向きの面積が最大かつ身長の 5% 角より大きいもの。
    static func material(_ pmx: PMXModel) -> Int? {
        guard let (stats, head) = stats(pmx) else { return nil }
        let minArea = pow(Puppet.height(pmx) * 0.05, 2)
        var best: (Int, Float)?
        for (i, s) in stats.enumerated() {
            guard let s, s.opaque, s.head > 0.9, s.front >= 0.35, s.front < 0.9, s.moved >= 0.15, s.center.z < head.z, s.area > minArea else { continue }
            let score = s.area * s.front
            if best == nil || score > best!.1 { best = (i, score) }
        }
        return best?.0
    }

    /// 前向きの面が 8 割以上の平たいパーツ。向きの混ざるもの（白目・眼球）は後ろ髪越しに透けるので、
    /// 顔の面より奥のもの（表情で出す隠し模様）は見えてはいけないので入れない。
    static func seeThrough(_ pmx: PMXModel, face: Set<Int>, features: Set<Int>) -> Set<Int> {
        guard !features.isEmpty, let (stats, _) = stats(pmx),
              let main = face.compactMap({ $0 < stats.count ? stats[$0] : nil }).max(by: { $0.area < $1.area }) else { return [] }
        return features.filter { i in
            guard i < stats.count, let s = stats[i] else { return false }
            return s.front >= 0.8 && s.center.z < main.center.z
        }
    }

    /// 正面から見て目・眉に重なり、それより前にある材質（前髪）。
    /// 後ろ髪まで含む材質は除く（後ろから目が透ける）。
    static func bangs(_ pmx: PMXModel, face: Set<Int>, features: Set<Int>) -> Set<Int> {
        guard !features.isEmpty else { return [] }
        let g = pmx.geometry
        func p(_ v: Int) -> SIMD3<Float> { SIMD3(g.positions[v * 3], g.positions[v * 3 + 1], g.positions[v * 3 + 2]) }
        var ranges: [Range<Int>] = []
        var start = 0
        for m in pmx.materials {
            let n = Int(m.faceCount) * 3
            ranges.append(start..<start + n)
            start += n
        }
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in features where i < ranges.count {
            for k in ranges[i] { let q = p(Int(g.indices[k])); lo = simd_min(lo, q); hi = simd_max(hi, q) }
        }
        guard lo.x <= hi.x, let headBone = pmx.bones.firstIndex(where: { $0.name == "頭" }) else { return [] }
        let headZ = pmx.bones[headBone].position.z
        return Set(pmx.materials.indices.filter { i in
            guard !face.contains(i), !features.contains(i) else { return false }
            var cover = 0, back = 0, total = 0
            for t in stride(from: ranges[i].lowerBound, to: ranges[i].upperBound - 2, by: 3) {
                let c = (p(Int(g.indices[t])) + p(Int(g.indices[t + 1])) + p(Int(g.indices[t + 2]))) / 3
                if c.x > lo.x && c.x < hi.x && c.y > lo.y && c.y < hi.y && c.z < lo.z { cover += 1 }
                if c.z > headZ { back += 1 }
                total += 1
            }
            return cover >= 8 && back * 5 < total
        })
    }

    /// 顔の上半分の、顔より小さく、表情で動くか目の骨に付く材質（目・眉・まつ毛）。
    static func features(_ pmx: PMXModel, face: Set<Int>) -> Set<Int> {
        guard !face.isEmpty, let (stats, head) = stats(pmx) else { return [] }
        let faces = face.compactMap { $0 < stats.count ? stats[$0] : nil }
        guard let main = faces.max(by: { $0.area < $1.area }) else { return [] }
        let width = Puppet.height(pmx) * 0.08
        return Set(stats.indices.filter { i in
            guard !face.contains(i), let s = stats[i] else { return false }
            return s.head > 0.9 && s.center.z < head.z && s.center.y >= main.center.y && s.center.y < main.center.y + width
                && abs(s.center.x - main.center.x) < width && s.area < main.area && (s.moved >= 0.1 || s.eye >= 0.5)
        })
    }
}
