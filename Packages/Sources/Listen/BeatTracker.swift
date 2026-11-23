import MascotCore
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Mac から出ている音のテンポと拍を推定する。音は録音も保存もしない。
public final class BeatTracker: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// 時刻はホストの時計の秒。
    public struct Estimate: Sendable, Equatable {
        public var bpm: Float
        public var lastBeat: Double
        public var confidence: Float
        public var loudness: Float

        public init(bpm: Float, lastBeat: Double, confidence: Float, loudness: Float) {
            (self.bpm, self.lastBeat, self.confidence, self.loudness) = (bpm, lastBeat, confidence, loudness)
        }

        /// 0 が拍の頭。
        public func phase(at now: Double) -> Float {
            Float(((now - lastBeat) * Double(bpm) / 60).truncatingRemainder(dividingBy: 1) + 1)
                .truncatingRemainder(dividingBy: 1)
        }
    }

    let lock = NSLock()
    var estimate: Estimate?
    var stream: SCStream?
    var starting = false
    /// `stop` のあとに届いた `startCapture` の完了を捨てるため
    var wanted = false
    let queue = DispatchQueue(label: "ringomate.beat", qos: .userInitiated)

    static let hop = 512
    public static let rate = 24_000.0
    static var frameRate: Double { rate / Double(hop) }
    var onsets: [Float] = []
    var lastTime = 0.0
    var pending: [Float] = []
    var low: Float = 0
    var previous: (low: Float, full: Float) = (0, 0)
    var rms: Float = 0
    var sinceEstimate = 0
    var soundHeard = false
    var quietHops = 0
    static let quietPeak: Float = 0.0056
    var quietSeconds = 0.0
    var resting = false
    var locked: Float?
    var lastSound = 0.0
    var candidate: (lag: Float, count: Int)?

    /// `useModel: false` で手作りの推定だけにする。
    public init(useModel: Bool = true) {
        self.useModel = useModel
        installedModel = useModel ? BeatModel() : nil
        super.init()
    }

    static let rawCapacity = Int(rate * 16)
    var raw: [Float] = []
    var rawHead = 0
    var rawFilled = 0
    var rawEnd = 0.0

    /// 生の音は直近 16 秒だけ持つ（保存しない）。
    /// `recentAudio` が値を返すか（コピーしない）。
    public func hasRecentAudio(seconds: Double) -> Bool {
        lock.withLock { Int(Self.rate * seconds) <= rawFilled }
    }

    public func recentAudio(seconds: Double) -> (samples: [Float], end: Double)? {
        lock.withLock {
            let n = Int(Self.rate * seconds)
            guard n <= rawFilled else { return nil }
            let start = (rawHead - n + Self.rawCapacity) % Self.rawCapacity
            let out = start + n <= Self.rawCapacity ? Array(raw[start..<(start + n)])
                : Array(raw[start...] + raw[..<(start + n - Self.rawCapacity)])
            return (out, rawEnd)
        }
    }

    public var current: Estimate? {
        lock.lock()
        defer { lock.unlock() }
        return estimate
    }

    /// 聞こえたことがなければ無限大。
    public func silence(at now: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return lastSound > 0 ? now - lastSound : .infinity
    }

    public var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stream != nil || starting
    }

    let kind = SoundKind(rate: BeatTracker.rate)
    let useModel: Bool
    /// 差し替えは `queue` の上で lock を取って行う
    var installedModel: BeatModel?
    var releasedStatus: ModelStatus?
    var model: BeatModel? { installedModel?.failed == true ? nil : installedModel }
    public var modelStatus: ModelStatus {
        lock.lock()
        defer { lock.unlock() }
        if let releasedStatus { return releasedStatus }
        guard let installedModel else { return .missing }
        return installedModel.failed ? .failed : .installed
    }

    /// モデルを外してメモリを空ける。次の `start` で読みなおす
    public func releaseModel() {
        queue.async { [self] in
            let status = modelStatus
            lock.withLock { (releasedStatus, installedModel) = (status, nil) }
        }
    }
    var section = SectionTracker()
    var lowOnsets: [Float] = []
    var onsetGrid: BarGrid?
    var barState: (grid: BarGrid, section: Int, intensity: Float, barsSince: Int)?

    var noveltyDebug: (Float, Float) = (0, 0)
    public var novelty: (last: Float, usual: Float) {
        lock.lock()
        defer { lock.unlock() }
        return noveltyDebug
    }

    public var bar: (grid: BarGrid, section: Int, intensity: Float, barsSince: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return barState
    }

    public var sound: SoundScores? { kind.current }
    /// 取り出すと空になる。
    public func takeSoundEvents() -> [SoundEvent] { kind.takeEvents() }

    var excluded: Set<String> = []

    /// マイクを使っているアプリの音を聞かない。聞いている途中でも差し替える。
    public func exclude(_ ids: Set<String>) {
        lock.lock()
        let changed = ids != excluded
        excluded = ids
        let s = stream
        lock.unlock()
        guard changed, let s else { return }
        SCShareableContent.getWithCompletionHandler { [weak self] content, _ in
            guard let self, let content, let display = content.displays.first else { return }
            s.updateContentFilter(self.filter(display: display, content: content)) { _ in }
        }
    }

    func filter(display: SCDisplay, content: SCShareableContent) -> SCContentFilter {
        lock.lock()
        let bases = excluded.map(appBundleBase)
        lock.unlock()
        let apps = content.applications.filter { app in
            bases.contains { app.bundleIdentifier.hasPrefix($0) || $0.hasPrefix(app.bundleIdentifier) && !app.bundleIdentifier.isEmpty }
        }
        return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
    }

    public func start() {
        lock.lock()
        wanted = true
        guard stream == nil, !starting else { return lock.unlock() }
        starting = true
        lock.unlock()
        queue.async { [self] in
            guard installedModel == nil, useModel else { return }
            let m = BeatModel()
            lock.withLock { (installedModel, releasedStatus) = (m, nil) }
        }
        SCShareableContent.getWithCompletionHandler { [weak self] content, _ in
            guard let self else { return }
            guard let content, let display = content.displays.first else {
                self.lock.lock()
                self.starting = false
                self.lock.unlock()
                return
            }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(Self.rate)
            // 1 チャンネルを頼むと左だけが届くので、2 チャンネルを mono() で平均する
            config.channelCount = 2
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
            let filter = self.filter(display: display, content: content)
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
            } catch {
                self.lock.lock()
                self.starting = false
                self.lock.unlock()
                return
            }
            s.startCapture { [weak self] error in
                guard let self else { return }
                self.lock.lock()
                self.starting = false
                let keep = error == nil && self.wanted
                self.stream = keep ? s : nil
                self.lock.unlock()
                if error == nil, !keep { s.stopCapture { _ in } }
            }
        }
    }

    public func stop() {
        lock.lock()
        wanted = false
        let s = stream
        stream = nil
        estimate = nil
        lock.unlock()
        s?.stopCapture { _ in }
        kind.reset()
        lock.lock()
        barState = nil
        raw.removeAll()
        (rawHead, rawFilled) = (0, 0)
        lock.unlock()
        queue.async { [weak self] in
            self?.model?.reset()
            self?.section.reset()
            self?.lowOnsets.removeAll()
            self?.onsetGrid = nil
            self?.stableGrid = nil
            self?.pendingMeter = nil
            self?.pendingShift = nil
            self?.onsets.removeAll()
            self?.pending.removeAll()
            self?.locked = nil
            self?.candidate = nil
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        self.stream = nil
        estimate = nil
        lock.unlock()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let samples = Self.mono(buffer) else { return }
        let end = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)) + Double(samples.count) / Self.rate
        process(samples, end: end)
    }

    func process(_ samples: [Float], end: Double) {
        quietSeconds = samples.contains { abs($0) >= Self.quietPeak } ? 0 : quietSeconds + Double(samples.count) / Self.rate
        if (quietSeconds > 5) != resting {
            resting.toggle()
            if resting { installedModel?.reset() }
        }
        if !resting { kind.feed(samples) }
        lock.withLock {
            if raw.count < Self.rawCapacity { raw = [Float](repeating: 0, count: Self.rawCapacity) }
            for v in samples {
                raw[rawHead] = v
                rawHead = (rawHead + 1) % Self.rawCapacity
            }
            rawFilled = min(rawFilled + samples.count, Self.rawCapacity)
            rawEnd = end
        }
        if let model, !resting {
            for row in model.feed(samples, rate: Self.rate, end: end) {
                let bands = stride(from: 0, to: row.count, by: 8).map { i in row[i..<min(i + 8, row.count)].reduce(0, +) / 8 }
                section.push(bands, loud: row.reduce(0, +) / Float(row.count))
            }
        }
        pending += samples
        let hops = pending.count / Self.hop
        guard hops > 0 else { return }
        for k in 0..<hops {
            feed(pending[(k * Self.hop)..<((k + 1) * Self.hop)])
        }
        pending.removeFirst(hops * Self.hop)
        lastTime = end - Double(pending.count) / Self.rate
        if soundHeard {
            soundHeard = false
            lock.lock()
            lastSound = lastTime
            lock.unlock()
        }
        sinceEstimate += hops
        let raw = model != nil ? model?.current.flatMap { lastTime - $0.lastBeat < 20 ? $0 : nil } : onsetGrid
        let grid = stabilize(raw)
        section.update(grid: grid, now: lastTime)
        lock.lock()
        barState = grid.map { ($0, section.index, section.intensity, section.barsSince) }
        noveltyDebug = (section.lastNovelty, section.lastUsual)
        lock.unlock()
        if sinceEstimate >= Int(Self.frameRate / 2), quietHops <= Int(Self.frameRate) {
            sinceEstimate = 0
            let e = estimateTempo()
            lock.lock()
            estimate = e
            lock.unlock()
        }
    }

    func feed(_ chunk: ArraySlice<Float>) {
        var peak: Float = 0
        for x in chunk { peak = max(peak, abs(x)) }
        if peak < Self.quietPeak {
            quietHops += 1
            if quietHops > Int(Self.frameRate) {
                if !onsets.isEmpty { onsets.removeAll(keepingCapacity: true) }
                if !lowOnsets.isEmpty { lowOnsets.removeAll(keepingCapacity: true) }
                return
            }
        } else {
            quietHops = 0
        }
        let a = Float(exp(-2 * Double.pi * 150 / Self.rate))
        var eLow: Float = 0, eFull: Float = 0
        for x in chunk {
            low = a * low + (1 - a) * x
            eLow += low * low
            eFull += x * x
        }
        let n = Float(chunk.count)
        if eFull / n > 1e-4 { soundHeard = true }
        let (l, f) = (log1p(eLow / n * 1e4), log1p(eFull / n * 1e4))
        let onset = max(0, l - previous.low) + 0.5 * max(0, f - previous.full)
        lowOnsets.append(max(0, l - previous.low))
        if model == nil { section.push([l, f], loud: f) }
        previous = (l, f)
        rms += (sqrt(eFull / n) - rms) * 0.05
        onsets.append(onset)
        let keep = Int(Self.frameRate * 8)
        if onsets.count > keep { onsets.removeFirst(onsets.count - keep) }
        if lowOnsets.count > keep { lowOnsets.removeFirst(lowOnsets.count - keep) }
    }

    var stableGrid: BarGrid?
    var lastRawBeat = 0.0
    var pendingMeter: (meter: Int, count: Int)?
    var pendingShift: (beats: Int, count: Int)?

    /// `Estimate.lastBeat` と同じホストの時計の秒。
    public static func now() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
}
