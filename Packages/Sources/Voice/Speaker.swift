import AVFoundation
import os
import IrodoriTTS
import MascotCore

/// 吹き出しの文を声にする。日本語は IrodoriTTS（ANE）、ほかとモデルがないときは macOS の声。
/// 口の形は鳴らしている音から LipSync で出す。
@MainActor
public final class Speaker {
    public struct VoiceSpec: Equatable, Sendable {
        public var caption: String
        public var reference: URL?

        public init(caption: String, reference: URL?) {
            (self.caption, self.reference) = (caption, reference)
        }
    }

    public var volume: Float = 1 {
        didSet { player.volume = volume }
    }
    public var spec = VoiceSpec(caption: "", reference: nil)
    public private(set) var isSpeaking = false
    public var onFailure: ((String) -> Void)?
    public var onReady: (() -> Void)?

    nonisolated static let rate = 48_000.0
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    private var tts: IrodoriTTS?
    private var loading: Task<IrodoriTTS?, Never>?
    private var loadedFrom: URL?
    /// `rest` で外したモデルの場所。次に日本語を喋るとき読みなおす。
    private var restingFrom: URL?
    /// 休みから読みなおしている読み込み（喋る側はこれを待つ）。
    private var waking: Task<IrodoriTTS?, Never>?
    private var voice: (spec: VoiceSpec, voice: Voice)?
    private var current: Task<Void, Never>?
    private let system = AVSpeechSynthesizer()

    private var lips = LipSync()
    private var lipTimeline: [[Float]] = []
    private var pending16k: [Float] = []
    private var scheduled = 0
    private var played = 0
    /// 止めた発話のバッファの終わりの知らせ（player.stop で遅れて届く）を、次の発話の played に数えないため
    private var generation = 0
    static let lipHop = 256

    public init() {
        engine.attach(player)
        try? engine.connectNode(player, to: engine.mainMixerNode, format: format)
    }

    /// モデルを裏で読む。初回は端末向けの特殊化で 1 分ほどかかる。
    /// 休んでいるときは読まない（次に喋るときに読む）。
    public func load(from directory: URL) {
        guard loadedFrom != directory, restingFrom != directory else { return }
        startLoad(directory)
    }

    private func startLoad(_ directory: URL) {
        loadedFrom = directory
        let wake = restingFrom != nil
        restingFrom = nil
        loading = Task {
            do {
                let began = Date()
                let tts = try await IrodoriTTS(modelDirectory: directory)
                // 読み込み直後の 1 回目の合成は声が参照どおりにならないことがあるので、鳴らさずに 1 回回しておく
                if let v = try? await self.currentVoice(tts) { _ = try? await tts.synthesize("あ", voice: v) }
                Logger(subsystem: "app.ringomate", category: "voice")
                    .notice("voice: model loaded in \(Date().timeIntervalSince(began), format: .fixed(precision: 2), privacy: .public) s")
                self.tts = tts
                self.onReady?()
                return tts
            } catch {
                self.onFailure?(error.localizedDescription)
                self.loadedFrom = nil
                return nil
            }
        }
        if wake { waking = loading }
    }

    public func unload() {
        stop()
        loading?.cancel()
        (tts, loading, loadedFrom, voice, restingFrom, waking) = (nil, nil, nil, nil, nil, nil)
    }

    /// 喋っていなければモデルを外してメモリを空ける。次に日本語を喋るとき読みなおす（キャッシュがあれば 1 秒ほど）。
    public func rest() {
        guard tts != nil, !isSpeaking, let directory = loadedFrom else { return }
        (tts, loading, loadedFrom, voice, waking) = (nil, nil, nil, nil, nil)
        restingFrom = directory
    }

    public var ready: Bool { tts != nil }
    /// 読み込み済みか、休んでいて次に読みなおせる。
    public var available: Bool { tts != nil || restingFrom != nil }

    /// 休んでいたら読みなおして待つ。初めての読み込みの途中では待たない（そのあいだは macOS の声）。
    private func awake() async -> IrodoriTTS? {
        if let tts { return tts }
        if let restingFrom { startLoad(restingFrom) }
        return await waking?.value
    }

    /// 参照のファイルを同じパスで差し替えたとき。
    public func invalidateVoice() { voice = nil }

    /// 声の見本（参照の録音にする 8 秒ほどの文）。キャプションだけから毎回違う声が出る。
    public func makeSample(caption: String) async throws -> [Float] {
        let ready = await awake()
        guard let tts = ready != nil ? ready : await loading?.value else { throw CocoaError(.fileReadNoSuchFile) }
        let v = try await tts.voice(caption: caption)
        return try await tts.synthesize(Self.sampleLine, voice: v, seed: .random(in: .min ... .max))
    }

    static let sampleLine = "こんにちは。今日もいっしょにがんばろうね。わからないことがあったら、なんでも聞いてね。"

    /// 見本などの音をそのまま鳴らす（口も動く）。
    public func play(samples: [Float]) {
        stop()
        isSpeaking = true
        current = Task {
            defer { if !Task.isCancelled { finish() } }
            guard !Task.isCancelled else { return }
            play(samples)
            await waitForPlayback()
        }
    }

    /// 今の発話を止めて `text` を喋る。`japanese` なら IrodoriTTS（読み込み済みのとき）。
    public func speak(_ text: String, japanese: Bool) {
        stop()
        isSpeaking = true
        current = Task {
            defer { if !Task.isCancelled { finish() } }
            do {
                if japanese, let tts = await awake() {
                    try await speakIrodori(text, tts)
                } else {
                    try await speakSystem(text, language: japanese ? "ja-JP" : "en-US")
                }
                await waitForPlayback()
            } catch is CancellationError {
            } catch {
                self.onFailure?(error.localizedDescription)
            }
        }
    }

    public func stop() {
        current?.cancel()
        current = nil
        player.stop()
        finish()
    }

    /// 鳴っている位置の母音の重み（あ・い・う・え・お）。喋っていないときは nil。
    public var vowels: [Float]? {
        guard isSpeaking else { return nil }
        guard let node = player.lastRenderTime, node.isSampleTimeValid,
              let t = player.playerTime(forNodeTime: node), t.sampleTime >= 0 else { return [0, 0, 0, 0, 0] }
        let i = Int(Double(t.sampleTime) / Self.rate * LipSync.rate) / Self.lipHop
        return i < lipTimeline.count ? lipTimeline[i] : [0, 0, 0, 0, 0]
    }

    // MARK: -

    private func speakIrodori(_ text: String, _ tts: IrodoriTTS) async throws {
        let v = try await currentVoice(tts)
        for try await chunk in tts.speak(text, voice: v) {
            try Task.checkCancellation()
            play(chunk)
        }
    }

    private func currentVoice(_ tts: IrodoriTTS) async throws -> Voice {
        if let voice, voice.spec == spec { return voice.voice }
        // 見本の声（voice/<種類>.wav）なら名前、ユーザーの録音なら user file とだけ出す
        let from = spec.reference.map { $0.deletingLastPathComponent().lastPathComponent == "voice" ? $0.lastPathComponent : "user file" } ?? "caption only"
        let chars = spec.caption.count
        Logger(subsystem: "app.ringomate", category: "voice").info("voice: new voice from \(from, privacy: .public) caption \(chars) chars")
        let made = try await tts.voice(caption: spec.caption, reference: spec.reference)
        voice = (spec, made)
        return made
    }

    private func speakSystem(_ text: String, language: String) async throws {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        let chunks = AsyncStream<[Float]> { continuation in
            system.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    continuation.finish()
                    return
                }
                continuation.yield((try? Self.mono48k(pcm)) ?? [])
            }
        }
        for await chunk in chunks {
            try Task.checkCancellation()
            play(chunk)
        }
    }

    private func play(_ samples: [Float]) {
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if !engine.isRunning { try? engine.start() }
        let gen = generation
        player.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.played += samples.count
            }
        }
        scheduled += samples.count
        if !player.isPlaying { try? player.playAudio() }
        addLips(samples)
    }

    private func addLips(_ samples: [Float]) {
        pending16k += Self.decimate(samples)
        let window = LipSync.window
        while pending16k.count >= window {
            lipTimeline.append(lips.vowels(pending16k[0..<window]))
            pending16k.removeFirst(Self.lipHop)
        }
    }

    private func waitForPlayback() async {
        while played < scheduled, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private func finish() {
        generation += 1
        isSpeaking = false
        (lipTimeline, pending16k, scheduled, played) = ([], [], 0, 0)
        lips = LipSync()
        if engine.isRunning { engine.pause() }
    }

    /// 48kHz → 16kHz（3 つの平均）。
    nonisolated static func decimate(_ x: [Float]) -> [Float] {
        stride(from: 0, to: x.count - 2, by: 3).map { (x[$0] + x[$0 + 1] + x[$0 + 2]) / 3 }
    }

    nonisolated static func mono48k(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let target = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard let converter = AVAudioConverter(from: buffer.format, to: target),
              let out = AVAudioPCMBuffer(pcmFormat: target,
                                         frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * rate / buffer.format.sampleRate) + 64)
        else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// 48kHz モノラルの WAV で書く。
    public static func save(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        guard !samples.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CocoaError(.fileWriteUnknown) }
        buffer.frameLength = buffer.frameCapacity
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        do {  // 閉じたときにヘッダが書かれる
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
    }

    /// 48kHz モノラルで読む。
    public static func load(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        return try mono48k(buffer)
    }
}
