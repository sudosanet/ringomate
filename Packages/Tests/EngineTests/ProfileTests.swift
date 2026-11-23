@testable import Engine
import Foundation
import Testing

@Test func builtinProfilesParse() {
    #expect(Profile.builtin.map(\.name) == ["mihoyo", "nte", "default"])
    #expect(Profile.builtin[0].ramp.replacesToon)
    // 別名は土台（default）にあり、どの系統にも効く
    let d = Profile.builtin[2]
    #expect(d.aliases.bone("頭") == ["頭", "头"])
    #expect(d.aliases.morph("まばたき") == ["まばたき", "眨眼", "闭眼"])
    #expect(d.aliases.bone("腰") == ["腰"])
    let n = Profile.builtin[1]
    #expect(n.isFace("面") && n.isFace("頭脸"))
    #expect(!n.isFace("眼白") && !n.isFace("前髪"))
}

@Test func userProfilesReplaceBuiltinsAndReportBrokenFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "ringomate-profiles-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = Bundle.module.url(forResource: "nte", withExtension: "toml") ?? URL(filePath: #filePath)
        .deletingLastPathComponent().appending(path: "../../Sources/Engine/Profiles/nte.toml")
    var nte = try String(contentsOf: src, encoding: .utf8)
    nte = nte.replacingOccurrences(of: "match_comment = [", with: "match_comment = [\"テストの作者\", ")
    try nte.write(to: dir.appending(path: "nte.toml"), atomically: true, encoding: .utf8)
    try "name = ".write(to: dir.appending(path: "broken.toml"), atomically: true, encoding: .utf8)
    let (all, errors) = Profile.all(dir)
    #expect(all.filter { $0.name == "nte" }.count == 1)
    #expect(all[0].matchComment.contains("テストの作者"))
    #expect(errors.count == 1 && errors[0].hasPrefix("broken.toml"))
}


@Test func aliasBonesAreRenamedToStandardNames() throws {
    var pmx = try PMXModel(pmx: Assets.pmxBytes())
    let head = try #require(pmx.bones.firstIndex { $0.name == "頭" })
    pmx.bones[head].name = "头"
    let renamed = Retarget.canonicalize(&pmx, Profile.builtin[2].aliases)
    #expect(renamed == ["头→頭"])
    #expect(pmx.bones[head].name == "頭")
    // 標準の名前が既にあれば触らない
    #expect(Retarget.canonicalize(&pmx, Profile.builtin[2].aliases).isEmpty)
}

@Test func modelRulesLayerOnTheChosenFamily() throws {
    let doc = try TOML.parse("name = \"x\"\nmatch_name = [\"m\"]\n[physics]\nleg_collider_scale = 1.0\nhair_colliders = [\"后领\"]\nhair_collider_scale = 2\n")
    var p = Profile.builtin[0]
    try p.apply(doc, from: "model rule x")
    #expect(p.name == "mihoyo")
    #expect(p.physics.legColliderScale == 1.0)
    #expect(p.ramp.replacesToon)
    #expect(p.origins["leg"] == "model rule x")
    #expect(p.physics.hairColliders == ["后领"] && p.physics.hairColliderScale == 2)
    #expect(Resolve.builtinModels.contains { $0.name == "lacrimosa" })
}

@Test func disabledRulesAreSkippedButTheBaseStays() {
    let r = Resolve.rules(nil, off: ["mihoyo", "columbina", "default"])
    #expect(!r.families.contains { $0.name == "mihoyo" })
    #expect(r.families.contains { $0.name == "default" })
    #expect(!r.models.contains { $0.name == "columbina" })
    #expect(Resolve.catalog().rules.contains { $0.name == "mihoyo" && $0.family && !$0.user })
}
