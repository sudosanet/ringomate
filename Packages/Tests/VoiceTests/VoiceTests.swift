import Foundation
import Testing
@testable import Voice

struct VoiceTests {
    @Test func decimate() {
        #expect(Speaker.decimate([1, 2, 3, 4, 5, 6, 7]) == [2, 5])
    }

    @MainActor static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<1500 where !done() { try await Task.sleep(for: .milliseconds(20)) }
        try #require(done(), "timed out")
    }

    static func makeZip() throws -> (zip: URL, sha: String, root: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "voice-test-\(UUID().uuidString)")
        let content = root.appending(path: "content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: content.appending(path: "constants.json"))
        let zip = root.appending(path: "models.zip")
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", content.path, zip.path]
        try p.run()
        p.waitUntilExit()
        return (zip, try VoiceModels.sha256(of: zip), root)
    }

    @MainActor @Test func downloadsAndInstalls() async throws {
        let (zip, sha, root) = try Self.makeZip()
        defer { try? FileManager.default.removeItem(at: root) }
        let models = VoiceModels(source: zip, checksum: sha, work: root.appending(path: "work"), directory: root.appending(path: "models/irodori"))
        #expect(models.state == .missing)
        models.download()
        try await Self.wait { models.state == .installed || models.state.isFailed }
        #expect(models.state == .installed)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "models/irodori/constants.json").path))
        models.delete()
        #expect(models.state == .missing)
    }

    @MainActor @Test func rejectsBadChecksum() async throws {
        let (zip, _, root) = try Self.makeZip()
        defer { try? FileManager.default.removeItem(at: root) }
        let models = VoiceModels(source: zip, checksum: String(repeating: "0", count: 64), work: root.appending(path: "work"),
                                 directory: root.appending(path: "models/irodori"))
        models.download()
        try await Self.wait { models.state.isFailed || models.state == .installed }
        #expect(models.state.isFailed)
        #expect(!models.installed)
    }
}

extension VoiceModels.State {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}
