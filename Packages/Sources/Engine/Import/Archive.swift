import CryptoKit
import Compression
import CoreFoundation
import Foundation

final class Archive: @unchecked Sendable {
    struct Entry: Sendable {
        public var name: String
        public var size: UInt64
        public var key: String
        var loc: Loc
    }

    enum Loc {
        case file(URL)
        case zip(ZIPEntry)
        case memory([UInt8])
    }

    enum Failure: Error {
        case io(String)
        case zip(String)
    }

    private(set) var entries: [Entry] = []
    private(set) var nameEncoding = "UTF-8"
    let zipURL: URL?

    private init(zipURL: URL?) { self.zipURL = zipURL }

    public static func open(_ url: URL, textureRefs: ([UInt8]) -> [String]) throws -> Archive {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let a = Archive(zipURL: nil)
            try listDir(root: url, dir: url, into: &a.entries)
            return a
        }
        if RAR.isRAR(url) { return try open(RAR.extract(url), textureRefs: textureRefs) }
        let a = Archive(zipURL: url)
        let raw = try ZIPEntry.readDirectory(url).filter { !$0.isDirectory }
        let main = raw.filter { $0.name.lowercasedASCII.suffix(4).elementsEqual(".pmx".utf8) }.lastMax { $0.size }
        let refs = try main.map { textureRefs(try $0.read(url)) } ?? []
        let enc = chooseEncoding(raw.filter { !$0.utf8Flag }.map(\.name), refs)
        a.entries = raw.map { e in
            let name = e.utf8Flag ? String(decoding: e.name, as: UTF8.self) : decode(e.name, enc).text
            var sizeLE = e.size.littleEndian, crcLE = e.crc.littleEndian
            let key = cacheKey([e.name, withUnsafeBytes(of: &sizeLE) { Array($0) }, withUnsafeBytes(of: &crcLE) { Array($0) }])
            return Entry(name: name.replacingOccurrences(of: "\\", with: "/"), size: e.size, key: key, loc: .zip(e))
        }
        a.nameEncoding = enc.name
        return a
    }

    public static func file(_ url: URL) throws -> Archive {
        let a = Archive(zipURL: nil)
        a.entries = [try fileEntry(root: url.deletingLastPathComponent(), url)]
        return a
    }

    @discardableResult
    func pushMemory(name: String, key: String, data: [UInt8]) -> Int {
        entries.append(Entry(name: name, size: UInt64(data.count), key: key, loc: .memory(data)))
        return entries.count - 1
    }

    public func read(_ i: Int) throws -> [UInt8] {
        guard entries.indices.contains(i) else { throw Failure.io("no entry \(i)") }
        switch entries[i].loc {
        case let .file(url):
            do { return [UInt8](try Data(contentsOf: url)) } catch { throw Failure.io("\(error)") }
        case let .zip(z):
            guard let zipURL else { throw Failure.io("no zip") }
            return try z.read(zipURL)
        case let .memory(d):
            return d
        }
    }

    public func index(of name: String) -> Int? { entries.firstIndex { $0.name == name } }

    /// 同じ大きさなら後のもの。
    func largest(_ exts: [String]) -> Int? {
        entries.indices.filter { i in
            let n = entries[i].name.lowercased()
            return exts.contains { n.hasSuffix($0) }
        }.lastMax { entries[$0].size }
    }

    var mainPMX: Int? { largest([".pmx"]) }
    var mainPMD: Int? { largest([".pmd"]) }
    var mainVRM: Int? { largest([".vrm", ".glb", ".fbx"]) }

    static func fileEntry(root: URL, _ url: URL) throws -> Entry {
        var st = stat()
        guard stat(url.path, &st) == 0 else { throw Failure.io("stat \(url.path)") }
        let size = UInt64(st.st_size)
        let nanos = UInt128(UInt64(st.st_mtimespec.tv_sec)) * 1_000_000_000 + UInt128(st.st_mtimespec.tv_nsec)
        let path = url.path
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let rel = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
        var s = size.littleEndian, n = nanos.littleEndian
        let key = cacheKey([Array(path.utf8), withUnsafeBytes(of: &s) { Array($0) }, withUnsafeBytes(of: &n) { Array($0) }])
        return Entry(name: rel.replacingOccurrences(of: "\\", with: "/"), size: size, key: key, loc: .file(url))
    }

    static func listDir(root: URL, dir: URL, into out: inout [Entry]) throws {
        guard let d = opendir(dir.path) else { throw Failure.io("opendir \(dir.path)") }
        defer { closedir(d) }
        while let e = readdir(d) {
            let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(e.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let url = dir.appending(path: name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            if isDir.boolValue {
                try listDir(root: root, dir: url, into: &out)
            } else {
                out.append(try fileEntry(root: root, url))
            }
        }
    }
}

/// 各部分のあとに 0xff を挟んだ SHA-256 の先頭 8 バイト。版をまたいで値を変えない。
func cacheKey(_ parts: [[UInt8]]) -> String {
    var h = SHA256()
    for p in parts {
        h.update(data: p)
        h.update(data: [0xff])
    }
    return h.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
}

struct NameEncoding {
    let name: String
    let cf: CFStringEncoding?

    static let utf8 = NameEncoding(name: "UTF-8", cf: nil)
    static let gbk = NameEncoding(name: "GBK", cf: CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    static let shiftJIS = NameEncoding(name: "Shift_JIS", cf: CFStringEncoding(CFStringEncodings.dosJapanese.rawValue))
}

/// ponytail: 壊れた所だけでなく全体を UTF-8 として読み直す。壊れた名前のファイルはどのみちテクスチャとして見つからない。
func decode(_ bytes: [UInt8], _ enc: NameEncoding) -> (text: String, errors: Bool) {
    guard let cf = enc.cf else {
        let ok = String(validating: bytes, as: UTF8.self)
        return (ok ?? String(decoding: bytes, as: UTF8.self), ok == nil)
    }
    if bytes.allSatisfy({ $0 < 0x80 }) { return (String(decoding: bytes, as: UTF8.self), false) }
    if let s = CFStringCreateWithBytes(nil, bytes, bytes.count, cf, false) { return (s as String, false) }
    return (String(decoding: bytes, as: UTF8.self), true)
}

/// 同点は GBK。
func chooseEncoding(_ names: [[UInt8]], _ refs: [String]) -> NameEncoding {
    if names.allSatisfy({ String(validating: $0, as: UTF8.self) != nil }) { return .utf8 }
    let keys = refs.map(basenameKey)
    func score(_ enc: NameEncoding) -> (Bool, Int, Int) {
        var errors = 0, matches = 0, kana = 0, half = 0
        for n in names {
            let (s, bad) = decode(n, enc)
            if bad { errors += 1 }
            if keys.contains(basenameKey(s)) { matches += 1 }
            for u in s.unicodeScalars {
                if (0x3040...0x30FF).contains(u.value) { kana += 1 }
                if (0xFF61...0xFF9F).contains(u.value) { half += 1 }
            }
        }
        return (errors == 0, matches, kana - half)
    }
    let g = score(.gbk), s = score(.shiftJIS)
    let sjisWins = (s.0 ? 1 : 0, s.1, s.2) > (g.0 ? 1 : 0, g.1, g.2)
    return sjisWins ? .shiftJIS : .gbk
}

func basenameKey(_ path: String) -> String {
    let name = String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? Substring(path))
    let lower = path.hasSuffix("/") || path.hasSuffix("\\") ? "" : name.lowercased()
    if let dot = lower.lastIndex(of: "."), dot != lower.startIndex { return String(lower[..<dot]) }
    return lower
}



extension Array where Element == UInt8 {
    var lowercasedASCII: [UInt8] { map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 } }
}

struct TextureResolver {
    var byPath: [String: String] = [:]
    var byStem: [String: [String]] = [:]
    let pmxDir: String

    init(_ archive: Archive, pmxPath: String) {
        for e in archive.entries {
            byPath[e.name.lowercased()] = e.name
            byStem[basenameKey(e.name), default: []].append(e.name)
        }
        pmxDir = pmxPath.lastIndex(of: "/").map { String(pmxPath[..<$0]) } ?? ""
    }

    func resolve(_ reference: String) -> String? {
        let joined = Self.normalize("\(pmxDir)/\(reference.replacingOccurrences(of: "\\", with: "/"))")
        if let hit = byPath[joined.lowercased()] { return hit }
        return byStem[basenameKey(reference)]?.lastMax { Self.commonPrefix($0, joined) }
    }

    static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for p in path.split(separator: "/", omittingEmptySubsequences: false) {
            switch p {
            case "", ".": break
            case "..": _ = parts.popLast()
            default: parts.append(p)
            }
        }
        return parts.joined(separator: "/")
    }

    static func commonPrefix(_ a: String, _ b: String) -> Int {
        zip(a.unicodeScalars, b.unicodeScalars).prefix { x, y in
            x == y || (x.isASCII && y.isASCII && x.properties.lowercaseMapping == y.properties.lowercaseMapping)
        }.count
    }
}
