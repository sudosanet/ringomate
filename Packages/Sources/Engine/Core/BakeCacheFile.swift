import Foundation

enum BakeCacheFile {
    static func url(_ model: LoadedModel, library: URL) -> URL? {
        guard let home = getenv("HOME") else { return nil }
        func stamp(_ u: URL) -> String {
            guard let a = try? FileManager.default.attributesOfItem(atPath: u.path) else { return "-" }
            let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
            let t = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(size):\(Int64(t * 1e9))"
        }
        let dir = library.deletingLastPathComponent()
        let parts = [
            model.key, model.profile.aliases.digest, Flags.value("MASCOT_DISABLE") ?? "",
            stamp(library), stamp(dir.appending(path: "../ual2/UAL2_Standard.glb")), stamp(dir.appending(path: "../bandai.toml")),
            stamp(dir.appending(path: "../cmu.toml")), stamp(URL(filePath: imagePath)),
        ]
        return URL(filePath: String(cString: home)).appending(path: "Library/Caches/app.ringomate/baked-swift/\(cacheKey([Array(parts.joined(separator: "\n").utf8)])).bin")
    }

    static let imagePath: String = {
        var info = Dl_info()
        let marker: @convention(c) () -> Void = {}
        guard dladdr(unsafeBitCast(marker, to: UnsafeRawPointer.self), &info) != 0, let name = info.dli_fname else { return "" }
        return String(cString: name)
    }()

    /// 骨の番号が今のモデルに収まらないキャッシュ（壊れた・古い）は捨てる。
    static func read(_ url: URL?, boneCount: Int) -> [(Slot, BakedClip)]? {
        guard let clips = url.flatMap({ try? [UInt8](Data(contentsOf: $0)) }).flatMap(BakeCache.decode) else { return nil }
        let ok = (0..<boneCount)
        return clips.allSatisfy { _, c in
            c.frames.allSatisfy { f in
                f.rotations.allSatisfy { ok.contains($0.0) } && f.feet.allSatisfy { ok.contains($0.0) } && f.center.map { ok.contains($0.0) } ?? true
            }
        } ? clips : nil
    }

    static func write(_ url: URL?, _ clips: [(Slot, BakedClip)]) {
        guard let url else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(BakeCache.encode(clips)).write(to: url, options: .atomic)
        prune(dir)
    }

    static func prune(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (f, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(16) { try? fm.removeItem(at: f) }
    }
}
