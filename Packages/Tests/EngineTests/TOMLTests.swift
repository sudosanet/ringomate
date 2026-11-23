@testable import Engine
import Foundation
import Testing

@Test func tomlReadsTheSyntaxWeUse() throws {
    let doc = try TOML.parse(#"""
    # コメント
    name = "Tsukuyomi" # 行末のコメント
    "quoted key" = 'literal \n'
    n = 1_000
    hex = 0xff
    f = -1.5e3
    yes = true
    list = [1, 2.5, "x",
      [true], ] # 改行と末尾のカンマ
    inline = { a = 1, b.c = "d" }
    multi = """
    1 行目\
       続き
    あ"""

    [table.sub]
    k = 1

    [[item]]
    v = 1
    [item.extra]
    w = 2

    [[item]]
    v = 2
    """#)
    #expect(doc["name"] == .string("Tsukuyomi"))
    #expect(doc["quoted key"] == .string("literal \\n"))
    #expect(doc["n"] == .int(1000) && doc["hex"] == .int(255))
    #expect(doc["f"] == .float(-1500) && doc["yes"] == .bool(true))
    #expect(doc["list"] == .array([.int(1), .float(2.5), .string("x"), .array([.bool(true)])]))
    #expect(doc["inline"]?["b"]?["c"] == .string("d"))
    #expect(doc["multi"] == .string("1 行目続き\nあ"))
    #expect(doc["table"]?["sub"]?["k"] == .int(1))
    #expect(doc["item"]?.array?.count == 2)
    #expect(doc["item"]?.array?[0]["extra"]?["w"] == .int(2))
    #expect(throws: TOMLError.self) { try TOML.parse("a = 1\na = 2") }
    #expect(throws: TOMLError.self) { try TOML.parse("a = \"x") }
}

/// `TOML_EXPECTED=<tomllib の JSON のパス>` があれば中身も比べる。
@Test func tomlMatchesTomllibOnRepositoryFiles() throws {
    let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized
    let expected: [String: Any]? = ProcessInfo.processInfo.environment["TOML_EXPECTED"].flatMap {
        try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: $0))) as? [String: Any]
    }
    var files: [String] = []
    for dir in ["Packages/Sources/Engine/Profiles", "assets"] {
        let base = repo.appending(path: dir)
        for case let url as URL in FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) ?? .init()
        where url.pathExtension == "toml" {
            files.append(String(url.standardized.path.dropFirst(repo.path.count + 1)))
        }
    }
    for p in expected.map({ Array($0.keys) }) ?? files {
        let doc = try TOML.parse(String(contentsOf: repo.appending(path: p), encoding: .utf8))
        if let want = expected?[p] {
            #expect(NSDictionary(dictionary: plain(.table(doc)) as! [String: Any]).isEqual(want), "\(p)")
        }
    }
    #expect(files.count > (Assets.hasSongs ? 100 : 5))
}

private func plain(_ v: TOML) -> Any {
    switch v {
    case let .string(s): s
    case let .int(i): NSNumber(value: i)
    case let .float(f): f.isFinite ? NSNumber(value: f) : "\(f)" as Any
    case let .bool(b): NSNumber(value: b)
    case let .array(a): a.map(plain)
    case let .table(t): t.mapValues(plain)
    }
}
