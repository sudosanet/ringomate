import Foundation

public struct TextureSource {
    public var key: String
    public var load: () -> Data?

    public init(key: String, load: @escaping () -> Data?) {
        self.key = key
        self.load = load
    }
}

public struct MeshInput {
    public var positions: [Float]
    public var normals: [Float]
    public var smoothNormals: [Float]
    public var edgeScale: [Float]
    public var sdef: [Float] = []
    public var uvs: [Float]
    public var skinIndices: [UInt32]
    public var skinWeights: [Float]
    public var indices: [UInt32]
    public var materials: [MaterialInput]
    public var textures: [TextureSource?]
    public var boneCount: Int
    public var parts: [UInt8]
    public var ramp: Ramp
    public var seeThroughAlpha: Float
    public var modelKey: String?
    public var poses: [[Float]]

    public init(positions: [Float], normals: [Float], smoothNormals: [Float] = [], edgeScale: [Float] = [],
                uvs: [Float], skinIndices: [UInt32],
                skinWeights: [Float], indices: [UInt32], materials: [MaterialInput],
                textures: [TextureSource?], boneCount: Int, parts: [UInt8], ramp: Ramp = Ramp(),
                seeThroughAlpha: Float = 0, modelKey: String? = nil, poses: [[Float]] = []) {
        self.positions = positions
        self.normals = normals
        self.smoothNormals = smoothNormals
        self.edgeScale = edgeScale
        self.uvs = uvs
        self.skinIndices = skinIndices
        self.skinWeights = skinWeights
        self.indices = indices
        self.materials = materials
        self.textures = textures
        self.boneCount = boneCount
        self.parts = parts
        self.ramp = ramp
        self.seeThroughAlpha = seeThroughAlpha
        self.modelKey = modelKey
        self.poses = poses
    }

    public var vertexCount: Int { positions.count / 3 }
}

public struct Ramp: Sendable {
    public var day: SIMD3<Float>
    public var night: SIMD3<Float>
    public var softness: Float

    public init(day: SIMD3<Float> = [0.86, 0.80, 0.84], night: SIMD3<Float> = [0.74, 0.76, 0.90], softness: Float = 0.06) {
        self.day = day
        self.night = night
        self.softness = softness
    }
}

public struct MaterialInput: Sendable {
    public enum SphereMode: Int32, Sendable { case none = 0, multiply = 1, add = 2, subTexture = 3 }

    public var indexStart: Int
    public var indexCount: Int
    public var diffuse: SIMD4<Float>
    public var ambient: SIMD3<Float>
    public var specular: SIMD3<Float>
    public var specularPower: Float
    public var doubleSided: Bool
    public var hiddenRemoval: Bool
    public var face: Bool
    public var bangs: Bool
    public var seeThrough: Bool
    public var edge: Bool
    public var edgeColor: SIMD4<Float>
    public var edgeSize: Float
    public var diffuseTexture: Int?
    public var sphereTexture: Int?
    public var sphereMode: SphereMode
    public var toonTexture: Int?
    public var mtoon: [Float] = []
    /// 目・眉・まつ毛。
    public var faceFeature = false
    /// 見えない三角形を隠れた素体として消す。
    public var skinCandidate = false
    public var noRim = false, warmShade = false, liftShade = false

    public init(indexStart: Int, indexCount: Int, diffuse: SIMD4<Float>, ambient: SIMD3<Float>,
                specular: SIMD3<Float>, specularPower: Float, doubleSided: Bool,
                hiddenRemoval: Bool = false, face: Bool = false, bangs: Bool = false, seeThrough: Bool = false, edge: Bool = false, edgeColor: SIMD4<Float> = [0, 0, 0, 1], edgeSize: Float = 0,
                diffuseTexture: Int?, sphereTexture: Int?, sphereMode: SphereMode, toonTexture: Int?) {
        self.indexStart = indexStart
        self.indexCount = indexCount
        self.diffuse = diffuse
        self.ambient = ambient
        self.specular = specular
        self.specularPower = specularPower
        self.doubleSided = doubleSided
        self.hiddenRemoval = hiddenRemoval
        self.face = face
        self.bangs = bangs
        self.seeThrough = seeThrough
        self.edge = edge
        self.edgeColor = edgeColor
        self.edgeSize = edgeSize
        self.diffuseTexture = diffuseTexture
        self.sphereTexture = sphereTexture
        self.sphereMode = sphereMode
        self.toonTexture = toonTexture
    }
}

public struct Placement: Sendable {
    public var anchor: SIMD2<Float>
    public var pointsPerUnit: Float

    public init(anchor: SIMD2<Float>, pointsPerUnit: Float) {
        self.anchor = anchor
        self.pointsPerUnit = pointsPerUnit
    }
}
