@testable import Engine
import Foundation
import Testing

@Test func faceFeaturesAreSmallPartsOfTheUpperFace() throws {
    let l = try LoadedModel.load(Assets.model)
    #expect(!l.faceMaterials.isEmpty)
    let features = FaceDetect.features(l.pmx, face: l.faceMaterials)
    #expect(!features.isEmpty)
    #expect(features.isDisjoint(with: l.faceMaterials))
    let see = FaceDetect.seeThrough(l.pmx, face: l.faceMaterials, features: features)
    #expect(see.isSubset(of: features))
    #expect(FaceDetect.bangs(l.pmx, face: l.faceMaterials, features: features).isDisjoint(with: features))
}

/// 材質名・大きさ・左右に依らない。
@Test func faceDetectionIgnoresNamesScaleAndMirroring() throws {
    let l = try LoadedModel.load(Assets.model)
    func result(_ p: PMXModel) -> [Set<Int>] {
        guard let face = FaceDetect.material(p) else { return [] }
        let features = FaceDetect.features(p, face: [face])
        return [[face], features, FaceDetect.bangs(p, face: [face], features: features), FaceDetect.seeThrough(p, face: [face], features: features)]
    }
    let base = result(l.pmx)
    #expect(!base.isEmpty)
    var renamed = l.pmx
    for i in renamed.materials.indices { renamed.materials[i].name = "m\(i * 7919 % 1000)" }
    #expect(result(renamed) == base)
    for k: Float in [0.08, 12.5] {
        var scaled = l.pmx
        scaled.geometry.positions = scaled.geometry.positions.map { $0 * k }
        for i in scaled.bones.indices { scaled.bones[i].position *= k }
        for i in scaled.morphs.indices { for j in scaled.morphs[i].vertexOffsets.indices { scaled.morphs[i].vertexOffsets[j].position *= k } }
        #expect(result(scaled) == base, "scale \(k)")
    }
    var mirrored = l.pmx
    for v in 0..<(mirrored.geometry.positions.count / 3) {
        mirrored.geometry.positions[v * 3] = -mirrored.geometry.positions[v * 3]
        mirrored.geometry.normals[v * 3] = -mirrored.geometry.normals[v * 3]
    }
    for i in mirrored.bones.indices { mirrored.bones[i].position.x = -mirrored.bones[i].position.x }
    #expect(result(mirrored) == base)
}
