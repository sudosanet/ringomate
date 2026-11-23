extension PMXModel {
    /// 読んだ直後に一度だけ通す。描画（GPU・meshopt）が範囲外を読み書きしないことと、骨の親が輪にならないことを保証する。
    /// 頂点・面の不整合は throw、骨などの参照の誤りは -1 にして続ける。
    mutating func validate() throws {
        let vertexCount = geometry.positions.count / 3
        guard geometry.positions.count == vertexCount * 3,
              geometry.normals.count == vertexCount * 3,
              geometry.uvs.count == vertexCount * 2,
              geometry.skinIndices.count == vertexCount * 4,
              geometry.skinWeights.count == vertexCount * 4,
              geometry.indices.count % 3 == 0
        else { throw FormatError.invalid("vertex arrays do not match the vertex count") }
        guard geometry.indices.allSatisfy({ Int($0) < vertexCount }) else {
            throw FormatError.invalid("a face refers to a vertex that does not exist")
        }
        let faceIndices = materials.reduce(0) { $0 + Int(max($1.faceCount, 0)) * 3 }
        guard faceIndices <= geometry.indices.count else {
            throw FormatError.invalid("materials have more faces than the model")
        }

        let boneCount = bones.count
        var repaired = 0
        func bone(_ i: Int32) -> Int32 {
            if i >= 0 && Int(i) < boneCount { return i }
            if i != -1 { repaired += 1 }
            return -1
        }
        func drop<T>(_ list: inout [T], _ bad: (T) -> Bool) {
            let n = list.count
            list.removeAll(where: bad)
            repaired += n - list.count
        }
        for i in geometry.skinIndices.indices where Int(geometry.skinIndices[i]) >= boneCount {
            repaired += 1
            geometry.skinIndices[i] = 0
            geometry.skinWeights[i] = 0
        }
        for i in bones.indices {
            bones[i].parentIndex = bone(bones[i].parentIndex)
            bones[i].tailIndex = bone(bones[i].tailIndex)
            if let a = bones[i].appendTransform {
                bones[i].appendTransform = bone(a.parentIndex) < 0 ? nil : a
            }
            if var ik = bones[i].ik {
                drop(&ik.links) { bone($0.boneIndex) < 0 }
                bones[i].ik = bone(ik.targetIndex) < 0 ? nil : ik
            }
        }
        repaired += breakParentCycles()

        let morphCount = morphs.count, rigidCount = rigidBodies.count, materialCount = materials.count
        for i in morphs.indices {
            drop(&morphs[i].vertexOffsets) { Int($0.vertexIndex) >= vertexCount }
            drop(&morphs[i].uvOffsets) { Int($0.vertexIndex) >= vertexCount }
            drop(&morphs[i].additionalUVOffsets) { Int($0.vertexIndex) >= vertexCount }
            drop(&morphs[i].boneOffsets) { bone($0.boneIndex) < 0 }
            drop(&morphs[i].groupOffsets) { $0.morphIndex < 0 || Int($0.morphIndex) >= morphCount }
            drop(&morphs[i].flipOffsets) { $0.morphIndex < 0 || Int($0.morphIndex) >= morphCount }
            drop(&morphs[i].materialOffsets) { $0.materialIndex < -1 || Int($0.materialIndex) >= materialCount }
            drop(&morphs[i].impulseOffsets) { $0.rigidBodyIndex < 0 || Int($0.rigidBodyIndex) >= rigidCount }
        }
        for i in rigidBodies.indices { rigidBodies[i].boneIndex = bone(rigidBodies[i].boneIndex) }
        drop(&joints) { j in
            ![j.rigidBodyIndexA, j.rigidBodyIndexB].allSatisfy { $0 >= 0 && Int($0) < rigidCount }
        }
        for i in displayFrames.indices {
            drop(&displayFrames[i].frames) { $0.index < 0 || Int($0.index) >= ($0.kind == "bone" ? boneCount : morphCount) }
        }
        if repaired > 0 {
            diagnostics.append(Diagnostic(level: "warning", code: "PMX_REFERENCES_REPAIRED",
                                          message: "\(repaired) references to missing bones, vertices, morphs or bodies were removed."))
        }
    }

    /// 親を根までたどる（自分は含まない）。`validate` のあとは輪がないので必ず終わる。
    func ancestors(of bone: Int) -> UnfoldSequence<Int, Int> {
        sequence(state: bone) { b in
            let p = Int(bones[b].parentIndex)
            guard p >= 0 else { return nil }
            b = p
            return p
        }
    }

    /// 親をたどって骨の数を超えたら輪がある。その骨を根にして輪を切る。
    private mutating func breakParentCycles() -> Int {
        var broken = 0
        for i in bones.indices {
            var p = bones[i].parentIndex, steps = 0
            while p >= 0 && steps <= bones.count {
                p = bones[Int(p)].parentIndex
                steps += 1
            }
            if p >= 0 {
                bones[i].parentIndex = -1
                broken += 1
            }
        }
        return broken
    }
}
