import CryptoKit
import Foundation
@testable import Listen
import Testing

/// file:// のフォルダをサーバーに見立てる
private struct Server {
    let root = FileManager.default.temporaryDirectory.appending(path: "songsync-\(UUID().uuidString)")

    func publish(_ packs: [String: [String: String]], schema: Int = 1) throws {
        try FileManager.default.createDirectory(at: root.appending(path: "o"), withIntermediateDirectories: true)
        var m = SongSync.Manifest(schema: 1, packs: [:])
        for (key, files) in packs {
            var p = SongSync.Pack(schema: schema, files: [:])
            for (name, text) in files {
                let data = Data(text.utf8)
                let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                try ((data as NSData).compressed(using: .lzma) as Data).write(to: root.appending(path: "o/\(hash)"))
                p.files[name] = hash
            }
            m.packs[key] = p
        }
        try JSONEncoder().encode(m).write(to: root.appending(path: "manifest.json"))
    }
}

@Test func syncsOnlyWhatChanged() async throws {
    let server = Server()
    let local = FileManager.default.temporaryDirectory.appending(path: "songsync-local-\(UUID().uuidString)")
    let sync = SongSync(directory: local, server: server.root)
    let a = "0123456789abcdef", b = "fedcba9876543210"

    try server.publish([a: ["song.toml": "a1", "lips.bin": "la"], b: ["song.toml": "b1"]])
    #expect(try await sync.sync() == 2)
    #expect(try String(contentsOf: local.appending(path: "\(a)/song.toml"), encoding: .utf8) == "a1")

    // 変わったファイルだけ落とす: 変わっていない lips.bin はサーバーから消しても手元から写る
    try server.publish([a: ["song.toml": "a2", "lips.bin": "la"], b: ["song.toml": "b1"]])
    let lips = SHA256.hash(data: Data("la".utf8)).map { String(format: "%02x", $0) }.joined()
    try FileManager.default.removeItem(at: server.root.appending(path: "o/\(lips)"))
    #expect(try await sync.sync() == 1)
    #expect(try String(contentsOf: local.appending(path: "\(a)/song.toml"), encoding: .utf8) == "a2")
    #expect(try String(contentsOf: local.appending(path: "\(a)/lips.bin"), encoding: .utf8) == "la")

    // 消えたパックは消す。読めない schema は入れない
    try server.publish([a: ["song.toml": "a2", "lips.bin": "la"]])
    #expect(try await sync.sync() == 1)
    #expect(!FileManager.default.fileExists(atPath: local.appending(path: b).path))
    #expect(try await sync.sync() == 0)
    try server.publish([b: ["song.toml": "b9"]], schema: 2)
    #expect(try await sync.sync() == 1)
    #expect(try FileManager.default.contentsOfDirectory(atPath: local.path).filter { !$0.hasPrefix(".") }.isEmpty)
}

@Test func rejectsPathsAndBadData() async throws {
    let ok = String(repeating: "a", count: 64)
    #expect(!SongSync.valid("../../etc", SongSync.Pack(schema: 1, files: ["x": ok])))
    #expect(!SongSync.valid("0123456789abcdef", SongSync.Pack(schema: 1, files: ["../x": ok])))
    #expect(!SongSync.valid("0123456789abcdef", SongSync.Pack(schema: 1, files: [".manifest.json": ok])))
    #expect(SongSync.valid("0123456789abcdef", SongSync.Pack(schema: 1, files: ["song.toml": ok])))

    // 中身がハッシュと合わなければ入れない
    let server = Server()
    try server.publish(["0123456789abcdef": ["song.toml": "x"]])
    let hash = SHA256.hash(data: Data("x".utf8)).map { String(format: "%02x", $0) }.joined()
    try ((Data("y".utf8) as NSData).compressed(using: .lzma) as Data).write(to: server.root.appending(path: "o/\(hash)"))
    let local = FileManager.default.temporaryDirectory.appending(path: "songsync-local-\(UUID().uuidString)")
    #expect(try await SongSync(directory: local, server: server.root).sync() == 0)
    #expect(!FileManager.default.fileExists(atPath: local.appending(path: "0123456789abcdef").path))
}
