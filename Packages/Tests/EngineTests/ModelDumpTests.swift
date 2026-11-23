import CryptoKit
@testable import Engine
import Foundation
import simd
import Testing

/// 読み込みの判定（材質のフラグ・物理の補正後の PMX・骨・診断）を JSON に書く。`DUMP_MODEL` のときだけ動く。
/// `DUMP_OUT` は書き出し先のフォルダ。
@Test func modelDump() throws {
    let env = ProcessInfo.processInfo.environment
    guard let path = env["DUMP_MODEL"] else { return }
    let scene = Scene()
    let data = try scene.load(model: URL(filePath: path), library: Assets.library)
    scene.commitLoad()
    let c = try #require(scene.character)
    let pmx = c.model.pmx
    let hash = SHA256.hash(data: Data(pmx.pmxBytes())).map { String(format: "%02x", $0) }.joined()
    let materials = data.materials.map { m -> String in
        let flags = [("face", m.face), ("hidden", m.hiddenRemoval), ("bangs", m.bangs), ("see", m.seeThrough),
                     ("feature", m.faceFeature), ("skin", m.skinCandidate), ("toon", m.toonTexture != nil)]
        return m.name + ": " + flags.filter(\.1).map(\.0).joined(separator: ",")
    }
    let bones = ModelData.standardBones.map { n in "\(n)=\(Retarget.bone(pmx, c.model.profile.aliases, [n]).map(String.init) ?? "-")" }
    let skip = ["load timing", "motions:"]
    let out: [String: Any] = [
        "profile": c.model.profile.name,
        "pmxHash": hash,
        "materials": materials,
        "ramp": [data.rampDay.x, data.rampDay.y, data.rampDay.z, data.rampNight.x, data.rampNight.y, data.rampNight.z,
                 data.rampSoftness].map { Double($0) },
        "decisions": c.model.decisions.map { "\($0.item) = \($0.value) [\($0.source)] \($0.reason)" },
        "seeThroughAlpha": Double(data.seeThroughAlpha),
        "bones": bones,
        "diagnostics": data.diagnostics.filter { d in !skip.contains { d.hasPrefix($0) } },
    ]
    let dir = URL(filePath: env["DUMP_OUT"] ?? FileManager.default.temporaryDirectory.path)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let json = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: dir.appending(path: URL(filePath: path).lastPathComponent + ".json"))
}

