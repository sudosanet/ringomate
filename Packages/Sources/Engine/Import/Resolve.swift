import Foundation

public struct Decision: Sendable {
    public var item: String
    public var value: String
    public var source: String
    public var reason: String
}

public struct RuleInfo: Sendable {
    public var name: String
    /// 表示用（「系統」か「モデル規則」）。
    public var kind: String
    public var user: Bool
    public var family: Bool
}

/// 名指しの規則（`match_name`。組み込み → ユーザー）＞ 解析 ＞ それ以外（土台に系統 1 つ、または手動選択）。
/// ユーザーの同名ファイルは組み込みを置き換える。
public enum Resolve {
    struct RuleFile {
        var name: String
        var label: String
        var doc: [String: TOML]
        var matchName: [String]
    }

    static func load(_ url: URL) throws -> [String: TOML] { try TOML.parse(String(contentsOf: url, encoding: .utf8)) }

    static let builtinModels: [RuleFile] = (Bundle.module.urls(forResourcesWithExtension: "toml", subdirectory: "Profiles/models") ?? [])
        .sorted { $0.path < $1.path }
        .map { url in
            let doc = try! load(url)
            let name = doc["name"]?.string ?? url.deletingPathExtension().lastPathComponent
            return RuleFile(name: name, label: "model rule \(name)", doc: doc, matchName: doc["match_name"]?.array?.compactMap(\.string) ?? [])
        }

    static let builtinFamilies: [RuleFile] = ["mihoyo", "nte", "default"].map { name in
        let url = Bundle.module.url(forResource: name, withExtension: "toml", subdirectory: "Profiles")!
        return RuleFile(name: name, label: name, doc: try! load(url), matchName: [])
    }

    /// `MASCOT_DISABLE` の `rule:名前`
    static var disabledRules: Set<String> {
        Set((Flags.value("MASCOT_DISABLE") ?? "").split(separator: ",")
            .compactMap { $0.hasPrefix("rule:") ? String($0.dropFirst(5)) : nil })
    }

    static func rules(_ dir: URL?, off: Set<String> = disabledRules) -> (families: [RuleFile], models: [RuleFile], errors: [String]) {
        var families = builtinFamilies
        var models = builtinModels
        var errors: [String] = []
        let files = (dir.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            ?? []).filter { $0.pathExtension == "toml" }.sorted { $0.path < $1.path }
        for url in files {
            do {
                let doc = try load(url)
                let label = "user \(url.lastPathComponent)"
                if let names = doc["match_name"]?.array?.compactMap(\.string), !names.isEmpty {
                    guard let name = doc["name"]?.string else { throw Profile.Invalid(description: "name is missing") }
                    var probe = Profile(name: name)
                    try probe.apply(doc, from: label)
                    models.removeAll { $0.name == name }
                    models.append(RuleFile(name: name, label: "user model rule \(url.lastPathComponent)", doc: doc, matchName: names))
                } else {
                    guard let name = doc["name"]?.string else { throw Profile.Invalid(description: "name is missing") }
                    var probe = Profile(name: name)
                    try probe.apply(doc, from: label)
                    families.removeAll { $0.name == name }
                    families.insert(RuleFile(name: name, label: label, doc: doc, matchName: []), at: 0)
                }
            } catch {
                errors.append("\(url.lastPathComponent): \(String(describing: error).split(separator: "\n").first ?? "")")
            }
        }
        // 土台は切れない
        return (families.filter { $0.name == "default" || !off.contains($0.name) }, models.filter { !off.contains($0.name) }, errors)
    }

    /// 切った規則も含める。
    public static func catalog() -> (rules: [RuleInfo], errors: [String]) {
        let r = rules(Profile.userDirectory, off: [])
        return (r.families.map { RuleInfo(name: $0.name, kind: String(localized: "Family", bundle: #bundle), user: $0.label.hasPrefix("user "), family: true) }
            + r.models.map { RuleInfo(name: $0.name, kind: String(localized: "Model rule", bundle: #bundle), user: $0.label.hasPrefix("user "), family: false) },
                r.errors)
    }

    /// 解析は `Load` が間に入れる。
    static func profile(_ pmx: PMXModel, readme: String) -> (Profile, String) {
        let (families, models, errors) = rules(Profile.userDirectory)
        let parsed = families.compactMap { f -> Profile? in var p = Profile(name: f.name); return (try? p.apply(f.doc, from: f.label)).map { p } }
        let (chosen, why0) = choose(parsed, pmx, readme)
        var why = why0
        var profile = Profile(name: "default")
        if let base = families.first(where: { $0.name == "default" }) { try? profile.apply(base.doc, from: base.label) }
        if chosen.name != "default", let f = families.first(where: { $0.name == chosen.name }) {
            try? profile.apply(f.doc, from: why == "manual" ? "manual \(f.name)" : f.label)
            profile.name = f.name
        }
        for m in models where m.matchName.contains(pmx.metadata.name) {
            try? profile.apply(m.doc, from: m.label)
            why += "; model rule \(m.name)"
        }
        return errors.isEmpty ? (profile, why) : (profile, "\(why); user profiles not read: \(errors.joined(separator: "; "))")
    }

    /// 同点は後のもの。
    static func choose(_ all: [Profile], _ pmx: PMXModel, _ readme: String) -> (Profile, String) {
        if let name = Flags.value("MASCOT_PROFILE"), let p = all.first(where: { $0.name == name }) {
            return (p, "manual")
        }
        let comment = "\(pmx.metadata.comment)\n\(pmx.metadata.englishComment)"
        let textures = pmx.materials.map(\.texturePath)
        let scored = all.map { p -> (Profile, Int, [String]) in
            var points = 0
            var why: [String] = []
            for k in p.matchComment where Profile.contains(comment, k) {
                points += 3
                why.append("comment \"\(k)\"")
            }
            for k in p.matchText where Profile.contains(readme, k) {
                points += 1
                why.append("readme \"\(k)\"")
            }
            for k in p.matchTexture where textures.contains(where: { Profile.contains($0, k) }) {
                points += 2
                why.append("texture \"\(k)\"")
            }
            return (p, points, why)
        }
        if let best = scored.filter({ $0.1 > 0 }).lastMax({ $0.1 }) {
            return (best.0, "score \(best.1): \(best.2.joined(separator: ", "))")
        }
        return (all.first { $0.name == "default" }!, "no title matched")
    }

    static func named(_ p: Profile, _ item: String) -> Bool { p.origins[item]?.contains("model rule") ?? false }

    /// 規則の出どころ（`model rule 名前` など、判定にも使う英語の固定の名前）を、表示の言語で。
    static func originLabel(_ origin: String) -> String {
        for (prefix, make) in [("user model rule ", { (n: String) in String(localized: "User model rule \(n)", bundle: #bundle) }),
                               ("model rule ", { String(localized: "Model rule \($0)", bundle: #bundle) }),
                               ("user ", { String(localized: "User \($0)", bundle: #bundle) }),
                               ("manual ", { String(localized: "Manual \($0)", bundle: #bundle) })] where origin.hasPrefix(prefix) {
            return make(String(origin.dropFirst(prefix.count)))
        }
        return String(localized: "Rule \(origin)", bundle: #bundle)
    }

    static func decisions(_ m: LoadedModel, why: String) -> [Decision] {
        let p = m.profile, pmx = m.pmx
        let none = String(localized: "None", bundle: #bundle), byDefault = String(localized: "Default", bundle: #bundle)
        let analysis = String(localized: "Analysis", bundle: #bundle), materialNames = String(localized: "Material names", bundle: #bundle)
        func src(_ item: String) -> String { p.origins[item].map { $0 == "default" ? byDefault : Self.originLabel($0) } ?? byDefault }
        func names(_ s: Set<Int>) -> String { s.sorted().map { pmx.materials[$0].name }.joined(separator: ", ") }
        let named = Set(pmx.materials.indices.filter { i in p.hiddenRemoval.contains { Profile.contains(pmx.materials[i].name, $0) } })
        let byName = !m.faceMaterials.isEmpty && m.faceMaterials.allSatisfy { p.isFace(pmx.materials[$0].name) }
        var out = [Decision(item: String(localized: "Family", bundle: #bundle), value: p.name, source: src("family"), reason: why)]
        out.append(Decision(item: String(localized: "Face", bundle: #bundle), value: names(m.faceMaterials),
                            source: m.faceMaterials.isEmpty ? none : byName ? src("face") : analysis,
                            reason: byName ? materialNames : String(localized: "Forward-facing materials on the head", bundle: #bundle)))
        if let s = p.seeThrough {
            out.append(Decision(item: String(localized: "Through bangs", bundle: #bundle), value: (s.bangs + s.materials).joined(separator: ", "),
                                source: src("see_through"), reason: materialNames))
        } else {
            out.append(Decision(item: String(localized: "Through bangs", bundle: #bundle), value: names(m.seeThroughMaterials),
                                source: m.bangsMaterials.isEmpty ? none : analysis,
                                reason: m.bangsMaterials.isEmpty ? "" : String(localized: "Bangs \(names(m.bangsMaterials))", bundle: #bundle)))
        }
        if !named.isEmpty {
            out.append(Decision(item: String(localized: "Skin", bundle: #bundle), value: names(named), source: src("skin"), reason: materialNames))
        } else {
            out.append(Decision(item: String(localized: "Skin", bundle: #bundle),
                                value: m.skinCandidates.isEmpty ? "" : String(localized: "\(m.skinCandidates.count) candidate materials", bundle: #bundle),
                                source: m.skinCandidates.isEmpty ? none : analysis,
                                reason: names(m.skinCandidates)))
        }
        out.append(Decision(item: "toon", value: p.ramp.replacesToon ? String(localized: "App shading on all materials", bundle: #bundle) : String(localized: "Author's toon", bundle: #bundle), source: src("toon"), reason: ""))
        out.append(Decision(item: String(localized: "Shadow color", bundle: #bundle), value: "\(p.ramp.day) / \(p.ramp.night)", source: src("ramp"), reason: ""))
        out.append(Decision(item: String(localized: "Leg colliders", bundle: #bundle), value: "×\(p.physics.legColliderScale)", source: src("leg"), reason: ""))
        let loosen = p.physics.loosen.isEmpty ? none
            : String(localized: "\(p.physics.loosen.joined(separator: ", ")) by ±\(Int(p.physics.loosenDegrees))°", bundle: #bundle)
        out.append(Decision(item: String(localized: "Loosened locks", bundle: #bundle), value: loosen, source: p.physics.loosen.isEmpty ? byDefault : src("loosen"), reason: ""))
        let aw = (p.physics.attach.map { "attach \($0)" } + p.physics.widen.map { "widen \($0)" }
            + p.physics.hairColliders.map { "hair hits \($0) ×\(p.physics.hairColliderScale)" }).joined(separator: ", ")
        out.append(Decision(item: String(localized: "Chain settings", bundle: #bundle), value: aw.isEmpty ? none : aw, source: aw.isEmpty ? byDefault : src("attach_widen"), reason: ""))
        out.append(Decision(item: String(localized: "Name aliases", bundle: #bundle),
                                value: String(localized: "\(p.aliases.bones.count) bones, \(p.aliases.morphs.count) morphs", bundle: #bundle), source: src("aliases"), reason: ""))
        return out
    }
}

extension Profile {
    /// 土台に重ねる前。
    static let builtin: [Profile] = Resolve.builtinFamilies.map { f in
        var p = Profile(name: f.name)
        try! p.apply(f.doc, from: f.label)
        return p
    }

    static var userDirectory: URL? {
        if let d = Flags.value("MASCOT_PROFILE_DIR") { return URL(filePath: d) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "ringomate/profiles")
    }

    static func all(_ dir: URL?) -> ([Profile], [String]) {
        let r = Resolve.rules(dir)
        return (r.families.compactMap { f in var p = Profile(name: f.name); return (try? p.apply(f.doc, from: f.label)).map { p } }, r.errors)
    }
}
