import AI
import AppKit
import Behavior
import Foundation
import MascotCore
import os
import Settings
import Voice

/// 吹き出しと声をまとめる。設定は喋るたびに読む。
@MainActor
final class VoiceService {
    enum Scene {
        case chatter, reply, agent, notification

        var key: String {
            switch self {
            case .chatter: SettingsKey.voiceChatter
            case .reply: SettingsKey.voiceReply
            case .agent: SettingsKey.voiceAgent
            case .notification: SettingsKey.voiceNotification
            }
        }
    }

    let status: VoiceStatus
    let models = VoiceModels()
    private let speaker = Speaker()
    private let mascot: Mascot
    /// 通話中など、マイクを使っているアプリがあるときは声を出さない
    var micApps: () -> Set<String> = { [] }
    private var enabled = false
    private var announce = false
    private var lastMic: Set<String> = []
    /// 最後に声を使った時刻。`restAfter` 秒たつとモデルを外す。
    private var lastVoice = Date()
    private static let restAfter: TimeInterval = 600
    private let log = Logger(subsystem: "app.ringomate", category: "voice")

    init(mascot: Mascot, status: VoiceStatus) {
        self.mascot = mascot
        self.status = status
        status.model = Self.map(models.state)
        models.onChange = { [weak self] state in
            guard let self else { return }
            status.model = Self.map(state)
            if state == .installed {
                announce = true
                refresh()
            }
        }
        speaker.onReady = { [weak self] in
            guard let self else { return }
            status.loaded = true
            status.failure = nil
            lastVoice = Date()
            log.info("voice: model ready")
            refresh()
            if announce {
                announce = false
                say(String(localized: "My voice is ready!"), seconds: 4, scene: .reply)
            }
        }
        speaker.onFailure = { [weak self] in
            self?.log.error("voice: \($0, privacy: .private)")
            self?.status.failure = $0
        }
        refresh()
    }

    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "ringomate/voice")
    private var candidateURL: URL { directory.appending(path: "candidate.wav") }

    /// 見本の声のファイル。録音はユーザーが選んだファイル。
    private func sampleURL(_ p: VoicePreset) -> URL? {
        guard p == .file else { return directory.appending(path: "\(p.rawValue).wav") }
        let path = UserDefaults.standard.string(forKey: SettingsKey.voiceReference) ?? ""
        return path.isEmpty ? nil : URL(filePath: path)
    }

    private func existing(_ p: VoicePreset) -> URL? {
        sampleURL(p).flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// 非表示のあいだは喋らず、声のモデルも外す
    var suspended = false {
        didSet {
            guard suspended != oldValue else { return }
            if suspended {
                speaker.unload()
                status.loaded = false
            } else {
                refresh()
            }
        }
    }

    func refresh() {
        guard !suspended else { return }
        let d = UserDefaults.standard
        enabled = d.bool(forKey: SettingsKey.voiceEnabled)
        if enabled, models.installed {
            speaker.load(from: models.directory)
        } else {
            speaker.unload()
            status.loaded = false
        }
        speaker.volume = Float(d.double(forKey: SettingsKey.voiceVolume))
        let p = VoicePreset.selected(d)
        let sample = existing(p)
        speaker.spec = .init(caption: p == .file ? "" : p.caption(d), reference: sample)
        status.made = Set(VoicePreset.allCases.filter { existing($0) != nil }.map(\.rawValue))
        // 初めて選んだ声は、見本を 1 度作ってから使う（それまではキャプションだけ）
        if enabled, sample == nil, p != .file, status.loaded, status.making == nil { make(p, candidate: false, play: false) }
    }

    private func make(_ p: VoicePreset, candidate: Bool, play: Bool = true) {
        guard let url = candidate ? candidateURL : sampleURL(p) else { return }
        status.making = p.rawValue
        Task {
            defer { status.making = nil }
            do {
                let samples = try await speaker.makeSample(caption: p.caption())
                try Speaker.save(samples, to: url)
                if candidate {
                    status.candidate = p.rawValue
                } else {
                    speaker.invalidateVoice()
                    refresh()
                }
                if play { speaker.play(samples: samples) }
            } catch {
                status.failure = error.localizedDescription
            }
        }
    }

    func remake(_ key: String) {
        guard let p = VoicePreset(rawValue: key), p != .file, status.making == nil else { return }
        make(p, candidate: existing(p) != nil)
    }

    func preview(_ key: String) {
        guard let url = VoicePreset(rawValue: key).flatMap(existing), let samples = try? Speaker.load(url) else { return }
        speaker.play(samples: samples)
    }

    func previewCandidate() {
        guard let samples = try? Speaker.load(candidateURL) else { return }
        speaker.play(samples: samples)
    }

    func acceptCandidate() {
        guard let key = status.candidate, let p = VoicePreset(rawValue: key), let url = sampleURL(p) else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.moveItem(at: candidateURL, to: url)
        status.candidate = nil
        speaker.invalidateVoice()
        refresh()
    }

    func discardCandidate() {
        try? FileManager.default.removeItem(at: candidateURL)
        status.candidate = nil
    }

    func say(_ text: String, seconds: Float = 5, scene: Scene) {
        guard !suspended else { return }
        let d = UserDefaults.standard
        let mic = d.bool(forKey: SettingsKey.voiceQuietOnMic) ? micApps() : []
        let voiced = enabled && d.bool(forKey: scene.key) && mic.isEmpty
        mascot.say(text, seconds: seconds, voiced: voiced)
        guard voiced else {
            speaker.stop()  // 吹き出しが変わったので、前の文の声も止める
            log.info("voice: silent \(String(describing: scene), privacy: .public) enabled \(self.enabled) mic \(mic.sorted().joined(separator: ","), privacy: .public)")
            return
        }
        let japanese = SpeechLanguage.isCJK(text)
        log.info("voice: \(String(describing: scene), privacy: .public) \(japanese && self.speaker.available ? "irodori" : "system", privacy: .public) \(text.count) chars")
        lastVoice = Date()
        speaker.speak(text, japanese: japanese)
    }

    /// 毎フレーム。喋っているあいだは吹き出しを残し、口の形を返す。
    func tick() -> [Float]? {
        let mic = micApps()
        if mic != lastMic {
            lastMic = mic
            status.micApps = Self.names(mic)
        }
        guard speaker.isSpeaking else {
            if speaker.ready, Date().timeIntervalSince(lastVoice) > Self.restAfter {
                speaker.rest()
                log.notice("voice: model resting")
            }
            return nil
        }
        lastVoice = Date()
        mascot.holdSpeech(0.3)
        return speaker.vowels
    }

    func test() {
        refresh()
        let line = SpeechLanguage.current == .japanese ? "こんにちは！今日もいっしょにがんばろうね。" : String(localized: "Hello! Let's do our best today.")
        mascot.say(line, seconds: SpeechLanguage.readingSeconds(line), voiced: enabled)
        if enabled { speaker.speak(line, japanese: SpeechLanguage.isCJK(line)) }
    }

    func quit() { models.suspendForQuit() }

    /// `com.hnc.Discord.helper.Renderer` → Discord
    private static func names(_ ids: Set<String>) -> [String] {
        let names = ids.map { id in
            let base = appBundleBase(id)
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: base)
                .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? base
        }
        return Array(Set(names)).sorted()
    }

    private static func map(_ s: VoiceModels.State) -> VoiceStatus.Model {
        switch s {
        case .missing: .missing
        case let .downloading(f): .downloading(f)
        case .installing: .installing
        case .installed: .installed
        case let .failed(m): .failed(m)
        }
    }
}

extension SettingsActions {
    @MainActor
    func withVoice(_ voice: VoiceService) -> SettingsActions {
        var a = self
        a.voice = voice.status
        a.downloadVoice = { [weak voice] in voice?.models.download() }
        a.cancelVoiceDownload = { [weak voice] in voice?.models.cancel() }
        a.deleteVoice = { [weak voice] in
            voice?.models.delete()
            voice?.refresh()
        }
        a.voiceChanged = { [weak voice] in voice?.refresh() }
        a.testVoice = { [weak voice] in voice?.test() }
        a.previewVoice = { [weak voice] in voice?.preview($0) }
        a.remakeVoice = { [weak voice] in voice?.remake($0) }
        a.previewCandidate = { [weak voice] in voice?.previewCandidate() }
        a.acceptCandidate = { [weak voice] in voice?.acceptCandidate() }
        a.discardCandidate = { [weak voice] in voice?.discardCandidate() }
        return a
    }
}
