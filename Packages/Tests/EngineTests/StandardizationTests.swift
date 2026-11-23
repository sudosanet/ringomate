@testable import Engine
import Foundation
import simd
import Testing

/// 意図して変えたら `MASCOT_UPDATE_BASELINES=1`。
private let standardBones = ["センター", "下半身", "上半身", "上半身2", "首", "頭", "左目", "右目", "左肩", "左腕", "左ひじ", "左手首",
                             "右腕", "右手首", "左足", "左ひざ", "右足首", "左足ＩＫ"]

private func report(_ url: URL) throws -> String {
    let model = try LoadedModel.load(url)
    let c = Puppet(model)
    let clips = try Assets.ual(["Idle_Loop", "Walk_Loop", "Sitting_Idle_Loop"], for: model)
    for (slot, name) in [(Slot.idle, "Idle_Loop"), (.walk, "Walk_Loop"), (.sit, "Sitting_Idle_Loop")] {
        if let clip = clips[name] { c.setBaked(slot, clip) }
    }
    let pmx = c.model.pmx
    var out = ""
    for name in standardBones {
        out += "bone \(name) = \(Procedural.bone(pmx, model.profile.aliases, name).map { pmx.bones[$0].name } ?? "-")\n"
    }
    for e in 0..<Expression.count {
        var one = [Float](repeating: 0, count: Expression.count)
        one[e] = 1
        let names = c.procedural.morphWeights(one).filter { $0.1 > 0 }.map { pmx.morphs[$0.0].name }
            .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        out += "expression \(e) = \(names.joined(separator: ", "))\n"
    }
    for (k, pose) in c.samplePoses(4).enumerated() {
        let sum = pose.reduce(0.0) { s, m in (0..<4).reduce(s) { s, col in s + (0..<4).reduce(0.0) { $0 + Double(abs(m[col][$1])) } } }
        out += "pose \(k) = \(String(format: "%.2f", sum))\n"
    }
    return out
}

private func close(_ a: Substring, _ b: Substring) -> Bool {
    func num(_ s: Substring) -> Double? { s.hasPrefix("pose ") ? s.components(separatedBy: " = ").last.flatMap(Double.init) : nil }
    guard let x = num(a), let y = num(b) else { return false }
    return abs(x - y) <= abs(x) * 1e-3
}

@Test func bundledModelsKeepTheirMappingAndPoses() throws {
    let update = ProcessInfo.processInfo.environment["MASCOT_UPDATE_BASELINES"] != nil
    let dir = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Baselines")
    for url in [Assets.model, Assets.library] {
        let got = try report(url)
        let baseline = dir.appending(path: url.deletingPathExtension().lastPathComponent + ".txt")
        guard !update, let want = try? String(contentsOf: baseline, encoding: .utf8) else {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try got.write(to: baseline, atomically: true, encoding: .utf8)
            continue
        }
        let (w, g) = (want.split(separator: "\n"), got.split(separator: "\n"))
        let diff = zip(w, g).filter { $0 != $1 && !close($0, $1) }.map { "  - \($0)\n  + \($1)" }
        #expect(diff.isEmpty && w.count == g.count, "\(url.lastPathComponent):\n\(diff.joined(separator: "\n"))")
    }
}
