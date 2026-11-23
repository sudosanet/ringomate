import MascotCore
import Foundation
import os

/// `BeatTracker` の推定から毎フレームの拍を刻み、推定へゆっくり寄せる（PLL）。
@MainActor
public final class BeatClock {
    private let tracker: BeatTracker
    private let log = Logger(subsystem: "app.ringomate", category: "app")
    private var clock: (phase: Float, bpm: Float, at: Double)?
    private var goodBeat: (estimate: BeatTracker.Estimate, at: Date)?
    private var musicUntil = Date.distantPast
    private var lastAudio = Date.distantPast
    private var loggedDownbeat = 0.0
    private var firstDownbeat: Double?

    public init(tracker: BeatTracker) {
        self.tracker = tracker
    }

    /// マイクを使っているアプリの音は聞かない。
    public func listen(allowed: Bool, audioPlaying: Bool, micApps: Set<String>, now: Date = Date()) {
        if audioPlaying { lastAudio = now }
        tracker.exclude(micApps)
        if allowed, audioPlaying, !tracker.running {
            tracker.start()
        } else if tracker.running, !allowed || now.timeIntervalSince(lastAudio) > 15 {
            tracker.stop()
        }
    }

    public func beat(now: Date = Date()) -> Beat? {
        if tracker.sound?.isMusic == true { musicUntil = now.addingTimeInterval(6) }
        if now < musicUntil, let bar = tracker.bar, bar.grid.source == .model, bar.grid.confidence >= 0.5,
           BeatTracker.now() - bar.grid.lastBeat < 4 {
            let g = bar.grid
            var e = BeatTracker.Estimate(bpm: Float(60 / g.period), lastBeat: g.lastBeat, confidence: g.confidence,
                                         loudness: tracker.current?.loudness ?? 0.5)
            if let p = goodBeat?.estimate, abs(e.bpm - p.bpm) / p.bpm < 0.04 { e.bpm = p.bpm * 0.8 + e.bpm * 0.2 }
            goodBeat = (e, now)
        } else if now < musicUntil, let e = tracker.current, e.confidence > 0.2, e.loudness > 0.1 {
            var e = e
            if let g = goodBeat?.estimate, abs(e.bpm - g.bpm) / g.bpm < 0.04 { e.bpm = g.bpm * 0.8 + e.bpm * 0.2 }
            goodBeat = (e, now)
        }
        guard let (e, at) = goodBeat, now.timeIntervalSince(at) < 20, now < musicUntil,
              tracker.silence(at: BeatTracker.now()) < 1
        else {
            clock = nil
            return nil
        }
        let t = BeatTracker.now()
        let target = e.phase(at: t)
        var c = clock ?? (phase: target, bpm: e.bpm, at: t)
        let dt = Float(max(0, min(0.1, t - c.at)))
        c.bpm += (e.bpm - c.bpm) * min(1, dt * 0.5)
        c.phase += dt * c.bpm / 60
        let err = (target - c.phase + 1.5).truncatingRemainder(dividingBy: 1) - 0.5
        c.phase = (c.phase + err * min(1, dt * 1.5) + 1).truncatingRemainder(dividingBy: 1)
        c.at = t
        clock = c
        var beat = Beat(bpm: c.bpm, phase: c.phase, energy: min(1, e.confidence * 0.6 + e.loudness * 0.6))
        if let bar = tracker.bar {
            let g = bar.grid
            if g.lastDownbeat != loggedDownbeat {
                loggedDownbeat = g.lastDownbeat
                let ref = firstDownbeat ?? g.lastDownbeat
                if firstDownbeat == nil { firstDownbeat = ref }
                let slot = ((Int(((g.lastDownbeat - ref) / g.period).rounded()) % g.meter) + g.meter) % g.meter
                let n = tracker.novelty
                log.info("barlog \(g.source.rawValue, privacy: .public) \(String(format: "%.1f", 60 / g.period), privacy: .public) bpm meter \(g.meter) downbeat slot \(slot) conf \(String(format: "%.2f", g.confidence), privacy: .public) section \(bar.section) bars \(bar.barsSince) novelty \(String(format: "%.3f/%.3f", n.last, n.usual), privacy: .public) intensity \(String(format: "%.2f", bar.intensity), privacy: .public)")
            }
            let start = t - Double(c.phase) * g.period
            let index = Int(((start - g.lastDownbeat) / g.period).rounded())
            beat.beatInBar = ((index % g.meter) + g.meter) % g.meter
            (beat.meter, beat.section, beat.intensity) = (g.meter, bar.section, bar.intensity)
        }
        return beat
    }
}

extension Beat {
    /// 描くのが 1 フレーム遅れるぶん先へ進めて渡す。
    public func advanced(by seconds: Float) -> Beat {
        var b = self
        let ahead = phase + bpm / 60 * seconds
        if ahead >= 1, let i = beatInBar { b.beatInBar = (i + 1) % max(meter, 1) }
        b.phase = ahead.truncatingRemainder(dividingBy: 1)
        return b
    }
}
