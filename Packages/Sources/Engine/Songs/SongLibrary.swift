import Foundation

public final class SongLibrary: Sendable {
    public let packs: [SongPack]
    let versions: [(Int, Int)]
    let index: SongIndex
    public let errors: [(URL, String)]

    public convenience init(roots: [URL], cache: URL) {
        var byID: [String: SongPack] = [:]
        var errors: [(URL, String)] = []
        let fm = FileManager.default
        for root in roots {
            guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { continue }
            let dirs = names.map { root.appending(path: $0) }
                .filter { fm.fileExists(atPath: $0.appending(path: "song.toml").path) }
                .sorted { $0.path < $1.path }
            for dir in dirs {
                do {
                    let p = try SongPack.load(dir, cache: cache)
                    byID[p.toml.id] = p
                } catch {
                    errors.append((dir, "\(error)"))
                }
            }
        }
        self.init(packs: byID.values.sorted { $0.toml.id < $1.toml.id }, errors: errors)
    }

    public init(packs: [SongPack], errors: [(URL, String)] = []) {
        var index = SongIndex()
        var versions: [(Int, Int)] = []
        for (p, pack) in packs.enumerated() {
            for (v, va) in pack.analysis.versions.enumerated() {
                index.add(UInt32(versions.count), va.fingerprint)
                versions.append((p, v))
            }
        }
        index.finish()
        (self.packs, self.versions, self.index, self.errors) = (packs, versions, index, errors)
    }

    func lookup(_ query: [UInt32]) -> (pack: Int, version: Int, hit: SongIndex.Hit, other: UInt32)? {
        let hits = index.lookup(query, minVotes: 8)
        guard let top = hits.first, versions.indices.contains(Int(top.version)) else { return nil }
        let (p, v) = versions[Int(top.version)]
        let other = hits.filter { versions.indices.contains(Int($0.version)) && versions[Int($0.version)].0 != p }
            .map(\.votes).max() ?? 0
        return (p, v, top, other)
    }

    public var indexCount: Int { index.count }
}
