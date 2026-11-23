import CryptoKit
import Foundation
import MascotCore

/// 声のモデル（swift-irodori-tts の Releases の zip）を裏で落として展開する。
@MainActor
public final class VoiceModels {
    public enum State: Equatable, Sendable {
        case missing
        case downloading(Double)
        case installing
        case installed
        case failed(String)
    }

    static let release = URL(string: "https://github.com/sudosanet/swift-irodori-tts/releases/download/0.1.0/IrodoriTTS-v4.1-Small-MF-coreai.zip")!
    static let sha256 = "89876e8f2780338fd43998c6e4ed5b4a2f300153983c44f225837b445dcd3bcd"

    public private(set) var state: State {
        didSet { if state != oldValue { onChange(state) } }
    }
    public var onChange: (State) -> Void = { _ in }
    public let directory: URL
    public var installed: Bool { FileManager.default.fileExists(atPath: directory.appending(path: "constants.json").path) }

    let source: URL
    let checksum: String
    let work: URL
    private var job: Task<Void, Never>?
    private let box = TaskBox()

    public convenience init() {
        self.init(source: Self.release, checksum: Self.sha256,
                  work: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ringomate/voice"),
                  directory: modelDirectory("irodori", marker: "constants.json"))
    }

    init(source: URL, checksum: String, work: URL, directory: URL) {
        (self.source, self.checksum, self.work, self.directory) = (source, checksum, work, directory)
        state = .missing
        state = installed ? .installed : .missing
    }

    var resumeFile: URL { work.appending(path: "download.resume") }

    public func download() {
        guard job == nil, !installed else { return }
        state = .downloading(0)
        job = Task { await run() }
    }

    /// 取り消す。続きのデータを残すので、次の download() はそこから落とす。
    public func cancel() {
        box.pause(saveTo: resumeFile)
    }

    /// 終了の前に続きのデータを書き出す（最大 1 秒待つ）。
    public func suspendForQuit() {
        guard job != nil else { return }
        let done = box.pause(saveTo: resumeFile)
        let deadline = Date().addingTimeInterval(1)
        while !done.isSet, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    }

    public func delete() {
        guard job == nil else { return }
        try? FileManager.default.removeItem(at: directory)
        state = installed ? .installed : .missing
    }

    private func run() async {
        defer { job = nil }
        let poll = Task { [box] in
            while !Task.isCancelled {
                if let f = box.fraction { self.state = .downloading(f) }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { poll.cancel() }
        do {
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = try await fetch()
            poll.cancel()
            state = .installing
            let (checksum, work, destination) = (checksum, work, directory)
            try await Task.detached(priority: .utility) { try Self.install(zip: zip, checksum: checksum, work: work, to: destination) }.value
            state = .installed
        } catch is CancellationError {
            state = .missing
        } catch let error as URLError where error.code == .cancelled {
            state = .missing
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func fetch() async throws -> URL {
        let resume = try? Data(contentsOf: resumeFile)
        try? FileManager.default.removeItem(at: resumeFile)
        let temp: URL
        do {
            if let resume {
                do {
                    temp = try await URLSession.shared.download(resumeFrom: resume, delegate: box).0
                } catch let error as URLError where error.code != .cancelled && error.downloadTaskResumeData == nil {
                    // 続きのデータが古いときは最初から
                    temp = try await URLSession.shared.download(from: source, delegate: box).0
                }
            } else {
                temp = try await URLSession.shared.download(from: source, delegate: box).0
            }
        } catch let error as URLError {
            if let data = error.downloadTaskResumeData { try? data.write(to: resumeFile) }
            throw error
        }
        let zip = work.appending(path: "models.zip")
        try? FileManager.default.removeItem(at: zip)
        try FileManager.default.moveItem(at: temp, to: zip)
        return zip
    }

    nonisolated static func install(zip: URL, checksum: String, work: URL, to destination: URL) throws {
        defer { try? FileManager.default.removeItem(at: zip) }
        guard try sha256(of: zip) == checksum else { throw VoiceError.checksum }
        let unpacked = work.appending(path: "unpacked")
        try? FileManager.default.removeItem(at: unpacked)
        let ditto = Process()
        ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0,
              FileManager.default.fileExists(atPath: unpacked.appending(path: "constants.json").path) else { throw VoiceError.unpack }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: unpacked, to: destination)
    }

    nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 22), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum VoiceError: LocalizedError {
    case checksum, unpack

    var errorDescription: String? {
        switch self {
        case .checksum: String(localized: "The downloaded file is damaged", bundle: #bundle)
        case .unpack: String(localized: "Could not unpack the voice models", bundle: #bundle)
        }
    }
}

/// URLSession の裏のスレッドから届く進捗と、取り消し用のタスク。
final class TaskBox: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?

    var fraction: Double? { lock.withLock { task.map { $0.progress.fractionCompleted } } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { self.task = task }
    }

    @discardableResult
    func pause(saveTo url: URL) -> Flag {
        let flag = Flag()
        guard let task = lock.withLock({ self.task }) as? URLSessionDownloadTask, task.state == .running else {
            flag.set()
            return flag
        }
        task.cancel { data in
            if let data { try? data.write(to: url) }
            flag.set()
        }
        return flag
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
