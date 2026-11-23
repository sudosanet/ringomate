import Foundation
import simd

extension VRM {
    static func expressionName(_ preset: String) -> String? {
        switch preset {
        case "blink": "まばたき"
        case "blinkLeft", "blink_l": "ウィンク"
        case "blinkRight", "blink_r": "ウィンク右"
        case "aa", "a": "あ"
        case "ih", "i": "い"
        case "ou", "u": "う"
        case "ee", "e": "え"
        case "oh", "o": "お"
        case "happy", "joy": "笑い"
        case "angry": "怒り"
        case "sad", "sorrow": "困る"
        case "relaxed", "fun": "なごみ"
        case "surprised": "びっくり"
        default: nil
        }
    }

    static func expressions(_ vrm: JSONValue, _ json: JSONValue, _ v: Version, _ prims: [Prim]) -> [PMXModel.Morph] {
        var list: [(String, [(Int, Int, Float)])] = []
        if v == .v1 {
            for kind in ["preset", "custom"] {
                for (name, e) in vrm["expressions"][kind].entries {
                    list.append((name, (e["morphTargetBinds"].array ?? []).map {
                        ($0["node"].uint ?? 0, $0["index"].uint ?? 0, $0["weight"].f)
                    }))
                }
            }
        } else {
            for g in vrm["blendShapeMaster"]["blendShapeGroups"].array ?? [] {
                let preset = g["presetName"].string ?? "unknown"
                let name = preset == "unknown" || preset.isEmpty ? g["name"].string ?? "" : preset
                list.append((name, (g["binds"].array ?? []).map {
                    ($0["mesh"].uint ?? 0, $0["index"].uint ?? 0, $0["weight"].f / 100)
                }))
            }
        }
        for (name, target, weight) in [("真面目", "Fcl_BRW_Angry", Float(0.5)), ("喜ぶ", "Fcl_BRW_Fun", 1), ("下", "Fcl_BRW_Sorrow", 0.7)]
        where !list.contains(where: { $0.0 == name }) {
            var binds: [(Int, Int, Float)] = []
            for (mi, mesh) in (json["meshes"].array ?? []).enumerated() {
                let names = mesh["extras"]["targetNames"].array ?? mesh["primitives"][0]["extras"]["targetNames"].array
                guard let k = names?.firstIndex(where: { $0.string?.hasSuffix(target) ?? false }) else { continue }
                if v == .v0 {
                    binds.append((mi, k, weight))
                } else {
                    for (ni, node) in (json["nodes"].array ?? []).enumerated() where node["mesh"].uint == mi {
                        binds.append((ni, k, weight))
                    }
                }
            }
            if !binds.isEmpty { list.append((name, binds)) }
        }
        return list.compactMap { name, binds in
            var acc: [UInt32: SIMD3<Float>] = [:]
            for (owner, target, w) in binds {
                for p in prims where (v == .v1 ? p.node : p.mesh) == owner {
                    guard target < p.targets.count else { continue }
                    for (k, d) in p.targets[target].enumerated() { acc[p.base + UInt32(k), default: .zero] += d * w }
                }
            }
            let offsets = acc.filter { simd_length_squared($0.value) > 1e-10 }
                .map { PMXModel.VertexOffset(vertexIndex: $0.key, position: $0.value) }
                .sorted { $0.vertexIndex < $1.vertexIndex }
            guard !offsets.isEmpty else { return nil }
            var m = PMXModel.Morph()
            m.name = expressionName(name) ?? name
            m.englishName = name
            m.vertexOffsets = offsets
            return m
        }
    }
}
