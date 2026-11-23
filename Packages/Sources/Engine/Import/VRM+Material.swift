import Foundation
import simd

extension VRM {
    static func renderQueue(_ vrm: JSONValue, _ json: JSONValue, _ mat: Int?, _ v: Version) -> Int {
        guard let i = mat else { return 0 }
        return (v == .v0 ? vrm["materialProperties"][i]["renderQueue"]
            : json["materials"][i]["extensions"]["VRMC_materials_mtoon"]["renderQueueOffsetNumber"]).int ?? 0
    }

    /// 影色 rgb・シフト、リム rgb・指数、トゥーニー・リムの持ち上げ・UV スクロール x・y、自発光 rgb・UV の回転。
    static func mtoonParams(_ vrm: JSONValue, _ json: JSONValue, _ mat: Int?, _ v: Version) -> [Float] {
        guard let i = mat else { return [] }
        func col(_ c: JSONValue, _ d: [Float]) -> [Float] { c.isArray ? [c[0].f, c[1].f, c[2].f] : d }
        func num(_ x: JSONValue, _ d: Float) -> Float { x.double.map(Float.init) ?? d }
        if v == .v0 {
            let p = vrm["materialProperties"][i]
            guard p["shader"].string == "VRM/MToon" else { return [] }
            let fl = p["floatProperties"], ve = p["vectorProperties"]
            return col(ve["_ShadeColor"], [0.97, 0.81, 0.86]) + [num(fl["_ShadeShift"], 0)] + col(ve["_RimColor"], [0, 0, 0])
                + [num(fl["_RimFresnelPower"], 1), num(fl["_ShadeToony"], 0.9), num(fl["_RimLift"], 0),
                   num(fl["_UvAnimScrollX"], 0), num(fl["_UvAnimScrollY"], 0)]
                + col(ve["_EmissionColor"], [0, 0, 0]) + [num(fl["_UvAnimRotation"], 0) * (2 * .pi)]
        }
        let m = json["materials"][i], e = m["extensions"]["VRMC_materials_mtoon"]
        guard e.isObject else { return [] }
        return col(e["shadeColorFactor"], [0, 0, 0]) + [num(e["shadingShiftFactor"], 0)]
            + col(e["parametricRimColorFactor"], [0, 0, 0])
            + [num(e["parametricRimFresnelPowerFactor"], 5), num(e["shadingToonyFactor"], 0.9),
               num(e["parametricRimLiftFactor"], 0), num(e["uvAnimationScrollXSpeedFactor"], 0),
               num(e["uvAnimationScrollYSpeedFactor"], 0)]
            + col(m["emissiveFactor"], [0, 0, 0]) + [num(e["uvAnimationRotationSpeedFactor"], 0)]
    }

    static func shadeTexture(_ vrm: JSONValue, _ json: JSONValue, _ mat: Int?, _ v: Version) -> Int? {
        guard let i = mat else { return nil }
        return (v == .v0 ? vrm["materialProperties"][i]["textureProperties"]["_ShadeTexture"]
            : json["materials"][i]["extensions"]["VRMC_materials_mtoon"]["shadeMultiplyTexture"]["index"]).uint
    }

    static func emissionTexture(_ vrm: JSONValue, _ json: JSONValue, _ mat: Int?, _ v: Version) -> Int? {
        guard let i = mat else { return nil }
        return (v == .v0 ? vrm["materialProperties"][i]["textureProperties"]["_EmissionMap"]
            : json["materials"][i]["emissiveTexture"]["index"]).uint
    }

    static func outline(_ vrm: JSONValue, _ json: JSONValue, _ mat: Int?, _ v: Version) -> (Bool, SIMD4<Float>) {
        guard let i = mat else { return (false, SIMD4(0, 0, 0, 1)) }
        let on: Bool, c: JSONValue
        if v == .v0 {
            let p = vrm["materialProperties"][i]
            on = p["floatProperties"]["_OutlineWidthMode"].f != 0 && p["floatProperties"]["_OutlineWidth"].f > 0
            c = p["vectorProperties"]["_OutlineColor"]
        } else {
            let m = json["materials"][i]["extensions"]["VRMC_materials_mtoon"]
            on = (m["outlineWidthMode"].string.map { $0 != "none" } ?? false) && m["outlineWidthFactor"].f > 0
            c = m["outlineColorFactor"]
        }
        return (on, SIMD4(c[0].f, c[1].f, c[2].f, 1))
    }
}
