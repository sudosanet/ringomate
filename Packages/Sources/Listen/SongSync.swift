import CryptoKit
import Foundation
import os

/// アセットデータを R2 から `directory` へ差分で写す。サーバーには manifest.json と、各ファイルを xz にした o/<平文の sha256> がある。
/// 写したものは `directory/<名前>/`、写し終えた manifest は `directory/.manifest.json`。
public final class SongSync: Sendable {
    public static let server = URL(string: "https://s3.ringomate-songs.sudosan.net")!
    /// 読める song.toml の schema の上限
    static let schema = 1

    struct Manifest: Codable, Equatable {
        var schema: Int
        var packs: [String: Pack]
    }

    struct Pack: Codable, Equatable {
        var schema: Int
        var files: [String: String]
    }

    struct Bad: Error, CustomStringConvertible { let description: String }

    public let directory: URL
    let server: URL
    let session: URLSession
    private let log = Logger(subsystem: "app.ringomate", category: "song-sync")

    public init(directory: URL, server: URL = SongSync.server, session: URLSession = .shared) {
        (self.directory, self.server, self.session) = (directory, server, session)
    }

    private var localManifest: URL { directory.appending(path: ".manifest.json") }

    /// 変わった（足した・直した・消した）数を返す。1 つの失敗はログに残して次へ（次の回にまた試す）。
    /// `progress` は落とすものがあるときだけ（済んだ数, 全体）で呼ぶ。
    public func sync(progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Int {
        let remote = try JSONDecoder().decode(Manifest.self, from: try await get(server.appending(path: "manifest.json")))
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasPrefix(".tmp-") {
            try? fm.removeItem(at: directory.appending(path: name))
        }
        var local = (try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: localManifest))) ?? Manifest(schema: 1, packs: [:])
        let want = remote.packs.filter { $0.value.schema <= Self.schema && Self.valid($0.key, $0.value) }
        var changed = 0
        for key in local.packs.keys where want[key] == nil {
            try? fm.removeItem(at: directory.appending(path: key))
            local.packs[key] = nil
            changed += 1
        }
        let todo = want.filter { local.packs[$0.key] != $0.value || !fm.fileExists(atPath: directory.appending(path: $0.key).path) }
            .sorted { $0.key < $1.key }
        try save(local)
        let old = local.packs
        var finished = 0
        if !todo.isEmpty { progress(0, todo.count) }
        try await withThrowingTaskGroup(of: (String, Pack, Bool).self) { group in
            var next = todo.makeIterator()
            func add() {
                guard let (key, pack) = next.next() else { return }
                group.addTask {
                    do {
                        try await self.install(key, pack, old: old[key])
                        return (key, pack, true)
                    } catch {
                        self.log.error("song pack \(key, privacy: .public): \(error, privacy: .public)")
                        return (key, pack, false)
                    }
                }
            }
            for _ in 0..<8 { add() }
            for try await (key, pack, ok) in group {
                finished += 1
                progress(finished, todo.count)
                if ok {
                    local.packs[key] = pack
                    changed += 1
                    try save(local)
                }
                add()
            }
        }
        return changed
    }

    /// サーバーの名前はパスに使うので、形の違うものは捨てる
    static func valid(_ key: String, _ pack: Pack) -> Bool {
        hex(key, 16) && !pack.files.isEmpty && pack.files.allSatisfy { name, hash in
            !name.isEmpty && !name.hasPrefix(".") && !name.contains("/") && hex(hash, 64)
        }
    }

    private static func hex(_ s: String, _ count: Int) -> Bool {
        s.utf8.count == count && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private func install(_ key: String, _ pack: Pack, old: Pack?) async throws {
        let fm = FileManager.default
        let dir = directory.appending(path: key), tmp = directory.appending(path: ".tmp-\(key)")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (name, hash) in pack.files {
            let have = dir.appending(path: name)
            if old?.files[name] == hash, fm.fileExists(atPath: have.path) {
                try fm.copyItem(at: have, to: tmp.appending(path: name))
                continue
            }
            let packed = try await get(server.appending(path: "o/\(hash)"))
            let data = try (packed as NSData).decompressed(using: .lzma) as Data
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == hash else {
                throw Bad(description: "\(name): checksum mismatch")
            }
            try data.write(to: tmp.appending(path: name))
        }
        try? fm.removeItem(at: dir)
        try fm.moveItem(at: tmp, to: dir)
    }

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Bad(description: "\(url.lastPathComponent): HTTP \(http.statusCode)")
        }
        return data
    }

    private func save(_ m: Manifest) throws {
        try JSONEncoder().encode(m).write(to: localManifest, options: .atomic)
    }
}
