import MascotCore
import Foundation
import os

/// 曲の雰囲気を 20 秒おきに当てる。結果は 40 秒で古くなる。
@MainActor
public final class MusicMoodListener {
    private let tracker: BeatTracker
    private var model: MusicMoodModel?
    private var released = false
    public let status: ModelStatus
    private let log = Logger(subsystem: "app.ringomate", category: "mood")
    private var busy = false
    private var lastRun = Date.distantPast
    private var result: (mood: MusicMood?, at: Date)?

    public init(tracker: BeatTracker) {
        self.tracker = tracker
        model = MusicMoodModel()
        status = model == nil ? .missing : .installed
    }

    /// モデルを外してメモリを空ける。次の `current` で読みなおす
    public func releaseModel() {
        (model, released, result) = (nil, true, nil)
    }

    /// 毎フレーム呼んでよい。
    public func current(now: Date = Date()) -> MusicMood? {
        if released {
            (model, released) = (MusicMoodModel(), false)
        }
        if let model, !busy, tracker.sound?.isMusic == true, now.timeIntervalSince(lastRun) > 20,
           let audio = tracker.recentAudio(seconds: 10) {
            busy = true
            lastRun = now
            Task.detached(priority: .utility) { [weak self] in
                let mel = model.logMel(Self.upsample(audio.samples))
                let cos = await model.embed(logMel: mel).map { model.cosines($0) }
                await self?.finish(cos, labels: model.labels)
            }
        }
        guard let result, now.timeIntervalSince(result.at) < 40 else { return nil }
        return result.mood
    }

    private func finish(_ cosines: [Float]?, labels: [String]) {
        busy = false
        guard let cosines else { return }
        let best = cosines.indices.max { cosines[$0] < cosines[$1] }!
        let mood = MusicMood(rawValue: labels[best])
        result = (mood, Date())
        log.info("mood \(labels[best], privacy: .public) \(zip(labels, cosines).map { "\($0)=\(String(format: "%.3f", $1))" }.joined(separator: " "), privacy: .public)")
    }

    nonisolated static func upsample(_ x: [Float]) -> [Float] {
        let n = MusicMoodModel.samples
        let src = Array(x.suffix(n / 2))
        var out = [Float](repeating: 0, count: n)
        let offset = n - src.count * 2
        for (i, v) in src.enumerated() {
            let next = i + 1 < src.count ? src[i + 1] : v
            out[offset + 2 * i] = v
            out[offset + 2 * i + 1] = (v + next) / 2
        }
        return out
    }
}
