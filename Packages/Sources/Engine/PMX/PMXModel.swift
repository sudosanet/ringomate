/// ponytail: 種類（`kind`・`mode` など）は文字列のまま。いずれ enum にする。
public struct PMXModel: Sendable {
    var metadata = Metadata()
    var geometry = Geometry()
    public var materials: [Material] = []
    public var bones: [Bone] = []
    public var morphs: [Morph] = []
    var displayFrames: [DisplayFrame] = []
    public var rigidBodies: [RigidBody] = []
    public var joints: [Joint] = []
    var softBodies: [SoftBody] = []
    public var diagnostics: [Diagnostic] = []

    public init() {}

    struct Metadata: Sendable {
        public var format = "pmx"
        public var version: Float = 2.0
        /// "utf-8" か "utf-16-le"。
        public var encoding = "utf-16-le"
        public var name = ""
        var englishName = ""
        public var comment = ""
        var englishComment = ""
        public var counts = Counts()
        var indexSizes = IndexSizes()
        var additionalUVCount: UInt8 = 0
    }

    struct Counts: Sendable {
        public var vertices = 0, faces = 0, materials = 0, bones = 0, morphs = 0
        var displayFrames = 0, rigidBodies = 0, joints = 0, softBodies = 0
    }

    struct IndexSizes: Sendable {
        public var vertex: UInt8 = 4, texture: UInt8 = 4, material: UInt8 = 4
        public var bone: UInt8 = 4, morph: UInt8 = 4, rigidBody: UInt8 = 4
    }

    struct Geometry: Sendable {
        /// xyz 連続。
        public var positions: [Float] = []
        public var normals: [Float] = []
        /// uv 連続。
        public var uvs: [Float] = []
        /// 追加 UV ごとに xyzw 連続。
        var additionalUVs: [[Float]] = []
        public var indices: [UInt32] = []
        /// 頂点ごとに 4 つ。
        public var skinIndices: [UInt32] = []
        public var skinWeights: [Float] = []
        public var edgeScale: [Float] = []
        var materialGroups: [MaterialGroup] = []
        public var sdef = SDEF()
        /// 頂点ごとの QDEF（1 なら QDEF）。
        var qdefEnabled: [Float] = []
    }

    public struct SDEF: Sendable {
        /// 頂点ごとの "bdef1"・"bdef2"・"bdef4"・"sdef"・"qdef"。
        var skinningModes: [String] = []
        public var enabled: [Float] = []
        public var c: [Float] = [], r0: [Float] = [], r1: [Float] = [], rw0: [Float] = [], rw1: [Float] = []
    }

    struct MaterialGroup: Sendable, Equatable {
        public var start: Int, count: Int, materialIndex: Int
    }

    public struct Material: Sendable {
        public var name = "", englishName = ""
        var texturePath = "", sphereTexturePath = ""
        /// "none"・"multiply"・"add"・"subTexture"。
        public var sphereMode = "none"
        var toonTexturePath = ""
        var sharedToonIndex: UInt8?
        public var diffuse = SIMD4<Float>(1, 1, 1, 1)
        public var specular = SIMD3<Float>(0, 0, 0)
        public var specularPower: Float = 0
        public var ambient = SIMD3<Float>(0, 0, 0)
        public var edgeColor = SIMD4<Float>(0, 0, 0, 1)
        public var edgeSize: Float = 1
        public var flags = MaterialFlags()
        var faceCount: Int32 = 0
    }

    public struct MaterialFlags: Sendable {
        public var doubleSided = false, groundShadow = false, selfShadowMap = false, selfShadow = false
        public var edge = false, vertexColor = false, pointDraw = false, lineDraw = false

        init(bits: UInt8) {
            doubleSided = bits & 0x01 != 0
            groundShadow = bits & 0x02 != 0
            selfShadowMap = bits & 0x04 != 0
            selfShadow = bits & 0x08 != 0
            edge = bits & 0x10 != 0
            vertexColor = bits & 0x20 != 0
            pointDraw = bits & 0x40 != 0
            lineDraw = bits & 0x80 != 0
        }

        public init() {}

        var bits: UInt8 {
            [doubleSided, groundShadow, selfShadowMap, selfShadow, edge, vertexColor, pointDraw, lineDraw]
                .enumerated().reduce(0) { $0 | ($1.element ? 1 << $1.offset : 0) }
        }
    }

    public struct Bone: Sendable {
        public var name = "", englishName = ""
        var parentIndex: Int32 = -1
        public var layer: Int32 = 0
        public var position = SIMD3<Float>(0, 0, 0)
        var tailIndex: Int32 = -1
        var tailPosition: SIMD3<Float>?
        public var flags = BoneFlags()
        var appendTransform: AppendTransform?
        var fixedAxis: SIMD3<Float>?
        var localAxis: LocalAxis?
        var externalParentKey: Int32?
        var ik: IK?
    }

    public struct BoneFlags: Sendable {
        var indexedTail = false, rotatable = false, translatable = false, visible = false, enabled = false
        var ik = false, appendLocal = false, appendRotate = false, appendTranslate = false
        var fixedAxis = false, localAxis = false, transformAfterPhysics = false
        var externalParentTransform = false

        public init() {}

        init(bits: UInt16) {
            indexedTail = bits & 0x0001 != 0
            rotatable = bits & 0x0002 != 0
            translatable = bits & 0x0004 != 0
            visible = bits & 0x0008 != 0
            enabled = bits & 0x0010 != 0
            ik = bits & 0x0020 != 0
            appendLocal = bits & 0x0080 != 0
            appendRotate = bits & 0x0100 != 0
            appendTranslate = bits & 0x0200 != 0
            fixedAxis = bits & 0x0400 != 0
            localAxis = bits & 0x0800 != 0
            transformAfterPhysics = bits & 0x1000 != 0
            externalParentTransform = bits & 0x2000 != 0
        }

        var bits: UInt16 {
            let pairs: [(Bool, UInt16)] = [
                (indexedTail, 0x0001), (rotatable, 0x0002), (translatable, 0x0004), (visible, 0x0008),
                (enabled, 0x0010), (ik, 0x0020), (appendLocal, 0x0080), (appendRotate, 0x0100),
                (appendTranslate, 0x0200), (fixedAxis, 0x0400), (localAxis, 0x0800),
                (transformAfterPhysics, 0x1000), (externalParentTransform, 0x2000),
            ]
            return pairs.reduce(0) { $0 | ($1.0 ? $1.1 : 0) }
        }
    }

    struct AppendTransform: Sendable {
        var parentIndex: Int32, weight: Float
    }

    struct LocalAxis: Sendable {
        public var x: SIMD3<Float>, z: SIMD3<Float>
    }

    struct IK: Sendable {
        var targetIndex: Int32
        var loopCount: Int32
        var limitAngle: Float
        var links: [IKLink]
    }

    struct IKLink: Sendable {
        var boneIndex: Int32
        public var limits: IKLimit?
    }

    struct IKLimit: Sendable {
        public var lower: SIMD3<Float>, upper: SIMD3<Float>
    }

    public struct Morph: Sendable {
        public var name = "", englishName = ""
        /// "system"・"brow"・"eye"・"mouth"・"other"・"unknown"。
        public var panel = "other"
        /// "group"・"vertex"・"bone"・"uv"・"additionalUv"・"material"・"flip"・"impulse"。
        public var kind = "vertex"
        var vertexOffsets: [VertexOffset] = []
        var groupOffsets: [GroupOffset] = []
        var boneOffsets: [BoneOffset] = []
        var uvOffsets: [UVOffset] = []
        var additionalUVOffsets: [AdditionalUVOffset] = []
        var materialOffsets: [MaterialOffset] = []
        var flipOffsets: [GroupOffset] = []
        var impulseOffsets: [ImpulseOffset] = []
    }

    struct VertexOffset: Sendable {
        var vertexIndex: UInt32, position: SIMD3<Float>
    }

    struct GroupOffset: Sendable {
        var morphIndex: Int32, weight: Float
    }

    struct BoneOffset: Sendable {
        var boneIndex: Int32, translation: SIMD3<Float>, rotation: SIMD4<Float>
    }

    struct UVOffset: Sendable {
        var vertexIndex: UInt32, uv: SIMD4<Float>
    }

    struct AdditionalUVOffset: Sendable {
        var vertexIndex: UInt32, uvIndex: UInt8, uv: SIMD4<Float>
    }

    struct MaterialOffset: Sendable {
        var materialIndex: Int32
        /// "multiply" か "add"。
        public var operation: String
        public var diffuse: SIMD4<Float>, specular: SIMD3<Float>, specularPower: Float, ambient: SIMD3<Float>
        public var edgeColor: SIMD4<Float>, edgeSize: Float
        var textureFactor: SIMD4<Float>, sphereTextureFactor: SIMD4<Float>, toonTextureFactor: SIMD4<Float>
    }

    struct ImpulseOffset: Sendable {
        var rigidBodyIndex: Int32, local: Bool, velocity: SIMD3<Float>, torque: SIMD3<Float>
    }

    struct DisplayFrame: Sendable {
        public var name = "", englishName = ""
        var special = false
        public var frames: [DisplayFrameElement] = []
    }

    struct DisplayFrameElement: Sendable {
        /// "bone" か "morph"。
        public var kind: String
        public var index: Int32
    }

    public struct RigidBody: Sendable {
        public var name = "", englishName = ""
        var boneIndex: Int32 = -1
        public var group: UInt8 = 0
        public var mask: UInt16 = 0xffff
        /// "sphere"・"box"・"capsule"・"unknown"。
        public var shape = "sphere"
        public var size = SIMD3<Float>(1, 1, 1)
        public var position = SIMD3<Float>(0, 0, 0)
        var rotation = SIMD3<Float>(0, 0, 0)
        var mass: Float = 1
        var linearDamping: Float = 0, angularDamping: Float = 0
        var restitution: Float = 0, friction: Float = 0
        /// "static"・"dynamic"・"dynamicBone"・"unknown"。
        var mode = "static"
    }

    public struct Joint: Sendable {
        public var name = "", englishName = ""
        /// "generic6dofSpring"・"generic6dof"・"point2point"・"coneTwist"・"slider"・"hinge"・"unknown"。
        public var kind = "generic6dofSpring"
        var rigidBodyIndexA: Int32 = -1, rigidBodyIndexB: Int32 = -1
        public var position = SIMD3<Float>(0, 0, 0), rotation = SIMD3<Float>(0, 0, 0)
        var translationLowerLimit = SIMD3<Float>(0, 0, 0), translationUpperLimit = SIMD3<Float>(0, 0, 0)
        var rotationLowerLimit = SIMD3<Float>(0, 0, 0), rotationUpperLimit = SIMD3<Float>(0, 0, 0)
        var springTranslationFactor = SIMD3<Float>(0, 0, 0)
        var springRotationFactor = SIMD3<Float>(0, 0, 0)
    }

    struct SoftBody: Sendable {
        public var name = "", englishName = ""
        /// "triMesh"・"rope"・"unknown"。
        public var kind = "triMesh"
        var materialIndex: Int32 = -1
        var collisionGroup: UInt8 = 0
        var collisionMask: UInt16 = 0
        public var flags: UInt8 = 0
        var bendingConstraintsDistance: Int32 = 0
        var clusterCount: Int32 = 0
        var totalMass: Float = 0, collisionMargin: Float = 0
    }

    public struct Diagnostic: Sendable {
        public var level: String, code: String, message: String
    }
}
