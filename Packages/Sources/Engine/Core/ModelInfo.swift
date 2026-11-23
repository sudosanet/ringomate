import Foundation

public struct ModelInfo: Sendable {
    public var title: String, titleEn: String
    public var comment: String
    public var format: String
    public var terms: [(name: String, text: String)]
    public var vertices: Int, materials: Int, bones: Int, morphs: Int, rigidBodies: Int, joints: Int, textures: Int
    public var profile: String
    public var decisions: [Decision]

    public init(_ url: URL) throws {
        let m = try LoadedModel.load(url)
        let meta = m.pmx.metadata
        func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        (title, titleEn, comment, format) = (trim(meta.name), trim(meta.englishName), trim(meta.comment), m.format)
        terms = m.terms.map { ($0.0, trim($0.1)) }
        let c = meta.counts
        (vertices, materials, bones, morphs, rigidBodies, joints) = (c.vertices, c.materials, c.bones, c.morphs, c.rigidBodies, c.joints)
        textures = m.textures.count
        profile = m.profile.name
        decisions = m.decisions
    }
}

extension Scene {
    public func textureBytes(_ i: Int) -> [UInt8]? { character?.model.textureBytes(i) }
}
