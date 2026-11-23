import CryptoKit
import Foundation

public struct SongPack: Sendable {
    public var dir: URL
    public var toml: SongToml
    public var analysis: SongAnalysis

    struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// 曲を作る道具は作業フォルダの音源を絶対パスで指す。
    static func resolve(_ dir: URL, _ path: String) -> URL { path.hasPrefix("/") ? URL(filePath: path) : dir.appending(path: path) }

    var dancePath: URL { Self.resolve(dir, toml.dance.file) }

    public var dances: [(path: URL, shift: Double)] {
        [(dancePath, 0)] + toml.dance.parts.map { (Self.resolve(dir, $0.file), toml.dance.offset - $0.offset) }
    }

    public static func readToml(_ dir: URL) throws -> SongToml {
        let path = dir.appending(path: "song.toml")
        let text: String
        do { text = try String(contentsOf: path, encoding: .utf8) } catch { throw Failure(description: "\(path.path): \(error)") }
        let toml: SongToml
        do { toml = try SongToml(parsing: text) } catch { throw Failure(description: "\(path.path): \(error)") }
        if toml.schema != SongAnalysis.schema {
            throw Failure(description: "\(path.path): schema \(toml.schema) (this app reads \(SongAnalysis.schema))")
        }
        if toml.versions.isEmpty { throw Failure(description: "\(path.path): no [[version]]") }
        return toml
    }

    public static func key(_ dir: URL, _ toml: SongToml) -> UInt64 {
        var h = SHA256()
        func eat<S: Sequence<UInt8>>(_ bytes: S) { h.update(data: Array(bytes)) }
        func le(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        eat((0..<4).map { UInt8(truncatingIfNeeded: SongAnalysis.schema >> (8 * $0)) })
        eat((try? Data(contentsOf: dir.appending(path: "song.toml"))) ?? Data())
        let files = toml.versions.compactMap(\.audio) + [toml.dance.file] + toml.dance.parts.map(\.file)
        for f in files {
            guard let a = try? FileManager.default.attributesOfItem(atPath: resolve(dir, f).path) else { continue }
            eat(le((a[.size] as? NSNumber)?.uint64Value ?? 0))
            eat(le(UInt64(max(((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).rounded(.down), 0))))
        }
        return h.finalize().prefix(8).reduce(0) { $0 << 8 | UInt64($1) }
    }

    public static func analyze(_ dir: URL, _ toml: SongToml) throws -> SongAnalysis {
        var versions: [VersionAnalysis] = []
        var base: (chroma: [Chroma12], onset: [Float])?
        for v in toml.versions {
            guard let rel = v.audio else { throw Failure(description: "\(dir.path): version \(v.name) has no audio") }
            let samples = try SongAudio.load(resolve(dir, rel))
            let onset = SongFeatures.onset(samples)
            let chroma = SongFeatures.chroma(samples, rate: SongAudio.rate)
            let seconds = Float(Double(samples.count) / Double(SongAudio.rate))
            var toRef = TimeMap.identity(seconds), keyShift: UInt8 = 0
            if let b = base, !v.map.isEmpty {
                var points: [SIMD2<Float>] = []
                for (i, a) in v.map.enumerated() {
                    let end = i + 1 < v.map.count ? v.map[i + 1].x : seconds
                    for x in stride(from: a.x, to: end, by: 1) { points.append(SIMD2(x, x + a.y - a.x)) }
                }
                SongWarp.refine(&points, onset, b.onset)
                toRef = TimeMap(points: points)
            } else if let b = base {
                let (map, rot) = SongWarp.align(chroma, b.chroma, onset, b.onset)
                (toRef, keyShift) = (map, UInt8(rot))
            }
            let scale = max(onset.max() ?? 0, 1e-6) / 255
            versions.append(VersionAnalysis(
                name: v.name, seconds: seconds, fingerprint: Chromaprint.fingerprint(samples, rate: SongAudio.rate),
                onset: onset.map { UInt8(min(max(($0 / scale).rounded(), 0), 255)) }, onsetScale: scale, toRef: toRef,
                keyShift: keyShift))
            if base == nil { base = (chroma, onset) }
        }
        let dance = resolve(dir, toml.dance.file)
        let danceSeconds: Float
        do { danceSeconds = Float(try DanceLength.seconds(dance)) } catch { throw Failure(description: "\(dance.path): \(error)") }
        let single = ClipMap.single(offset: Float(toml.dance.offset), length: danceSeconds)
        let clip = toml.dance.fillRepeats && base != nil ? ClipMap.fill(base!.chroma, single) : single
        return SongAnalysis(schema: SongAnalysis.schema, key: key(dir, toml), versions: versions, clip: clip, danceSeconds: danceSeconds)
    }

    public static func writeAnalysis(_ path: URL, _ a: SongAnalysis) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(a.postcard()).write(to: path)
    }

    public static func readAnalysis(_ path: URL) -> SongAnalysis? {
        guard let d = try? Data(contentsOf: path), let a = SongAnalysis(postcard: [UInt8](d)), a.schema == SongAnalysis.schema
        else { return nil }
        return a
    }

    public static func load(_ dir: URL, cache: URL) throws -> SongPack {
        let toml = try readToml(dir)
        if let a = readAnalysis(dir.appending(path: "analysis.bin")) { return SongPack(dir: dir, toml: toml, analysis: a) }
        let k = key(dir, toml)
        let cached = cache.appending(path: String(format: "%016llx.analysis", k))
        if let a = readAnalysis(cached), a.key == k { return SongPack(dir: dir, toml: toml, analysis: a) }
        let a = try analyze(dir, toml)
        try writeAnalysis(cached, a)
        return SongPack(dir: dir, toml: toml, analysis: a)
    }
}
