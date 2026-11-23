import Foundation

/// RAR は macOS の bsdtar（libarchive）で Caches に展開して、フォルダとして読む。
enum RAR {
    static func isRAR(_ url: URL) -> Bool {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return false }
        defer { try? h.close() }
        return (try? h.read(upToCount: 6)).map { [UInt8]($0) == Array("Rar!\u{1a}\u{07}".utf8) } ?? false
    }

    // ponytail: 展開したものは消さない（Caches は OS が掃除する）。容量が問題になったら BakeCacheFile.prune のように古い順に消す
    static func extract(_ url: URL) throws -> URL {
        let key = try Archive.fileEntry(root: url.deletingLastPathComponent(), url).key
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appending(path: "Library/Caches/app.ringomate/archives")
        let dest = root.appending(path: key)
        if fm.fileExists(atPath: dest.path) { return dest }
        let work = root.appending(path: "\(key).\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/bsdtar")
        // -P を付けないので、絶対パス・".."・リンク越しの書き込みは bsdtar が断る
        p.arguments = ["-xf", url.path, "-C", work.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw Archive.Failure.io("bsdtar: \(error)") }
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Archive.Failure.io("rar: \(message.trimmingCharacters(in: .whitespacesAndNewlines))") }
        do {
            try fm.moveItem(at: work, to: dest)
        } catch where fm.fileExists(atPath: dest.path) {}
        return dest
    }
}
