import Engine
import Foundation
import Render

extension MeshInput {
    static var hiddenRemovalEnabled: Bool { !Flags.disabled("hidden_removal") }

    /// `MASCOT_DISABLE` に `+名前` でオン
    static func on(_ step: String) -> Bool { Flags.disabled("+" + step) }

    public init(_ m: ModelData, core: Core) {
        let (rim, ramp, mtoon) = (Self.on("class_rim"), Self.on("class_ramp"), Self.on("mtoon_fix"))
        self.init(
            positions: m.positions, normals: m.normals, smoothNormals: m.smoothNormals, edgeScale: m.edgeScale, uvs: m.uvs,
            skinIndices: m.skinIndices, skinWeights: m.skinWeights, indices: m.indices,
            materials: m.materials.map { mat in
                var input = MaterialInput(
                    indexStart: mat.indexStart, indexCount: mat.indexCount,
                    diffuse: mat.diffuse, ambient: mat.ambient, specular: mat.specular,
                    specularPower: mat.specularPower, doubleSided: mat.doubleSided,
                    hiddenRemoval: mat.hiddenRemoval && Self.hiddenRemovalEnabled, face: mat.face, bangs: mat.bangs, seeThrough: mat.seeThrough,
                    edge: mat.edge, edgeColor: mat.edgeColor, edgeSize: mat.edgeSize,
                    diffuseTexture: mat.diffuseTexture, sphereTexture: mat.sphereTexture,
                    sphereMode: MaterialInput.SphereMode(rawValue: Int32(mat.sphereMode)) ?? .none,
                    toonTexture: mat.toonTexture
                )
                input.mtoon = mat.mtoon.count == 16 ? mat.mtoon : []
                input.faceFeature = mat.faceFeature
                input.skinCandidate = mat.skinCandidate && Self.hiddenRemovalEnabled
                input.noRim = rim && (mat.face || mat.faceFeature)
                input.warmShade = ramp && (mat.face || mat.hiddenRemoval || mat.skinCandidate)
                input.liftShade = mtoon && mat.mtoon.count == 16
                return input
            },
            textures: m.textures.enumerated().map { i, t in
                t.key.map { key in TextureSource(key: key) { [unowned core] in core.textureBytes(i) } }
            },
            boneCount: m.boneCount,
            parts: m.parts,
            ramp: Ramp(day: m.rampDay, night: m.rampNight, softness: m.rampSoftness),
            seeThroughAlpha: m.seeThroughAlpha,
            modelKey: m.modelKey,
            poses: m.poses.map { pose in pose.flatMap { m in (0..<4).flatMap { c in (0..<4).map { m[c][$0] } } } }
        )
        sdef = m.sdef
    }
}
