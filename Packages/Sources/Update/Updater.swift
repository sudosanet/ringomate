import Foundation
import os
import Security

/// GitHub の最新の Release の dmg に入れ替える。入れるのは、同じチームの Developer ID で署名して公証してあるものだけ。
public final class Updater: Sendable {
    public static let api = URL(string: "https://api.github.com/repos/sudosanet/ringomate/releases/latest")!
    static let requirement = #"anchor apple generic and identifier "app.ringomate" and certificate leaf[subject.OU] = "4RU8L6U52Z" and notarized"#

    public struct Release: Sendable, Equatable {
        public let version: String
        public let dmg: URL
        public let page: URL
    }

    struct Bad: Error, CustomStringConvertible { let description: String }

    let current: String
    let app: URL
    let api: URL
    let session: URLSession
    private let log = Logger(subsystem: "app.ringomate", category: "update")

    public init(current: String, app: URL = Bundle.main.bundleURL, api: URL = Updater.api, session: URLSession = .shared) {
        (self.current, self.app, self.api, self.session) = (current, app, api, session)
    }

    /// 今より新しい版があればそれ、なければ nil
    public func check() async throws -> Release? {
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Bad(description: "HTTP \(http.statusCode)") }
        return Self.newer(try JSONDecoder().decode(Latest.self, from: data), than: current)
    }

    struct Latest: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let html_url: URL
        let assets: [Asset]
    }

    static func newer(_ latest: Latest, than current: String) -> Release? {
        let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
        guard version.compare(current, options: .numeric) == .orderedDescending,
              let dmg = latest.assets.first(where: { $0.name == "RingoMate.dmg" }) else { return nil }
        return Release(version: version, dmg: dmg.browser_download_url, page: latest.html_url)
    }

    /// 落として、署名を確かめて、`app` を入れ替える（動いているアプリはそのまま。次に開いたときから新しい版）
    public func install(_ release: Release) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "ringomate-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let (download, response) = try await session.download(from: release.dmg)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Bad(description: "HTTP \(http.statusCode)") }
        let dmg = work.appending(path: "update.dmg"), mount = work.appending(path: "mnt")
        try fm.moveItem(at: download, to: dmg)
        try run("/usr/bin/hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path)
        defer { try? run("/usr/bin/hdiutil", "detach", "-force", mount.path) }
        // 同じボリュームに写してから確かめて入れ替える（確かめたものと入れるものを同じにする）
        let staged = app.deletingLastPathComponent().appending(path: ".RingoMate-\(release.version).app")
        try? fm.removeItem(at: staged)
        try run("/usr/bin/ditto", mount.appending(path: "RingoMate.app").path, staged.path)
        do {
            try Self.verify(staged)
            _ = try fm.replaceItemAt(app, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        log.notice("updated to \(release.version, privacy: .public)")
    }

    static func verify(_ app: URL) throws {
        var code: SecStaticCode?, req: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else {
            throw Bad(description: "cannot read the signature")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate), req)
        guard status == errSecSuccess else { throw Bad(description: "signature check failed: \(status)") }
    }

    /// このプロセスが終わったら `app` を開き直す。呼んだあとにアプリを終える
    public func relaunch() throws {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
                       String(ProcessInfo.processInfo.processIdentifier), app.path]
        try p.run()
    }

    private func run(_ tool: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(filePath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Bad(description: "\((tool as NSString).lastPathComponent): exit \(p.terminationStatus)") }
    }
}
