import simd

/// 名前の規則で胸の骨が見つからないときの、形からの候補。
enum BustDetect {
    /// 胸らしい名前（「胸」「乳」「breast」「chest」…）で、胴に直接ぶら下がり、頂点が胸の前に付く左右対の骨（左, 右）。
    /// `weight`・`center` は骨ごとのスキンの重みの合計と重心。
    static func pair(_ pmx: PMXModel, weight: [Float], center: [SIMD3<Float>], height: Float) -> (left: Int, right: Int)? {
        let bones = pmx.bones
        func index(_ n: String) -> Int? { bones.firstIndex { $0.name == n } }
        let torsoNames = ["上半身", "上半身2", "上半身3"]
        let torso = Set(torsoNames.compactMap(index))
        guard let chest = index("上半身2") ?? index("上半身"), let neck = index("首") else { return nil }
        let (low, high) = (bones[chest].position.y - height * 0.05, bones[neck].position.y)
        let front = bones[chest].position.z
        let candidates = bones.indices.filter { b in
            let n = bones[b].name.lowercased()
            let named = Bust.isBreast(bones[b].name) || n.contains("chest") || n.contains("breast")
            let c = center[b]
            return named && weight[b] > 0 && bones[b].parentIndex >= 0 && torso.contains(Int(bones[b].parentIndex))
                && c.y > low && c.y < high && c.z < front && abs(c.x) > height * 0.01
        }
        var best: (Int, Int, Float)?
        for l in candidates where center[l].x > 0 {
            for r in candidates where center[r].x < 0 {
                let (cl, cr) = (center[l], center[r])
                guard abs(cl.x + cr.x) < abs(cl.x) * 0.25, abs(cl.y - cr.y) < height * 0.03,
                      weight[l] / weight[r] > 0.5, weight[l] / weight[r] < 2 else { continue }
                let total = weight[l] + weight[r]
                if best == nil || total > best!.2 { best = (l, r, total) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }
}
