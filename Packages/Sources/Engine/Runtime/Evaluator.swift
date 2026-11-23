import simd

/// mmd-anim-runtime の移植（物理以外）。
final class Evaluator {
    let model: RuntimeModel
    var pose: Pose
    var transform: [simd_float4x4]
    var ikHistory: [simd_quatf?]
    var ikTargetHistory: [(Int, simd_float4x4)]
    let layerBones: [[[Int]]]
    let ikDeferredAppend: [Bool]
    var ikUpdateBones: [[Int]?]
    var ikScratch = IKScratch()

    init(_ model: RuntimeModel) {
        self.model = model
        pose = Pose(bones: model.boneCount, morphs: model.morphCount, iks: model.ikSolvers.count)
        transform = Array(repeating: matrix_identity_float4x4, count: model.boneCount)
        let layers = model.evaluationLayers()
        layerBones = [false, true].map { after in
            var groups: [Int32: [Int]] = [:]
            for b in model.evalPhase[after ? 1 : 0] { groups[layers[b], default: []].append(b) }
            return groups.keys.sorted().map { groups[$0]! }
        }
        let (underIK, dependent) = Self.dependencyRoles(model)
        ikHistory = zip(dependent, underIK).map { $0 && $1 ? Math.identity : nil }
        ikDeferredAppend = dependent.indices.map { i in
            dependent[i] && !underIK[i] && model.ikSolvers.contains { $0.targetBone == i }
        }
        ikUpdateBones = Array(repeating: nil, count: model.ikSolvers.count)
        ikTargetHistory = Self.initialTargetHistory(model, layers)
    }

    static func initialTargetHistory(_ model: RuntimeModel, _ layers: [Int32]) -> [(Int, simd_float4x4)] {
        var rest = [SIMD3<Float>](repeating: .zero, count: model.boneCount)
        for b in model.evalOrder { rest[b] = model.restLocal[b] + (model.parents[b] >= 0 ? rest[model.parents[b]] : .zero) }
        var history: [(Int, simd_float4x4)] = []
        for s in model.ikSolvers where layers[s.targetBone] > layers[s.ikBone] && !history.contains(where: { $0.0 == s.targetBone }) {
            history.append((s.targetBone, Math.translation(rest[s.targetBone])))
        }
        return history
    }

    /// (IK の鎖の骨か, その骨から付与を受ける骨かその子孫か)。骨の番号の順に調べる（MMD と同じ）。
    static func dependencyRoles(_ model: RuntimeModel) -> ([Bool], [Bool]) {
        var underIK = [Bool](repeating: false, count: model.boneCount)
        for s in model.ikSolvers {
            underIK[s.ikBone] = false
            underIK[s.targetBone] = false
            for l in s.links { underIK[l.bone] = true }
        }
        var dependent = [Bool](repeating: false, count: model.boneCount)
        for i in 0..<model.boneCount {
            let p = model.parents[i]
            dependent[i] = (p >= 0 && dependent[p]) || model.appendOfBone[i].map { k in
                let a = model.appends[k]
                return (a.rotation || a.translation) && underIK[a.source]
            } ?? false
        }
        return (underIK, dependent)
    }

    var ikMemory: ([simd_quatf?], [(Int, simd_float4x4)]) {
        get { (ikHistory, ikTargetHistory) }
        set { (ikHistory, ikTargetHistory) = newValue }
    }

    func resetIKHistory() {
        for i in ikHistory.indices where ikHistory[i] != nil { ikHistory[i] = Math.identity }
        ikTargetHistory = Self.initialTargetHistory(model, model.evaluationLayers())
    }

    func evaluate() {
        resetIKRotations()
        begin()
        var earliest: Int?
        phase(false, &earliest)
        phase(true, &earliest)
        finish(earliest)
    }

    func evaluateBeforePhysics() {
        resetIKRotations()
        begin()
        var earliest: Int?
        phase(false, &earliest)
    }

    func evaluateAfterPhysics() {
        var earliest: Int?
        phase(true, &earliest)
        finish(earliest)
    }

    func resetIKRotations() { for i in pose.ikRotations.indices { pose.ikRotations[i] = Math.identity } }

    func begin() {
        for b in 0..<model.boneCount { pose.resetAppend(b) }
        for b in model.evalOrder { updateWorld(b) }
        for (b, w) in ikTargetHistory {
            pose.world[b] = w
            transform[b] = Math.mul(w, Math.translation(-model.restWorld[b]))
            pose.skinning[b] = Math.mul(w, Math.translation(-model.restWorld[b]))
        }
    }

    func phase(_ after: Bool, _ earliest: inout Int?) {
        for layer in layerBones[after ? 1 : 0] {
            for b in layer {
                if after { earliest = min(earliest ?? .max, model.evalPosition[b]) }
                if model.appendOfBone[b] != nil {
                    pose.resetAppend(b)
                    updateAppend(b)
                }
                updateWorld(b)
            }
            for b in layer { for k in model.ikOfBone[b] { solveIK(k) } }
            for b in layer where ikDeferredAppend[b] {
                updateAppend(b)
                updateWorld(b)
            }
        }
    }

    func finish(_ earliest: Int?) {
        var start = earliest
        for a in model.appends where model.evalPosition[a.target] < model.evalPosition[a.source] {
            start = min(start ?? .max, model.evalPosition[a.target])
        }
        if let s = start { updateWorldFrom(expandStart(s)) }
        for k in ikTargetHistory.indices { ikTargetHistory[k].1 = pose.world[ikTargetHistory[k].0] }
    }

    func updateWorldFrom(_ position: Int) {
        let start = expandStart(position)
        for b in model.evalOrder[start...] { pose.resetAppend(b) }
        for b in model.evalOrder[start...] {
            updateAppend(b)
            updateWorld(b)
        }
    }

    func expandStart(_ position: Int) -> Int {
        var start = position
        while true {
            var changed = false
            for a in model.appends {
                if model.evalPosition[a.source] >= start && model.evalPosition[a.target] < start {
                    start = model.evalPosition[a.target]
                    changed = true
                }
            }
            if !changed { return start }
        }
    }

    func updateAppend(_ bone: Int, except preserved: Int? = nil) {
        var visiting: [Int] = []
        updateAppendInner(bone, &visiting, preserved)
    }

    func updateAppendInner(_ bone: Int, _ visiting: inout [Int], _ preserved: Int?) {
        guard preserved != bone, let k = model.appendOfBone[bone], !visiting.contains(bone) else { return }
        visiting.append(bone)
        let a = model.appends[k]
        let useSource = !a.local && model.appendOfBone[a.source] != nil
        if useSource { updateAppendInner(a.source, &visiting, preserved) }
        var rotation = pose.localRotations[a.source]
        if useSource { rotation = MMDMath.multiply(pose.appendRotations[a.source], rotation) }
        let offset = useSource ? pose.appendOffsets[a.source] : pose.localOffsets[a.source]
        pose.appendRotations[bone] = a.rotation ? MMDMath.scaleRotation(rotation, a.ratio) : Math.identity
        pose.appendOffsets[bone] = a.translation ? offset * a.ratio : .zero
        visiting.removeLast()
    }

    func updateWorld(_ bone: Int, rotationMatrix: simd_float4x4? = nil) {
        var matrix = rotationMatrix
        var rotation = pose.localRotations[bone]
        var offset = pose.localOffsets[bone]
        if let k = model.appendOfBone[bone] {
            if model.appends[k].rotation {
                matrix = nil
                rotation = MMDMath.multiply(pose.appendRotations[bone], rotation)
            }
            if model.appends[k].translation { offset += pose.appendOffsets[bone] }
        }
        let rest = model.restWorld[bone]
        var r = matrix ?? MMDMath.rotationMatrix(rotation)
        let s = pose.localScales[bone]
        if s != SIMD3(repeating: 1) {
            r.columns.0 *= s.x
            r.columns.1 *= s.y
            r.columns.2 *= s.z
        }
        let local = Math.translationMul(rest, Math.translationMul(offset, Math.mulTranslation(r, -rest)))
        let p = model.parents[bone]
        let skin = p >= 0 ? Math.mul(transform[p], local) : local
        let world = Math.mulTranslation(skin, rest)
        transform[bone] = skin
        pose.world[bone] = world
        pose.skinning[bone] = Math.mulTranslation(world, -rest)
    }

    func expandMorphs() {
        let n = model.morphCount
        if model.groupMorphs.contains(where: { !$0.isEmpty }) {
            var expanded = Array(pose.morphWeights[..<n])
            for m in 0..<n where pose.morphWeights[m] != 0 {
                var stack: [(Int, Float, Int)] = [(m, pose.morphWeights[m], 0)]
                while !stack.isEmpty {
                    let (morph, weight, next) = stack[stack.count - 1]
                    let offsets = model.groupMorphs[morph]
                    if next >= offsets.count {
                        stack.removeLast()
                        continue
                    }
                    stack[stack.count - 1].2 += 1
                    let (child, ratio) = offsets[next]
                    let contribution = weight * ratio
                    expanded[child] += contribution
                    if !model.groupMorphs[child].isEmpty { stack.append((child, contribution, 0)) }
                }
            }
            for i in 0..<n { pose.morphWeights[i] = expanded[i] }
        }
        for (m, offsets) in model.boneMorphs.enumerated() where !offsets.isEmpty {
            let w = pose.morphWeights[m]
            if w == 0 { continue }
            for (b, position, rotation) in offsets {
                pose.localOffsets[b] += position * w
                let scaled = Math.slerp(Math.identity, rotation, w)
                pose.localRotations[b] = simd_normalize(Math.mul(pose.localRotations[b], scaled))
            }
        }
    }
}
