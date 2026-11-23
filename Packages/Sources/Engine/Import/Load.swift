import Foundation

public struct LoadedModel {
    public var pmx: PMXModel
    public var textures: [Texture]
    var materialTextures: [MaterialTextures]
    public var mtoon: [[Float]]
    public var profile: Profile
    public var key: String
    public var diagnostics: [String]
    public var format: String
    public var terms: [(String, String)]
    /// 顔の材質。名前で見つからなければ形から選ぶ（`FaceDetect`）。
    var faceMaterials: Set<Int> = []
    /// 目・眉・まつ毛。
    var featureMaterials: Set<Int> = []
    var bangsMaterials: Set<Int> = []
    var seeThroughMaterials: Set<Int> = []
    /// 名前で肌が見つからないときの候補（`SkinDetect`）。
    var skinCandidates: Set<Int> = []
    public var decisions: [Decision] = []
    let archive: Archive

    public struct Texture: Sendable {
        public var reference: String
        var entry: Int?
        public var key: String?
    }

    struct MaterialTextures: Sendable {
        public var diffuse: Int?, sphere: Int?, toon: Int?
    }

    mutating func addTexture(reference: String, data: [UInt8]) -> Int {
        let key = "prop-" + cacheKey([data])
        let entry = archive.pushMemory(name: reference, key: key, data: data)
        textures.append(Texture(reference: reference, entry: entry, key: key))
        return textures.count - 1
    }

    public func textureBytes(_ i: Int) -> [UInt8]? {
        guard i >= 0, i < textures.count, let e = textures[i].entry, let bytes = try? archive.read(e) else { return nil }
        return DDS.isDDS(bytes) ? DDS.png(bytes) : bytes
    }

    struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func load(_ url: URL) throws -> LoadedModel {
        let ext = url.pathExtension.lowercased()
        let archive: Archive
        let main: Int
        if ["pmx", "pmd", "gltf"].contains(ext) {
            archive = try Archive.open(url.deletingLastPathComponent()) { _ in [] }
            guard let i = archive.index(of: url.lastPathComponent) else { throw Failure(description: "PMX not found") }
            main = i
        } else if ["vrm", "glb", "fbx"].contains(ext) {
            archive = try Archive.file(url)
            main = 0
        } else {
            archive = try Archive.open(url) { bytes in
                guard let m = try? PMXModel(pmx: bytes) else { return [] }
                return m.materials.flatMap { [$0.texturePath, $0.sphereTexturePath, $0.toonTexturePath] }.filter { !$0.isEmpty }
            }
            guard let i = archive.mainPMX ?? archive.mainPMD ?? archive.mainVRM else {
                throw Failure(description: "PMX not found")
            }
            main = i
        }
        let singlePMX = ext == "pmx" || ext == "pmd"
        let pmxPath = archive.entries[main].name
        var mainBytes = try archive.read(main)
        var vrmDiagnostics: [String] = []
        var lower = pmxPath.lowercased()
        let dir = pmxPath.lastIndex(of: "/").map { String(pmxPath[..<$0]) } ?? ""
        if lower.hasSuffix(".fbx") {
            mainBytes = try FBX.glb(mainBytes) { name in
                let name = name.replacingOccurrences(of: "\\", with: "/")
                let file = name.split(separator: "/").last.map(String.init) ?? name
                return [name, "\(dir)/\(name)", file, "\(dir)/\(file)"].lazy
                    .compactMap { archive.index(of: $0) }.first.flatMap { try? archive.read($0) }
            }
        }
        if lower.hasSuffix(".gltf") {
            mainBytes = try GLTFExpand.pack(mainBytes) { name in
                archive.index(of: dir.isEmpty ? name : "\(dir)/\(name)").flatMap { try? archive.read($0) }
            }
        }
        if lower.hasSuffix(".fbx") || lower.hasSuffix(".gltf") { lower += ".glb" }
        if lower.hasSuffix(".glb") || lower.hasSuffix(".vrm"), let plain = try GLTFExpand.expand(mainBytes) {
            vrmDiagnostics.append("glTF: Draco / KTX2 expanded")
            mainBytes = plain
        }
        var mtoon: [[Float]] = []
        var format = lower.hasSuffix(".pmd") ? "PMD" : "PMX"
        var vrmTerms = ""
        let pmxBytes: [UInt8]
        if lower.hasSuffix(".pmd") {
            pmxBytes = try PMD.convert(mainBytes).pmxBytes()
        } else if lower.hasSuffix(".vrm") || lower.hasSuffix(".glb") {
            let c = try VRM.convert(mainBytes)
            let key = archive.entries[main].key
            for (reference, data) in c.images {
                archive.pushMemory(name: dir.isEmpty ? reference : "\(dir)/\(reference)", key: "\(key)-\(reference)", data: data)
            }
            vrmDiagnostics = c.diagnostics
            mtoon = c.mtoon
            format = pmxPath.lowercased().hasSuffix(".fbx") ? "FBX" : c.format
            vrmTerms = c.terms
            pmxBytes = c.pmx.pmxBytes()
        } else {
            pmxBytes = mainBytes
        }
        var pmx = try PMXModel(pmx: pmxBytes)

        let c = pmx.metadata.counts
        var diagnostics = [
            "model: \(pmx.metadata.name) (\(pmxPath))",
            "file names: \(archive.nameEncoding)",
            "counts: \(c.vertices) vertices, \(c.materials) materials, \(c.bones) bones, \(c.morphs) morphs, "
                + "\(c.rigidBodies) rigid bodies, \(c.joints) joints",
        ]
        diagnostics += vrmDiagnostics
        diagnostics += pmx.diagnostics.map { "pmx \($0.code): \($0.message)" }
        let others = archive.entries.filter { $0.name.lowercased().hasSuffix(".pmx") && $0.name != pmxPath }.map(\.name)
        if !others.isEmpty, !singlePMX { diagnostics.append("other PMX not loaded: \(others.joined(separator: ", "))") }

        let resolver = TextureResolver(archive, pmxPath: pmxPath)
        var textures: [Texture] = []
        func index(_ reference: String) -> Int? {
            if reference.isEmpty { return nil }
            if let i = textures.firstIndex(where: { $0.reference == reference }) { return i }
            let entry = resolver.resolve(reference).flatMap { archive.index(of: $0) }
            if let e = entry {
                if archive.entries[e].name.lowercased() != reference.replacingOccurrences(of: "\\", with: "/").lowercased() {
                    diagnostics.append("texture \(reference) -> \(archive.entries[e].name)")
                }
            } else {
                diagnostics.append("missing texture: \(reference)")
            }
            textures.append(Texture(reference: reference, entry: entry, key: entry.map { archive.entries[$0].key }))
            return textures.count - 1
        }
        let materialTextures = pmx.materials.map {
            MaterialTextures(diffuse: index($0.texturePath), sphere: index($0.sphereTexturePath), toon: index($0.toonTexturePath))
        }

        let readmes: [(String, String)] = archive.entries.enumerated()
            .filter { $0.element.name.lowercased().hasSuffix(".txt") && $0.element.size < 64 * 1024 }
            .compactMap { i, e in
                guard let b = try? archive.read(i) else { return nil }
                if let s = String(validating: b, as: UTF8.self) {
                    return (e.name, s.hasPrefix("\u{feff}") ? String(s.drop { $0 == "\u{feff}" }) : s)
                }
                let (gbk, bad) = decode(b, .gbk)
                return (e.name, bad ? decode(b, .shiftJIS).text : gbk)
            }
        let readme = readmes.map(\.1).joined(separator: "\n")
        var terms: [(String, String)] = []
        if !vrmTerms.isEmpty { terms.append((String(localized: "VRM terms of use", bundle: #bundle), vrmTerms)) }
        terms += readmes
        let (profile, why) = Resolve.profile(pmx, readme: readme)
        diagnostics.append("profile: \(profile.name) (\(why))")
        if Optimize.enabled("bone_aliases") {
            let renamed = Retarget.canonicalize(&pmx, profile.aliases)
            if !renamed.isEmpty { diagnostics.append("bones renamed to standard names: \(renamed.joined(separator: ", "))") }
        }
        var face = Set(pmx.materials.indices.filter { profile.isFace(pmx.materials[$0].name) })
        if face.isEmpty, Optimize.analyzer("analyze_face"), let found = FaceDetect.material(pmx) {
            face = [found]
            diagnostics.append("analysis: face = \(pmx.materials[found].name) (geometry)")
        }
        var loaded = LoadedModel(pmx: pmx, textures: textures, materialTextures: materialTextures, mtoon: mtoon, profile: profile,
                                 key: archive.entries[main].key, diagnostics: diagnostics, format: format, terms: terms,
                                 archive: archive)
        loaded.faceMaterials = face
        func names(_ s: Set<Int>) -> String { s.sorted().map { pmx.materials[$0].name }.joined(separator: ", ") }
        if Optimize.analyzer("face_features") {
            loaded.featureMaterials = FaceDetect.features(pmx, face: face)
            if !loaded.featureMaterials.isEmpty { loaded.diagnostics.append("analysis: face features = \(names(loaded.featureMaterials))") }
        }
        if Optimize.enabled("analyzer"), Optimize.optIn("skin_detect"), !pmx.materials.contains(where: { m in profile.hiddenRemoval.contains { Profile.contains(m.name, $0) } }) {
            loaded.skinCandidates = SkinDetect.candidates(loaded)
            if !loaded.skinCandidates.isEmpty { loaded.diagnostics.append("analysis: skin candidates = \(names(loaded.skinCandidates))") }
        }
        if Optimize.analyzer("see_through") {
            loaded.bangsMaterials = FaceDetect.bangs(pmx, face: face, features: loaded.featureMaterials)
            if !loaded.bangsMaterials.isEmpty {
                loaded.seeThroughMaterials = FaceDetect.seeThrough(pmx, face: face, features: loaded.featureMaterials)
                loaded.diagnostics.append("analysis: bangs = \(names(loaded.bangsMaterials)), seen through = \(names(loaded.seeThroughMaterials))")
            }
        }
        loaded.decisions = Resolve.decisions(loaded, why: why)
        return loaded
    }
}
