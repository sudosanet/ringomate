import simd

/// glTF の座標・メートル、BVH は cm。
struct SourceSkeleton: Sendable {
    public var names: [String]
    var parents: [Int?]
    var bind: [(SIMD3<Float>, simd_quatf)]
}

struct SourceClip: Sendable {
    public var name: String
    public var duration: Float
    var groundSpeed: Float?
    var translations: [Track<SIMD3<Float>>?]
    var rotations: [Track<simd_quatf>?]

    struct Track<T: Sendable>: Sendable {
        var times: [Float]
        var values: [T]

        func sample(_ t: Float, _ lerp: (T, T, Float) -> T) -> T {
            let i = times.partitionPoint { $0 <= t }
            if i == 0 { return values[0] }
            if i >= times.count { return values.last ?? values[0] }
            let (t0, t1) = (times[i - 1], times[i])
            return lerp(values[i - 1], values[i], t1 > t0 ? (t - t0) / (t1 - t0) : 0)
        }
    }

    public init(name: String, fps: Float, frames: [[(SIMD3<Float>, simd_quatf)]]) {
        let joints = frames.first?.count ?? 0
        let times = (0..<frames.count).map { Float($0) / fps }
        self.name = name
        duration = Float(max(frames.count, 1) - 1) / fps
        groundSpeed = nil
        translations = (0..<joints).map { j in Track(times: times, values: frames.map { $0[j].0 }) }
        rotations = (0..<joints).map { j in Track(times: times, values: frames.map { $0[j].1 }) }
    }

    init(name: String, duration: Float, translations: [Track<SIMD3<Float>>?], rotations: [Track<simd_quatf>?]) {
        (self.name, self.duration, groundSpeed, self.translations, self.rotations) = (name, duration, nil, translations, rotations)
    }

    public func sample(_ skeleton: SourceSkeleton, _ t: Float) -> [(SIMD3<Float>, simd_quatf)] {
        skeleton.names.indices.map { j in
            let (bt, br) = skeleton.bind[j]
            return (translations[j]?.sample(t, Math.lerp) ?? bt, rotations[j]?.sample(t, Math.slerp) ?? br)
        }
    }

    static func loadGLB(_ bytes: [UInt8]) throws -> (SourceSkeleton, [SourceClip]) {
        let glb = try GLB(bytes)
        let json = glb.json
        guard let skin = json["skins"][0].isObject ? json["skins"][0] : nil else { throw GLB.Invalid(description: "no skin") }
        let joints = (skin["joints"].array ?? []).compactMap(\.uint)
        let indexOf = Dictionary(joints.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var parents = [Int?](repeating: nil, count: joints.count)
        for (ni, n) in (json["nodes"].array ?? []).enumerated() {
            guard let p = indexOf[ni] else { continue }
            for c in (n["children"].array ?? []).compactMap(\.uint) { if let ci = indexOf[c] { parents[ci] = p } }
        }
        let nodes = json["nodes"].array ?? []
        let skeleton = SourceSkeleton(
            names: joints.map { nodes[$0]["name"].string ?? "" }, parents: parents,
            bind: joints.map { decomposed(nodes[$0]) })
        let clips: [SourceClip] = (json["animations"].array ?? []).map { a in
            var tr = [Track<SIMD3<Float>>?](repeating: nil, count: joints.count)
            var rot = [Track<simd_quatf>?](repeating: nil, count: joints.count)
            var duration: Float = 0
            let samplers = a["samplers"].array ?? []
            for ch in a["channels"].array ?? [] {
                guard let node = ch["target"]["node"].uint, let j = indexOf[node], let si = ch["sampler"].uint,
                      si < samplers.count, let input = samplers[si]["input"].uint, let output = samplers[si]["output"].uint,
                      let times = glb.floats(input, components: 1)?.map({ $0[0] }) else { continue }
                duration = max(duration, times.last ?? 0)
                switch ch["target"]["path"].string {
                case "translation":
                    if let v = glb.floats(output, components: 3), v.count == times.count { tr[j] = Track(times: times, values: v.map { SIMD3($0[0], $0[1], $0[2]) }) }
                case "rotation":
                    if let v = glb.floats(output, components: 4, normalize: true), v.count == times.count {
                        rot[j] = Track(times: times, values: v.map { simd_quatf(ix: $0[0], iy: $0[1], iz: $0[2], r: $0[3]) })
                    }
                default: break
                }
            }
            return SourceClip(name: a["name"].string ?? "", duration: duration, translations: tr, rotations: rot)
        }
        return (skeleton, clips)
    }

    /// 拡大縮小は捨てる。
    static func decomposed(_ n: JSONValue) -> (SIMD3<Float>, simd_quatf) {
        if let m = GLB.nodeMatrix(n) {
            let (c0, c1, c2) = (m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz)
            let r = simd_float3x3(c0 / simd_length(c0), c1 / simd_length(c1), c2 / simd_length(c2))
            return (m.columns.3.xyz, simd_quatf(r))
        }
        let (t, r, _) = GLB.nodeTRS(n)
        return (t, r)
    }
}

