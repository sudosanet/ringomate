import Foundation

/// 規則（TOML）を重ねた結果（`Resolve`）。
public struct Profile: Sendable {
    public var name: String
    var matchComment: [String] = []
    var matchText: [String] = []
    var matchTexture: [String] = []
    /// PMX のモデル名（名指しの規則）。
    var matchName: [String] = []
    public var aliases = Aliases()
    var faceMaterials: [String] = []
    var faceContains: [String] = []
    public var hiddenRemoval: [String] = []
    public var ramp = Ramp(day: [0.86, 0.80, 0.84], night: [0.74, 0.76, 0.90], softness: 0.06, replacesToon: false)
    public var physics = PhysicsTuning()
    public var seeThrough: SeeThrough?
    /// 項目ごとに、最後に書いた規則の表示名。
    var origins: [String: String] = [:]

    public struct Ramp: Sendable {
        public var day: SIMD3<Float>, night: SIMD3<Float>
        public var softness: Float
        var replacesToon: Bool
    }

    public struct PhysicsTuning: Sendable {
        var legColliderScale: Float = 1
        var loosen: [String] = []
        var loosenDegrees: Float = 0
        /// 名前の先頭がこれに一致する剛体の完全固定の鎖は、揺れる親の延長として付いていかせる（`Optimize.attachLockedTails`）。
        public var attach: [String] = []
        /// 名前の先頭がこれに一致する剛体のジョイントの回転の範囲を `widenFactor` 倍に広げる。
        var widen: [String] = []
        var widenFactor: Float = 2
        /// 名前の先頭がこれに一致する剛体を、髪の鎖の当たり相手としてだけ `hairColliderScale` 倍に太らせる（見た目の服が剛体より外にあるとき）。
        var hairColliders: [String] = []
        var hairColliderScale: Float = 1
    }

    public struct SeeThrough: Sendable {
        public var bangs: [String], materials: [String], alpha: Float
    }

    public struct Aliases: Sendable {
        public var bones: [String: [String]] = [:]
        public var morphs: [String: [String]] = [:]

        public func bone(_ name: String) -> [String] { [name] + (bones[name] ?? []) }
        func morph(_ name: String) -> [String] { [name] + (morphs[name] ?? []) }

        /// 辞書の順に依らない。
        var digest: String {
            [bones, morphs].map { d in d.keys.sorted().map { "\($0)=\(d[$0]!.joined(separator: ","))" }.joined(separator: ";") }
                .joined(separator: "|")
        }
    }

    func isFace(_ material: String) -> Bool {
        faceMaterials.contains(material) || faceContains.contains { Self.contains(material, $0) }
    }

    struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    public init(name: String) { self.name = name }

    /// 書いてあるキーだけ置き換える。
    public mutating func apply(_ doc: [String: TOML], from: String) throws {
        func strings(_ v: TOML?) throws -> [String] {
            guard let v else { return [] }
            guard let a = v.array, a.allSatisfy({ $0.string != nil }) else { throw Invalid(description: "not an array of strings") }
            return a.compactMap(\.string)
        }
        func float(_ v: TOML?, _ what: String) throws -> Float {
            guard let d = v?.double else { throw Invalid(description: "\(what) is missing") }
            return Float(d)
        }
        func vec3(_ v: TOML?, _ what: String) throws -> SIMD3<Float> {
            guard let a = v?.array, a.count == 3 else { throw Invalid(description: "\(what) must be 3 numbers") }
            return SIMD3(try float(a[0], what), try float(a[1], what), try float(a[2], what))
        }
        func table(_ v: TOML?) throws -> [String: [String]] {
            guard let t = v?.table else { return [:] }
            return try t.mapValues { try strings($0) }
        }
        func set<T>(_ key: String, _ item: String, _ path: WritableKeyPath<Profile, T>, _ read: (TOML) throws -> T) throws {
            guard let v = doc[key] else { return }
            self[keyPath: path] = try read(v)
            origins[item] = from
        }
        try set("match_comment", "family", \.matchComment, strings)
        try set("match_text", "family", \.matchText, strings)
        try set("match_texture", "family", \.matchTexture, strings)
        try set("match_name", "match", \.matchName, strings)
        try set("face_materials", "face", \.faceMaterials, strings)
        try set("face_contains", "face", \.faceContains, strings)
        try set("hidden_removal", "skin", \.hiddenRemoval, strings)
        if let a = doc["aliases"] {
            aliases = Aliases(bones: try table(a["bones"]), morphs: try table(a["morphs"]))
            origins["aliases"] = from
        }
        if let r = doc["ramp"] {
            if r["day"] != nil { ramp.day = try vec3(r["day"], "ramp.day") }
            if r["night"] != nil { ramp.night = try vec3(r["night"], "ramp.night") }
            if r["softness"] != nil { ramp.softness = try float(r["softness"], "ramp.softness") }
            if r["day"] != nil || r["night"] != nil || r["softness"] != nil { origins["ramp"] = from }
            if let t = r["replaces_toon"] {
                guard let b = t.bool else { throw Invalid(description: "ramp.replaces_toon must be true or false") }
                ramp.replacesToon = b
                origins["toon"] = from
            }
        }
        if let p = doc["physics"] {
            if let v = p["leg_collider_scale"] {
                physics.legColliderScale = try float(v, "leg_collider_scale")
                origins["leg"] = from
            }
            if let v = p["loosen"] { physics.loosen = try strings(v); origins["loosen"] = from }
            if let v = p["loosen_degrees"] { physics.loosenDegrees = try float(v, "loosen_degrees"); origins["loosen"] = from }
            if let v = p["attach"] { physics.attach = try strings(v); origins["attach_widen"] = from }
            if let v = p["widen"] { physics.widen = try strings(v); origins["attach_widen"] = from }
            if let v = p["widen_factor"] { physics.widenFactor = try float(v, "widen_factor"); origins["attach_widen"] = from }
            if let v = p["hair_colliders"] { physics.hairColliders = try strings(v); origins["attach_widen"] = from }
            if let v = p["hair_collider_scale"] { physics.hairColliderScale = try float(v, "hair_collider_scale"); origins["attach_widen"] = from }
        }
        if let s = doc["see_through"] {
            seeThrough = SeeThrough(bangs: try strings(s["bangs"]), materials: try strings(s["materials"]),
                                    alpha: try float(s["alpha"], "see_through.alpha"))
            origins["see_through"] = from
        }
    }

    /// Swift の `contains` は書記素で比べるのでバイト列で比べる。
    static func contains(_ s: String, _ k: String) -> Bool {
        k.isEmpty || s.utf8.firstRange(of: k.utf8) != nil
    }
}
