import simd

/// 座標は PMX のまま（左手系・Y 上・MMD 単位）。
public struct ModelData: Sendable {
    public struct Material: Sendable {
        public var name: String
        /// インデックス単位。
        public var indexStart: Int, indexCount: Int
        public var diffuse: SIMD4<Float>, specular: SIMD3<Float>, specularPower: Float, ambient: SIMD3<Float>
        public var doubleSided: Bool
        public var hiddenRemoval: Bool, face: Bool, bangs: Bool, seeThrough: Bool
        public var edge: Bool, edgeColor: SIMD4<Float>, edgeSize: Float
        public var diffuseTexture: Int?, sphereTexture: Int?
        /// 0: なし、1: 乗算、2: 加算、3: サブテクスチャ
        public var sphereMode: UInt8
        public var toonTexture: Int?
        /// 16 個、MToon でなければ空。
        public var mtoon: [Float]
        /// 目・眉・まつ毛。
        public var faceFeature = false
        public var skinCandidate = false
    }

    public struct Texture: Sendable {
        public var name: String
        public var key: String?
    }

    /// xyz 連続。
    public var positions: [Float], normals: [Float]
    public var smoothNormals: [Float], edgeScale: [Float]
    public var uvs: [Float]
    /// 頂点ごとに 4 つ。
    public var skinIndices: [UInt32], skinWeights: [Float]
    public var gestures: [String]
    public var boneNames: [String]
    /// SDEF（頂点ごとに 12 個: C の xyz・有効なら 1、RW0 の xyz・0、RW1 の xyz・0）。SDEF の頂点がなければ空。
    public var sdef: [Float]
    public var indices: [UInt32]
    public var materials: [Material]
    public var textures: [Texture]
    public var boneCount: Int
    /// 頂点ごとの部位（1: 頭、2: 胴、3: 手、4: 足）。
    public var parts: [UInt8]
    public var height: Float
    public var rampDay: SIMD3<Float>, rampNight: SIMD3<Float>, rampSoftness: Float
    public var seeThroughAlpha: Float
    public var modelKey: String
    public var poses: [[simd_float4x4]]
    public var walkSpeed: Float, calmWalkSpeed: Float, carryWalkSpeed: Float
    public var seatHeight: Float
    public var diagnostics: [String]

    static let standardBones = ["センター", "上半身", "上半身2", "首", "頭", "両目", "左肩", "左腕", "左ひじ", "左手首", "右肩", "右腕",
                                "右ひじ", "右手首", "下半身", "左足", "左ひざ", "左足首", "右足", "右ひざ", "右足首", "左足ＩＫ", "右足ＩＫ"]

    static func sdefData(_ s: PMXModel.SDEF, _ n: Int) -> [Float] {
        guard s.enabled.contains(where: { $0 > 0 }) else { return [] }
        func v3(_ v: [Float], _ i: Int) -> [Float] { i * 3 + 3 <= v.count ? Array(v[i * 3..<i * 3 + 3]) : [0, 0, 0] }
        var out: [Float] = []
        out.reserveCapacity(n * 12)
        for i in 0..<n {
            let on = (i < s.enabled.count ? s.enabled[i] : 0) > 0 && s.rw1.count >= i * 3 + 3
            out += v3(s.c, i) + [on ? 1 : 0] + v3(s.rw0, i) + [0] + v3(s.rw1, i) + [0]
        }
        return out
    }

    /// 形から前髪を見つけたときの、前髪越しの目・眉の濃さ。
    static let seeThroughAlpha: Float = 0.6

    init(_ c: Puppet) {
        let pmx = c.model.pmx, g = pmx.geometry, profile = c.model.profile
        let see = profile.seeThrough
        var start = 0
        materials = zip(pmx.materials, c.model.materialTextures).enumerated().map { i, mt in
            let (m, t) = mt
            let count = Int(max(m.faceCount, 0)) * 3
            defer { start += count }
            return Material(
                name: m.name, indexStart: start, indexCount: count, diffuse: m.diffuse, specular: m.specular,
                specularPower: m.specularPower, ambient: m.ambient, doubleSided: m.flags.doubleSided,
                hiddenRemoval: profile.hiddenRemoval.contains { Profile.contains(m.name, $0) }, face: c.model.faceMaterials.contains(i),
                bangs: see.map { $0.bangs.contains(m.name) } ?? c.model.bangsMaterials.contains(i),
                seeThrough: see.map { $0.materials.contains(m.name) } ?? c.model.seeThroughMaterials.contains(i),
                edge: m.flags.edge, edgeColor: m.edgeColor, edgeSize: m.edgeSize, diffuseTexture: t.diffuse, sphereTexture: t.sphere,
                sphereMode: ["multiply": 1, "add": 2, "subTexture": 3][m.sphereMode] ?? 0, toonTexture: profile.ramp.replacesToon ? nil : t.toon, mtoon: i < c.model.mtoon.count ? c.model.mtoon[i] : [],
                faceFeature: c.model.featureMaterials.contains(i), skinCandidate: c.model.skinCandidates.contains(i))
        }
        let missing = Self.standardBones.filter { Retarget.bone(pmx, profile.aliases, [$0]) == nil }
        diagnostics = c.model.diagnostics + c.diagnostics
            + [missing.isEmpty ? "skeleton: all standard bones found" : "skeleton: not found \(missing.joined(separator: ", "))"]
        positions = g.positions
        normals = g.normals
        smoothNormals = Optimize.enabled("smooth_normals") ? Optimize.smoothNormals(positions: g.positions, normals: g.normals) : g.normals
        edgeScale = g.edgeScale
        uvs = g.uvs
        skinIndices = g.skinIndices
        skinWeights = g.skinWeights
        boneNames = pmx.bones.map(\.name)
        gestures = c.gestureNames
        sdef = Self.sdefData(g.sdef, g.positions.count / 3)
        indices = g.indices
        textures = c.model.textures.map { Texture(name: $0.reference, key: $0.key) }
        boneCount = c.boneCount
        parts = c.vertexParts
        height = max(Puppet.height(pmx), 1)
        (rampDay, rampNight, rampSoftness) = (profile.ramp.day, profile.ramp.night, profile.ramp.softness)
        seeThroughAlpha = see?.alpha ?? (c.model.bangsMaterials.isEmpty ? 0 : Self.seeThroughAlpha)
        modelKey = c.model.key
        poses = []
        walkSpeed = c.walkSpeed
        let calm = c.walkSpeed(of: .walkCalm)
        calmWalkSpeed = calm == 0 ? c.walkSpeed : calm
        carryWalkSpeed = c.walkSpeed(of: .walkCarry)
        seatHeight = c.seatHeight ?? 0
    }
}
