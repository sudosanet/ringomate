import Foundation
import os

public struct SongInfo: Sendable, Equatable {
    public var id: String
    public var title: String
    public var artist: String
    public var dances: [SongDance]
    public var front: Float?
}

public struct SongDance: Sendable, Equatable {
    public var path: String
    /// `SongNow.clipTime` に足すと、この踊りのクリップの秒になる。
    public var shift: Double
}

public struct SongNow: Sendable, Equatable {
    public var pack: UInt32
    public var version: String
    public var refTime: Double
    public var clipTime: Double?
    public var rate: Double
    /// 基準の版の長さ（秒）。`refTime` と同じ時計。
    public var refSeconds: Double
}

public final class Songs: Sendable {
    let library: SongLibrary
    let follower = OSAllocatedUnfairLock(initialState: SongFollower())

    init(library: SongLibrary) { self.library = library }

    public static func open(roots: [String], cache: String) -> Songs {
        Songs(library: SongLibrary(roots: roots.map { URL(filePath: $0) }, cache: URL(filePath: cache)))
    }

    public func songs() -> [SongInfo] {
        library.packs.map { p in
            SongInfo(id: p.toml.id, title: p.toml.title, artist: p.toml.artist,
                     dances: p.dances.map { SongDance(path: $0.path.path, shift: $0.shift) }, front: p.toml.dance.front)
        }
    }

    public func errors() -> [String] { library.errors.map { "\($0.0.path): \($0.1)" } }

    /// 24kHz の 1 チャンネル。重い計算はロックの外でして、位置を読む側（毎フレーム）を待たせない。
    public func update(samples: [Float], end: Double) {
        let o = SongFollower.observe(library, samples: samples, end: end)
        follower.withLock { $0.apply(o, library) }
    }

    public func position(now: Double) -> SongNow? {
        guard let p = follower.withLock({ $0.position(library, now: now) }) else { return nil }
        return SongNow(pack: UInt32(p.pack), version: library.packs[p.pack].analysis.versions[p.version].name, refTime: p.refTime,
                       clipTime: p.clipTime, rate: p.rate,
                       refSeconds: Double(library.packs[p.pack].analysis.versions.first?.seconds ?? 0))
    }
}
