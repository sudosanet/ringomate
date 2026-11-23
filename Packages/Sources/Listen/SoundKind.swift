import MascotCore
import AVFoundation
import Foundation
import SoundAnalysis

/// 0〜1、合計は 1 にならない。
public struct SoundScores: Sendable, Equatable {
    public var music: Float
    public var singing: Float
    public var speech: Float

    public var isMusic: Bool { max(music, singing) > 0.35 && max(music, singing) > speech * 0.8 }
}

// 端末の中だけ。`feed` は拍の推定と同じ直列のキューから、`current` はどのスレッドからでも呼ぶ
final class SoundKind: NSObject, SNResultsObserving, @unchecked Sendable {
    private let analyzer: SNAudioStreamAnalyzer?
    private let format: AVAudioFormat?
    private var frame: AVAudioFramePosition = 0
    private let lock = NSLock()
    private var scores: SoundScores?
    private var eventLevels: [SoundEvent: Float] = [:]
    private var events: [SoundEvent] = []

    init(rate: Double) {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
        let analyzer = format.map { SNAudioStreamAnalyzer(format: $0) }
        self.format = format
        self.analyzer = analyzer
        super.init()
        guard let analyzer, let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return }
        request.overlapFactor = 0.5
        try? analyzer.add(request, withObserver: self)
    }

    var current: SoundScores? {
        lock.lock()
        defer { lock.unlock() }
        return scores
    }

    func takeEvents() -> [SoundEvent] {
        lock.lock()
        defer { lock.unlock() }
        let e = events
        events.removeAll()
        return e
    }

    func feed(_ samples: [Float]) {
        guard let analyzer, let format, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        analyzer.analyze(buffer, atAudioFramePosition: frame)
        frame += AVAudioFramePosition(samples.count)
    }

    func reset() {
        lock.lock()
        scores = nil
        eventLevels.removeAll()
        events.removeAll()
        lock.unlock()
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        let c = { (ids: [String]) in ids.map { Float(r.classification(forIdentifier: $0)?.confidence ?? 0) }.max() ?? 0 }
        let s = SoundScores(music: c(["music"]), singing: c(["singing", "choir_singing", "rapping", "humming"]),
                       speech: c(["speech", "conversation", "narration_monologue"]))
        lock.lock()
        scores = s
        for e in SoundEvent.allCases {
            let level = c(e.identifiers)
            if SoundEvent.began(previous: eventLevels[e] ?? 0, now: level), !events.contains(e) { events.append(e) }
            eventLevels[e] = level
        }
        lock.unlock()
    }
}
