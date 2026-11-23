import AVFoundation
import Foundation
import Testing
@testable import Listen
import MascotCore

@Test func estimatesTempoAndBeatOfClicks() {
    for bpm in [96.0, 128.0, 150.0] {
        let t = BeatTracker()
        let rate = BeatTracker.rate
        let seconds = 10.0
        var samples = [Float](repeating: 0, count: Int(rate * seconds))
        let period = 60 / bpm
        var beat = 0.0
        while beat < seconds {
            let start = Int(beat * rate)
            for i in 0..<min(Int(rate * 0.05), samples.count - start) {
                let x = Double(i) / rate
                samples[start + i] += Float(sin(2 * .pi * 60 * x) * exp(-x * 40))
            }
            beat += period
        }
        var k = 0
        while k < samples.count {
            let chunk = Array(samples[k..<min(k + 512, samples.count)])
            k += chunk.count
            t.process(chunk, end: Double(k) / rate)
        }
        guard let e = t.current else { Issue.record("no estimate at \(bpm)"); continue }
        #expect(abs(Double(e.bpm) - bpm) / bpm < 0.03, "\(bpm) → \(e.bpm)")
        let truth = (seconds / period).truncatingRemainder(dividingBy: 1)
        var d = abs(Double(e.phase(at: seconds)) - truth)
        d = min(d, 1 - d)
        #expect(d < 0.15, "\(bpm): phase off by \(d)")
    }
}

@Test func keepsTheTempoWhenOffbeatsAppear() {
    let t = BeatTracker()
    let rate = BeatTracker.rate, bpm = 110.0, period = 60 / bpm
    var samples = [Float](repeating: 0, count: Int(rate * 16))
    var beat = 0.0
    while beat < 16 {
        let start = Int(beat * rate)
        for i in 0..<min(Int(rate * 0.05), samples.count - start) {
            let x = Double(i) / rate
            samples[start + i] += Float(sin(2 * .pi * 60 * x) * exp(-x * 40))
        }
        if beat > 8 {
            let off = Int((beat + period / 2) * rate)
            for i in 0..<min(Int(rate * 0.0125), max(0, samples.count - off)) {
                samples[off + i] += Float(sin(2 * .pi * 5000 * Double(i) / rate) * exp(-Double(i) / rate * 200)) * 0.8
            }
        }
        beat += period
    }
    var k = 0, seen: [Float] = []
    while k < samples.count {
        let chunk = Array(samples[k..<min(k + 512, samples.count)])
        k += chunk.count
        t.process(chunk, end: Double(k) / rate)
        if k % (512 * 24) == 0, let e = t.current { seen.append(e.bpm) }
    }
    let late = seen.suffix(10)
    #expect(late.allSatisfy { abs(Double($0) - bpm) / bpm < 0.04 }, "\(late)")
}

@Test func noticesSilenceQuickly() {
    let t = BeatTracker()
    let rate = BeatTracker.rate
    var k = 0
    while k < Int(rate * 5) {
        let chunk = (0..<512).map { i -> Float in k + i < Int(rate * 3) ? Float(sin(Double(k + i) * 0.05)) * 0.5 : 0 }
        k += chunk.count
        t.process(chunk, end: Double(k) / rate)
    }
    let s = t.silence(at: Double(k) / rate)
    #expect(s > 1.9 && s < 2.1, "\(s)")
}

@Test func tellsMusicFromSpeech() throws {
    let rate = BeatTracker.rate
    func run(_ samples: [Float]) -> SoundScores? {
        let t = BeatTracker()
        var k = 0
        while k < samples.count {
            let chunk = Array(samples[k..<min(k + 512, samples.count)])
            k += chunk.count
            t.process(chunk, end: Double(k) / rate)
        }
        for _ in 0..<50 where t.sound == nil { Thread.sleep(forTimeInterval: 0.05) }
        return t.sound
    }
    let n = Int(rate * 8)
    var music = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / rate, beat = t.truncatingRemainder(dividingBy: 0.5)
        var y = sin(2 * .pi * (60 + 80 * exp(-beat * 30)) * beat) * exp(-beat * 20) * 0.6
        let chord = [[261.6, 329.6, 392.0], [220, 261.6, 329.6], [174.6, 220, 261.6], [196, 246.9, 293.7]][Int(t) % 4]
        let bar = t.truncatingRemainder(dividingBy: 1)
        for f in chord { y += 0.1 * sin(2 * .pi * f * t) * exp(-bar * 1.5) }
        music[i] = Float(y * 0.8)
    }
    let m = try #require(run(music))
    #expect(m.isMusic, "music \(m)")
    let url = FileManager.default.temporaryDirectory.appending(path: "ringomate-speech-\(UUID()).wav")
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/say")
    p.arguments = ["-o", url.path, "--file-format=WAVE", "--data-format=LEF32@24000", "今日の会議では、来週のリリースの予定と、テストの進み具合について確認します。まず最初に、先週の課題から見ていきましょう。"]
    try p.run()
    p.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let speech = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    let s = try #require(run(speech))
    #expect(!s.isMusic, "speech \(s)")
}

@Test func survivesABrokenLockedTempo() {
    let rate = BeatTracker.rate
    for bad: Float in [1000, -50, 0, 3] {
        let t = BeatTracker()
        t.locked = bad
        var seed: UInt32 = 12345
        var samples = [Float](repeating: 0, count: Int(rate * 6))
        for i in samples.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            samples[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * (i % 9000 < 4500 ? 0.4 : 0.01)
        }
        var k = 0
        while k < samples.count {
            let chunk = Array(samples[k..<min(k + 512, samples.count)])
            k += chunk.count
            t.process(chunk, end: Double(k) / rate)
        }
        if let e = t.current { #expect(e.bpm.isFinite && e.bpm >= 60 && e.bpm <= 200, "bpm \(e.bpm) from locked \(bad)") }
    }
}

@Test func accentsGiveMeterAndDownbeat() {
    for (meter, bpm) in [(4, 120.0), (3, 100.0)] {
        let t = BeatTracker(useModel: false)
        let rate = BeatTracker.rate, seconds = 12.0
        var samples = [Float](repeating: 0, count: Int(rate * seconds))
        let period = 60 / bpm
        var k = 0
        while Double(k) * period < seconds {
            let start = Int(Double(k) * period * rate)
            let amp: Float = k % meter == 0 ? 1 : 0.3
            for i in 0..<min(Int(rate * 0.06), samples.count - start) {
                let x = Double(i) / rate
                samples[start + i] += amp * Float(sin(2 * .pi * 60 * x) * exp(-x * 40))
            }
            k += 1
        }
        var n = 0
        while n < samples.count {
            let chunk = Array(samples[n..<min(n + 512, samples.count)])
            n += chunk.count
            t.process(chunk, end: Double(n) / rate)
        }
        guard let bar = t.bar else { Issue.record("no bar at meter \(meter)"); continue }
        #expect(bar.grid.meter == meter, "meter \(bar.grid.meter) for \(meter)")
        let barLength = period * Double(meter)
        var d = bar.grid.lastDownbeat.truncatingRemainder(dividingBy: barLength)
        d = min(d, barLength - d)
        #expect(d < period * 0.25, "downbeat off by \(d) s at meter \(meter)")
    }
}

@Test func sectionChangeIsDetected() {
    var s = SectionTracker()
    let grid = BarGrid(period: 0.5, lastBeat: 0, lastDownbeat: 0, meter: 4, confidence: 1, source: .model)
    var t = 0.0
    var changedAt: Int?
    var bar = 0
    while t < 32 {
        let loud: Float = t < 16 ? 0.2 : 1.0
        let f: [Float] = t < 16 ? [0.2, 0.1, 0.3] : [1.0, 0.9, 0.2]
        let wobble = Float(sin(t * 7)) * 0.02
        s.push(f.map { $0 + wobble }, loud: loud + wobble)
        if s.update(grid: grid, now: t) {
            bar += 1
            if s.index > 0, changedAt == nil { changedAt = bar }
        }
        t += 0.02
    }
    #expect(s.index >= 1)
    #expect(changedAt.map { $0 >= 8 && $0 <= 11 } == true, "changed at bar \(changedAt ?? -1)")
    #expect(s.intensity > 0.8)
}

@Test func beatModelMatchesPythonAndFindsDownbeats() async throws {
    let dir = BeatModel.directory
    guard let model = BeatModel(directory: dir),
          let wave = try? Data(contentsOf: dir.appending(path: "reference-four.wav.bin")),
          let mel = try? Data(contentsOf: dir.appending(path: "reference-four.mel.bin")) else { return }
    let y = wave.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let ref = mel.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let padded = Array(y[1...512].reversed()) + y + Array(y[(y.count - 513)..<(y.count - 1)].reversed())
    var worst: Float = 0
    for k in stride(from: 0, to: ref.count / 128, by: 37) {
        let row = model.melFrame(padded[(k * 441)..<(k * 441 + 1024)])
        for m in 0..<128 { worst = max(worst, abs(row[m] - ref[k * 128 + m])) }
    }
    #expect(worst < 0.01, "mel differs by \(worst)")
    let rows = (0..<(ref.count / 128)).map { Array(ref[($0 * 128)..<($0 * 128 + 128)]) }
    let last = Array(rows.suffix(750))
    let times = (0..<last.count).map { Double(rows.count - last.count + $0) / 50 }
    let g = try #require(await model.infer(rows: last, times: times))
    let start = Date()
    for _ in 0..<10 { _ = await model.infer(rows: last, times: times) }
    print("Beat This: \(Int(Date().timeIntervalSince(start) * 100)) ms per 15 s")
    #expect(g.meter == 4)
    #expect(abs(g.period - 0.5) < 0.03, "period \(g.period)")
    var d = g.lastDownbeat.truncatingRemainder(dividingBy: 2)
    d = min(d, 2 - d)
    #expect(d < 0.1, "downbeat off by \(d)")
}

@Test func streamingFindsBarsWithTheModel() throws {
    let dir = BeatModel.directory
    guard BeatModel(directory: dir) != nil,
          let wave = try? Data(contentsOf: dir.appending(path: "reference-four.wav.bin")) else { return }
    let y = wave.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let rate = BeatTracker.rate
    let n = Int(Double(y.count) * rate / 22050)
    let x = (0..<n).map { i -> Float in
        let p = Double(i) * 22050 / rate, k = Int(p), f = Float(p - Double(k))
        return k + 1 < y.count ? y[k] + (y[k + 1] - y[k]) * f : y[y.count - 1]
    }
    let t = BeatTracker()
    var k = 0
    var bar: (grid: BarGrid, section: Int, intensity: Float, barsSince: Int)?
    while k < x.count {
        let chunk = Array(x[k..<min(k + 512, x.count)])
        k += chunk.count
        t.process(chunk, end: Double(k) / rate)
        if k % (512 * 40) == 0 { Thread.sleep(forTimeInterval: 0.05) }
        if let b = t.bar, b.grid.source == .model { bar = b }
    }
    let b = try #require(bar)
    #expect(b.grid.meter == 4)
    var d = b.grid.lastDownbeat.truncatingRemainder(dividingBy: 2)
    d = min(d, 2 - d)
    #expect(d < 0.12, "downbeat off by \(d)")
}

@Test func gridTempoIsFinerThanFrames() {
    let period = 60.0 / 126
    var beat = [Float](repeating: -5, count: 750), down = [Float](repeating: -5, count: 750)
    let times = (0..<750).map { Double($0) / 50 }
    var k = 0
    while Double(k) * period < 14.8 {
        let f = Int((Double(k) * period * 50).rounded())
        beat[f] = 3
        if k % 4 == 0 { down[f] = 3 }
        k += 1
    }
    guard let g = BeatModel.grid(beat: beat, downbeat: down, times: times) else { Issue.record("no grid"); return }
    #expect(abs(60 / g.period - 126) < 0.3, "bpm \(60 / g.period)")
    #expect(g.meter == 4)
}

@Test func loudChorusStartsASection() {
    var s = SectionTracker()
    let grid = BarGrid(period: 0.5, lastBeat: 0, lastDownbeat: 0, meter: 4, confidence: 1, source: .model)
    var t = 0.0
    var bar = 0
    var changedAt: Int?
    while t < 40 {
        let chorus = t >= 16
        let wobble = Float(sin(t * 5)) * 0.03
        s.push([0.5 + wobble, 0.4, chorus ? 0.45 : 0.4], loud: (chorus ? 1.0 : 0.4) + wobble)
        if s.update(grid: grid, now: t) {
            bar += 1
            if s.index > 0, changedAt == nil { changedAt = bar }
        }
        t += 0.02
    }
    #expect(changedAt.map { $0 >= 8 && $0 <= 13 } == true, "changed at bar \(changedAt ?? -1)")
}

@Test func resumesAfterALongSilence() {
    let t = BeatTracker()
    let rate = BeatTracker.rate
    func clicks(_ seconds: Double, bpm: Double) -> [Float] {
        var samples = [Float](repeating: 0, count: Int(rate * seconds))
        var beat = 0.0
        while beat < seconds {
            let start = Int(beat * rate)
            for i in 0..<min(Int(rate * 0.05), samples.count - start) {
                let x = Double(i) / rate
                samples[start + i] += Float(sin(2 * .pi * 60 * x) * exp(-x * 40))
            }
            beat += 60 / bpm
        }
        return samples
    }
    let samples = clicks(10, bpm: 96) + [Float](repeating: 0, count: Int(rate * 7)) + clicks(10, bpm: 128)
    var k = 0
    while k < samples.count {
        let chunk = Array(samples[k..<min(k + 512, samples.count)])
        k += chunk.count
        t.process(chunk, end: Double(k) / rate)
    }
    guard let e = t.current else { Issue.record("no estimate after the silence"); return }
    #expect(abs(Double(e.bpm) - 128) / 128 < 0.03, "128 → \(e.bpm)")
}

@Test func beatAdvancesAcrossTheBeat() {
    let b = Beat(bpm: 120, phase: 0.9, energy: 1, beatInBar: 3, meter: 4).advanced(by: 0.1)
    #expect(abs(b.phase - 0.1) < 1e-4)
    #expect(b.beatInBar == 0)
    #expect(Beat(bpm: 120, phase: 0.2, energy: 1, beatInBar: 1).advanced(by: 0).beatInBar == 1)
}

@Test func soundEventsFireOnceWhenTheyBegin() {
    #expect(SoundEvent.began(previous: 0.1, now: 0.8))
    #expect(!SoundEvent.began(previous: 0.7, now: 0.9))
    #expect(!SoundEvent.began(previous: 0.1, now: 0.5))
}

@Test func musicMoodMatchesPython() async throws {
    let dir = MusicMoodModel.directory
    guard let model = MusicMoodModel(directory: dir),
          let wave = try? Data(contentsOf: dir.appending(path: "fixture.wave.bin")),
          let melRef = try? Data(contentsOf: dir.appending(path: "fixture.mel.bin")),
          let embRef = try? Data(contentsOf: dir.appending(path: "fixture.embedding.bin")) else { return }
    let floats = { (d: Data) in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    let start = Date()
    let mel = model.logMel(floats(wave))
    let melTime = Date().timeIntervalSince(start)
    let ref = floats(melRef)
    let melErr = zip(mel, ref).map { abs($0 - $1) }.max()!
    #expect(mel.count == ref.count)
    #expect(melErr < 0.05, "mel max err \(melErr)")
    let t0 = Date()
    let emb = try #require(await model.embed(logMel: mel))
    let embTime = Date().timeIntervalSince(t0)
    let e = floats(embRef)
    let cos = zip(emb, e).map { $0 * $1 }.reduce(0, +)
    #expect(cos > 0.999, "cosine \(cos)")
    let c = model.cosines(emb)
    let best = model.labels[c.indices.max { c[$0] < c[$1] }!]
    print("clap: mel \(String(format: "%.1f", melTime * 1000))ms (max err \(melErr)), embed \(String(format: "%.1f", embTime * 1000))ms (first), cosine \(cos), top \(best)")
    #expect(best == "cute")
}

@Test func mixesAllChannelsToMono() throws {
    var left: [Float] = [1, 0, 0.5]
    var right: [Float] = [0, 1, 0.5]
    let planar = AudioBufferList.allocate(maximumBuffers: 2)
    defer { free(planar.unsafeMutablePointer) }
    left.withUnsafeMutableBytes { l in
        right.withUnsafeMutableBytes { r in
            planar[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(l.count), mData: l.baseAddress)
            planar[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(r.count), mData: r.baseAddress)
            #expect(BeatTracker.mixDown(planar) == [0.5, 0.5, 0.5])
        }
    }
    var inter: [Float] = [1, 0, 0, 1, 0.5, 0.5]
    let one = AudioBufferList.allocate(maximumBuffers: 1)
    defer { free(one.unsafeMutablePointer) }
    inter.withUnsafeMutableBytes { p in
        one[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(p.count), mData: p.baseAddress)
        #expect(BeatTracker.mixDown(one) == [0.5, 0.5, 0.5])
    }
}
