import CoreGraphics
import Foundation
import ImageIO
import simd

/// 顔の色に近い材質（肌の候補）。消すのは描画で見えない三角形だけ（`HiddenSurface`）。
/// ponytail: 色の近さだけで、名前の肌の約半分しか当たらず靴下・飾りも拾う。既定オフ、精度が上がったら既定オンへ。
enum SkinDetect {
    static func candidates(_ model: LoadedModel) -> Set<Int> {
        let pmx = model.pmx
        var cache: [Int: (Int, Int, [UInt8])?] = [:]
        guard let face = model.faceMaterials.min(), let skin = meanColor(model, face, &cache),
              let stats = FaceDetect.stats(pmx)?.stats else { return [] }
        let skip = model.faceMaterials.union(model.featureMaterials)
        return Set(pmx.materials.indices.filter { i in
            // 頭に付くもの（口の中・髪）は動くと見えるので外す
            guard !skip.contains(i), let s = stats[i], s.head < 0.3, pmx.materials[i].diffuse.w > 0.98, pmx.materials[i].faceCount >= 30,
                  let c = meanColor(model, i, &cache) else { return false }
            return simd_distance(c, skin) < Optimize.knob("skin_color", 0.12)
        })
    }

    /// 材質の頂点の UV でテクスチャを引いた色の平均（0〜1、材質の色を掛けたもの）。
    static func meanColor(_ model: LoadedModel, _ material: Int, _ cache: inout [Int: (Int, Int, [UInt8])?]) -> SIMD3<Float>? {
        let pmx = model.pmx, g = pmx.geometry
        guard material < model.materialTextures.count, let t = model.materialTextures[material].diffuse else { return nil }
        if cache[t] == nil { cache[t] = model.textureBytes(t).flatMap(small) }
        guard let (w, h, pixels) = cache[t] ?? nil else { return nil }
        var start = 0
        for m in pmx.materials.prefix(material) { start += Int(m.faceCount) * 3 }
        let n = Int(pmx.materials[material].faceCount) * 3
        var sum = SIMD3<Float>.zero, k: Float = 0
        for v in Set(g.indices[start..<start + n].map(Int.init)) where v * 2 + 1 < g.uvs.count {
            let u = g.uvs[v * 2] - floor(g.uvs[v * 2]), vv = g.uvs[v * 2 + 1] - floor(g.uvs[v * 2 + 1])
            let o = (min(Int(vv * Float(h)), h - 1) * w + min(Int(u * Float(w)), w - 1)) * 4
            guard pixels[o + 3] > 128 else { continue }
            sum += SIMD3(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2])) / 255
            k += 1
        }
        guard k > 0 else { return nil }
        let d = pmx.materials[material].diffuse
        return sum / k * SIMD3(d.x, d.y, d.z)
    }

    static func small(_ bytes: [UInt8]) -> (Int, Int, [UInt8])? {
        ImageSample.rgba(bytes, width: 64, height: 64).map { (64, 64, $0) }
    }
}
