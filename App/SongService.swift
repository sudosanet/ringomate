import CoreBridge
import Engine
import Foundation
import MascotCore
import os
import Listen

@MainActor
final class SongService {
    private let log = Logger(subsystem: "app.ringomate", category: "song")
    private let queue = DispatchQueue(label: "app.ringomate.songs", qos: .userInitiated)
    private var songs: Songs?
    private var infos: [SongInfo] = []
    private var busy = false
    private var lastUpdate = 0.0
    private var watcher: DispatchSourceFileSystemObject?
    private var loggedSong = ""
    private static let danceSlots = 508..<540
    private var slots: [String: Int] = [:]
    private var slotOrder: [String] = []
    private var baking: Set<String> = []
    private var chosen: (pack: UInt32, dance: Int)?
    private var lipsTracks: [String: LipsTrack?] = [:]
    private(set) var lips: [Float]?
    private(set) var locked: SongInfo?
    /// 曲の中の位置と長さ（秒）。
    private(set) var progress: (time: Double, length: Double)?

    static var userRoot: URL {
        URL.applicationSupportDirectory.appending(path: "ringomate/songs")
    }

    /// R2 から写したアセット。同じ id ならユーザーの曲が勝つ（後の root が勝つ）
    private let sync = SongSync(directory: URL.applicationSupportDirectory.appending(path: "ringomate/synced-songs"))
    private var syncScheduler: NSBackgroundActivityScheduler?
    /// アセットを落としている間の（済んだ数, 全体）。落としていないときは nil
    var onSyncProgress: ((done: Int, total: Int)?) -> Void = { _ in }

    private var roots: [String] {
        [Bundle.main.resourceURL?.appending(path: "songs").path, sync.directory.path, Self.userRoot.path].compactMap { $0 }
    }

    func start() {
        try? FileManager.default.createDirectory(at: Self.userRoot, withIntermediateDirectories: true)
        reload()
        startSync()
        let fd = open(Self.userRoot.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    func reload() {
        lipsTracks.removeAll()
        let roots = self.roots
        let cache = URL.cachesDirectory.appending(path: "app.ringomate/songs").path
        queue.async { [weak self] in
            let s = Songs.open(roots: roots, cache: cache)
            let infos = s.songs(), errors = s.errors()
            Task { @MainActor [weak self] in
                guard let self else { return }
                (self.songs, self.infos) = (s, infos)
                self.log.info("songs: \(infos.count) packs")
                for e in errors { self.log.error("song pack: \(e, privacy: .private)") }
            }
        }
    }

    var packs: [SongInfo] { infos }

    /// 起動したときと、それから 1 日ごとに R2 のアセットを写す
    private func startSync() {
        let sync = self.sync, log = self.log
        let run: @Sendable () async -> Void = { [weak self] in
            do {
                let n = try await sync.sync { done, total in
                    Task { @MainActor in self?.onSyncProgress(done < total ? (done, total) : nil) }
                }
                if n > 0 { await self?.reload() }
                log.info("song sync: \(n) changed")
            } catch {
                log.error("song sync: \(error, privacy: .public)")
            }
            await MainActor.run { self?.onSyncProgress(nil) }
        }
        Task(priority: .utility) { await run() }
        let s = NSBackgroundActivityScheduler(identifier: "app.ringomate.song-sync")
        s.repeats = true
        s.interval = 24 * 60 * 60
        s.qualityOfService = .utility
        s.schedule { done in Task { await run(); done(.finished) } }
        syncScheduler = s
    }

    /// `audio` は 0.5 秒ごとの照合のときだけ呼ぶ（8 秒ぶんのコピー）。`hasAudio` は 8 秒ぶんたまっているか。
    func tick(hasAudio: Bool, audio: () -> (samples: [Float], end: Double)?, now: Double, ahead: Double) -> SongPlaying? {
        guard let songs else { return nil }
        if hasAudio, !busy, now - lastUpdate >= 0.5, let audio = audio() {
            lastUpdate = now
            busy = true
            queue.async { [weak self] in
                songs.update(samples: audio.samples, end: audio.end)
                Task { @MainActor [weak self] in self?.busy = false }
            }
        }
        guard hasAudio, let p = songs.position(now: now + ahead), infos.indices.contains(Int(p.pack)) else {
            loggedSong = ""
            lips = nil
            locked = nil
            progress = nil
            return nil
        }
        let id = infos[Int(p.pack)].id
        locked = infos[Int(p.pack)]
        progress = (p.refTime, p.refSeconds)
        lips = lipsTrack(infos[Int(p.pack)])?.vowels(at: p.refTime)
        let line = "\(id) \(p.version) ref \(Int(p.refTime))s clip \(p.clipTime.map { "\(Int($0))s" } ?? "-")"
        if line != loggedSong {
            if loggedSong.split(separator: " ").first != line.split(separator: " ").first {
                log.notice("song locked \(line, privacy: .private)")
            } else {
                log.info("song \(line, privacy: .private)")
            }
            loggedSong = line
        }
        if chosen?.pack != p.pack {
            chosen = (p.pack, Int.random(in: 0..<max(1, infos[Int(p.pack)].dances.count)))
        }
        guard let clip = p.clipTime, let k = chosen?.dance else { return nil }
        let shift = infos[Int(p.pack)].dances.indices.contains(k) ? infos[Int(p.pack)].dances[k].shift : 0
        return SongPlaying(id: k == 0 ? id : "\(id)#\(k)", clipTime: Float(clip + shift), rate: Float(p.rate))
    }

    private func lipsTrack(_ info: SongInfo) -> LipsTrack? {
        if let t = lipsTracks[info.id] { return t }
        let dir = info.dances.first.map { URL(filePath: $0.path).deletingLastPathComponent() }
        let t = dir.flatMap { LipsTrack(url: $0.appending(path: "lips.bin")) }
        lipsTracks[info.id] = t
        return t
    }

    func bake(id: String, core: Core, generation: @escaping @MainActor () -> Int, done: @escaping @MainActor (String, Int) -> Void) {
        let parts = id.split(separator: "#")
        let k = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        guard slots[id] == nil, !baking.contains(id), let info = infos.first(where: { $0.id == parts.first.map(String.init) }),
              info.dances.indices.contains(k) else { return }
        let path = info.dances[k].path
        let slot: Int
        if let free = Self.danceSlots.first(where: { !slots.values.contains($0) }) {
            slot = free
        } else {
            let oldest = slotOrder.removeFirst()
            slot = slots.removeValue(forKey: oldest) ?? Self.danceSlots.lowerBound
        }
        baking.insert(id)
        let gen = generation()
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try core.assignSongDance(index: slot, path: path, front: info.front) }
            await MainActor.run {
                guard let self else { return }
                self.baking.remove(id)
                switch result {
                case .success where generation() == gen:
                    self.slots[id] = slot
                    self.slotOrder.append(id)
                    done(id, slot)
                case .success:
                    break
                case let .failure(e):
                    self.log.error("song dance \(id, privacy: .private): \(e, privacy: .private)")
                }
            }
        }
    }

    func forgetDances() {
        (slots, slotOrder, baking) = ([:], [], [])
    }
}
