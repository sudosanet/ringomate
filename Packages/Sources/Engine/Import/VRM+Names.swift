import Foundation
import simd

extension VRM {
    static func mmdName(_ bone: String, _ v: Version) -> String? {
        var side = "", rest = Substring(bone)
        if rest.hasPrefix("left") {
            side = "左"
            rest = rest.dropFirst(4)
        } else if rest.hasPrefix("right") {
            side = "右"
            rest = rest.dropFirst(5)
        }
        let body: [Substring: String] = [
            "hips": "下半身", "spine": "上半身", "chest": "上半身2", "upperChest": "上半身3", "neck": "首", "head": "頭",
            "jaw": "あご", "Eye": "目", "Shoulder": "肩", "UpperArm": "腕", "LowerArm": "ひじ", "Hand": "手首",
            "UpperLeg": "足", "LowerLeg": "ひざ", "Foot": "足首", "Toes": "つま先",
        ]
        if let b = body[rest] { return side + b }
        let fingers = [("Thumb", "親指"), ("Index", "人指"), ("Middle", "中指"), ("Ring", "薬指"), ("Little", "小指")]
        guard let (f, jp) = fingers.first(where: { rest.hasPrefix($0.0) }) else { return nil }
        let joint = rest.dropFirst(f.count)
        let thumb = f == "Thumb"
        let n: String
        switch (joint, thumb) {
        case ("Metacarpal", true): n = "０"
        case ("Proximal", true): n = v == .v1 ? "１" : "０"
        case ("Intermediate", true): n = "１"
        case ("Distal", true): n = "２"
        case ("Proximal", false): n = "１"
        case ("Intermediate", false): n = "２"
        case ("Distal", false): n = "３"
        default: return nil
        }
        return "\(side)\(jp)\(n)"
    }

    static func bone(_ name: String, _ parent: Int32, _ p: SIMD3<Float>, translatable: Bool) -> PMXParts.Bone {
        var b = PMXParts.Bone()
        b.name = name
        b.parentIndex = parent
        b.position = p
        b.translatable = translatable
        return b
    }

    static func local(_ n: JSONValue) -> simd_float4x4 {
        if let m = GLB.nodeMatrix(n) { return m }
        let (t, r, s) = GLB.nodeTRS(n)
        return Math.translation(t) * simd_float4x4(r) * simd_float4x4(diagonal: SIMD4(s, 1))
    }

    /// キーのバイト順。
    static func metaTerms(_ meta: JSONValue) -> String {
        guard meta.isObject else { return "" }
        func value(_ v: JSONValue) -> String {
            switch v {
            case let .string(s): s
            case let .bool(b): b ? String(localized: "Allowed", bundle: #bundle) : String(localized: "Not allowed", bundle: #bundle)
            case let .array(a): a.map { $0.string ?? $0.jsonText }.joined(separator: ", ")
            default: v.jsonText
            }
        }
        return meta.entries.filter { k, v in !["name", "title", "thumbnailImage", "texture"].contains(k) && !value(v).isEmpty }
            .map { k, v in "\(labels.first { $0.0 == k }?.1 ?? k): \(value(v))" }
            .joined(separator: "\n")
    }
}
