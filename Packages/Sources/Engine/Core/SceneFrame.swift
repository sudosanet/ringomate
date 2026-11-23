import simd

extension Puppet {
    /// 列優先の float4x4。
    func writeSkinning(into out: UnsafeMutableBufferPointer<Float>) {
        let place = self.place()
        let skinning = eval.pose.skinning
        for (i, m) in skinning.prefix(out.count / 16).enumerated() {
            let w = Math.mul(place, m)
            for c in 0..<4 { for r in 0..<4 { out[i * 16 + c * 4 + r] = w[c][r] } }
        }
    }

    /// xyz 連続。
    func writePositions(into out: UnsafeMutableBufferPointer<Float>) {
        let base = model.pmx.geometry.positions
        let n = min(base.count, out.count)
        base.withUnsafeBufferPointer { b in _ = UnsafeMutableBufferPointer(rebasing: out[0..<n]).update(fromContentsOf: b[0..<n]) }
        let weights = eval.pose.morphWeights
        for mi in vertexMorphs {
            let w = mi < weights.count ? weights[mi] : 0
            if w == 0 { continue }
            for o in model.pmx.morphs[mi].vertexOffsets {
                let v = Int(o.vertexIndex) * 3
                if v + 2 < n {
                    out[v] += o.position.x * w
                    out[v + 1] += o.position.y * w
                    out[v + 2] += o.position.z * w
                }
            }
        }
        bust.apply(to: UnsafeMutableBufferPointer(rebasing: out[0..<n]))
    }
}

extension Scene {
    public func step(_ dt: Float, _ inputs: Inputs, skin: UnsafeMutableBufferPointer<Float>,
                     positions: UnsafeMutableBufferPointer<Float>) -> (Output, bones: Int)? {
        guard let out = step(dt, inputs) else { return nil }
        return lock.withLock {
            guard let c = state?.character else { return nil }
            if positions.baseAddress != nil { c.writePositions(into: positions) }
            if skin.baseAddress != nil { c.writeSkinning(into: skin) }
            return (out, c.boneCount)
        }
    }
}
