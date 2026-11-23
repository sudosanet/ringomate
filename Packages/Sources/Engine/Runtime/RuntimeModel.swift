import simd

final class RuntimeModel: Sendable {
    struct IKLink: Sendable {
        public var bone: Int
        /// ラジアン。
        public var limit: (min: SIMD3<Float>, max: SIMD3<Float>)?
    }

    struct IKSolver: Sendable {
        var ikBone: Int, targetBone: Int
        var links: [IKLink]
        var iterationCount: Int
        var limitAngle: Float
    }

    struct Append: Sendable {
        public var target: Int, source: Int
        public var ratio: Float
        var rotation: Bool, translation: Bool, local: Bool
    }

    public let boneCount: Int
    public let boneNames: [String]
    /// 親（なければ -1）。
    let parents: [Int]
    let restLocal: [SIMD3<Float>]
    let restWorld: [SIMD3<Float>]
    let transformOrder: [Int32]
    let afterPhysics: [Bool]
    /// PMX の軸制限は IK にだけ効く（普段の評価では使わない）。
    let fixedAxis: [SIMD3<Float>?]
    let evalOrder: [Int]
    let evalPhase: [[Int]]
    let evalPosition: [Int]
    let ikSolvers: [IKSolver]
    let ikOfBone: [[Int]]
    let appends: [Append]
    let appendOfBone: [Int?]
    let morphCount: Int
    let boneMorphs: [[(Int, SIMD3<Float>, simd_quatf)]]
    let groupMorphs: [[(Int, Float)]]

    public init(_ pmx: PMXModel) {
        let bones = pmx.bones
        boneCount = bones.count
        boneNames = bones.map(\.name)
        let parents = bones.map { $0.parentIndex >= 0 && Int($0.parentIndex) < bones.count ? Int($0.parentIndex) : -1 }
        self.parents = parents
        restLocal = bones.indices.map { i in parents[i] >= 0 ? bones[i].position - bones[parents[i]].position : bones[i].position }
        restWorld = bones.map(\.position)
        let transformOrder = bones.map(\.layer)
        self.transformOrder = transformOrder
        afterPhysics = bones.map(\.flags.transformAfterPhysics)
        fixedAxis = bones.map { b in
            guard b.flags.fixedAxis, let a = b.fixedAxis, a.x.isFinite, a.y.isFinite, a.z.isFinite,
                  simd_dot(a, a) > .ulpOfOne else { return nil }
            return simd_normalize(a)
        }

        var appends: [Append] = []
        var ikSolvers: [IKSolver] = []
        for (i, b) in bones.enumerated() {
            if b.flags.appendRotate || b.flags.appendTranslate, let a = b.appendTransform, a.parentIndex >= 0, a.weight.isFinite {
                appends.append(Append(target: i, source: Int(a.parentIndex), ratio: a.weight, rotation: b.flags.appendRotate,
                                      translation: b.flags.appendTranslate, local: b.flags.appendLocal))
            }
            if b.flags.ik, let ik = b.ik, ik.targetIndex >= 0, ik.loopCount > 0, ik.limitAngle.isFinite, ik.limitAngle >= 0 {
                let links = ik.links.map { l -> IKLink in
                    let lim = l.limits.flatMap { lim -> (min: SIMD3<Float>, max: SIMD3<Float>)? in
                        let ok = (0..<3).allSatisfy { lim.lower[$0].isFinite && lim.upper[$0].isFinite && lim.lower[$0] <= lim.upper[$0] }
                        return ok ? (lim.lower, lim.upper) : nil
                    }
                    return IKLink(bone: l.boneIndex >= 0 ? Int(l.boneIndex) : 0, limit: lim)
                }
                ikSolvers.append(IKSolver(ikBone: i, targetBone: Int(ik.targetIndex), links: links,
                                          iterationCount: Int(ik.loopCount), limitAngle: ik.limitAngle))
            }
        }
        self.appends = appends
        self.ikSolvers = ikSolvers
        var appendOfBone = [Int?](repeating: nil, count: bones.count)
        for (k, a) in appends.enumerated() { appendOfBone[a.target] = k }
        self.appendOfBone = appendOfBone
        var ikOfBone = [[Int]](repeating: [], count: bones.count)
        for (k, s) in ikSolvers.enumerated() { ikOfBone[s.ikBone].append(k) }
        self.ikOfBone = ikOfBone

        var order: [Int] = []
        var visited = [Bool](repeating: false, count: bones.count)
        let starts = bones.indices.sorted { (transformOrder[$0], $0) < (transformOrder[$1], $1) }
        for s in starts where !visited[s] {
            var chain: [Int] = []
            var c = s
            while c >= 0, !visited[c], !chain.contains(c) {
                chain.append(c)
                c = parents[c]
            }
            for b in chain.reversed() {
                visited[b] = true
                order.append(b)
            }
        }
        evalOrder = order
        let flags = afterPhysics
        evalPhase = [order.filter { !flags[$0] }, order.filter { flags[$0] }]
        var position = [Int](repeating: 0, count: bones.count)
        for (p, b) in order.enumerated() { position[b] = p }
        evalPosition = position

        morphCount = pmx.morphs.count
        boneMorphs = pmx.morphs.map { m in
            m.kind != "bone" ? [] : m.boneOffsets.compactMap { o in
                guard o.boneIndex >= 0, Int(o.boneIndex) < bones.count else { return nil }
                let q = simd_quatf(vector: o.rotation)
                return (Int(o.boneIndex), o.translation, simd_normalize(q))
            }
        }
        groupMorphs = pmx.morphs.map { m in
            m.kind != "group" ? [] : m.groupOffsets.compactMap { o in
                o.morphIndex >= 0 && Int(o.morphIndex) < pmx.morphs.count ? (Int(o.morphIndex), o.weight) : nil
            }
        }
    }

    /// 同じ名前が複数なら最後のもの。
    func ikSolver(named name: String) -> Int? {
        ikSolvers.indices.last { boneNames[ikSolvers[$0].ikBone] == name }
    }

    var toeIKs: [Int] {
        ["左つま先ＩＫ", "左つま先IK", "右つま先ＩＫ", "右つま先IK"].compactMap { ikSolver(named: $0) }
    }

    func evaluationLayers() -> [Int32] {
        var layers = [Int32](repeating: 0, count: boneCount)
        for b in evalOrder {
            layers[b] = parents[b] >= 0 ? max(transformOrder[b], layers[parents[b]]) : transformOrder[b]
        }
        return layers
    }

    func isAncestor(_ ancestor: Int, of bone: Int) -> Bool {
        var c = parents[bone]
        while c >= 0 {
            if c == ancestor { return true }
            c = parents[c]
        }
        return false
    }
}
