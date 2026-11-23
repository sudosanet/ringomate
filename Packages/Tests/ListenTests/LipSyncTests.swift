import Accelerate
import AVFoundation
import Foundation
@testable import Listen
import MascotCore
import Testing

private func speak(_ text: String, voice: String) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appending(path: "ringomate-lips-\(UUID()).wav")
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEF32@16000", text]
    try p.run()
    p.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

private let vowelTexts = ["あーーーーー", "いーーーーー", "うーーーーー", "えーーーーー", "おーーーーー"]

@Test func tellsVowelsApart() throws {
    var correct = 0, total = 0
    for voice in ["Sandy", "Grandpa"] {
        let sounds = try vowelTexts.map { try speak($0, voice: voice) }
        var lips = LipSync()
        for x in sounds {
            for end in stride(from: LipSync.window, to: x.count, by: 267) { _ = lips.vowels(x[(end - LipSync.window)..<end]) }
        }
        for (k, text) in vowelTexts.enumerated() {
            let x = sounds[k]
            var votes = [Float](repeating: 0, count: 5)
            for end in stride(from: LipSync.window, to: x.count, by: 267) {
                let v = lips.vowels(x[(end - LipSync.window)..<end])
                for i in 0..<5 { votes[i] += v[i] }
            }
            let best = votes.indices.max { votes[$0] < votes[$1] }!
            print("\(voice) \(text.prefix(1)) → \(["あ", "い", "う", "え", "お"][best]) \(votes.map { String(format: "%.1f", $0) })")
            correct += best == k ? 1 : 0
            total += 1
        }
    }
    #expect(correct >= total - 1, "\(correct)/\(total)")
    var lips = LipSync()
    _ = lips.vowels([Float](repeating: 0.3, count: LipSync.window)[...])
    #expect(lips.vowels([Float](repeating: 0, count: LipSync.window)[...]).reduce(0, +) == 0)
}

@Test func vocalFocusKeepsTheCenter() {
    let rate = VocalFocus.inputRate
    let n = Int(rate * 2)
    let tone = (0..<n).map { i -> Float in
        let t = Float(Double(i) / rate)
        return (1...6).map { 0.1 / Float($0) * sin(2 * .pi * 220 * Float($0) * t) }.reduce(0, +)
    }
    var g = SystemRandomNumberGenerator()
    let noise = (0..<n).map { _ in Float.random(in: -0.3...0.3, using: &g) }
    let clicks = (0..<n).map { i in i % 12_000 < 40 ? Float(0.8) : 0 }
    let rms = { (x: [Float]) in sqrt(x.map { $0 * $0 }.reduce(0, +) / Float(max(x.count, 1))) }
    let run = { (l: [Float], r: [Float]) -> [Float] in
        let f = VocalFocus()
        var out: [Float] = []
        for s in stride(from: 0, to: n, by: 960) { out += f.push(left: Array(l[s..<min(s + 960, n)]), right: Array(r[s..<min(s + 960, n)])) }
        return Array(out.dropFirst(4000))
    }
    let center = rms(run(tone, tone))
    let side = rms(run(noise, [Float](repeating: 0, count: n)))
    let drums = rms(run(clicks, clicks))
    print("center \(center) side \(side) drums \(drums)")
    #expect(center > 0.02)
    #expect(side < center * 0.2)
    #expect(drums < center * 0.5)
    #expect(rms(run([Float](repeating: 0, count: n), [Float](repeating: 0, count: n))) == 0)
}

@Test func vocalFocusThenLipSync() throws {
    var correct = 0
    for voice in ["Sandy", "Grandpa"] {
        let sounds = try vowelTexts.map { try speak24($0, voice: voice) }
        let focus = VocalFocus()
        var lips = LipSync()
        var g = SystemRandomNumberGenerator()
        var results: [[Float]] = []
        for pass in 0..<2 {
            for x in sounds {
                let noise = x.map { _ in Float.random(in: -0.02...0.02, using: &g) }
                var votes = [Float](repeating: 0, count: 5)
                var pending: [Float] = []
                for s in stride(from: 0, to: x.count, by: 960) {
                    let e = min(s + 960, x.count)
                    pending += focus.push(left: zip(x[s..<e], noise[s..<e]).map { $0 + $1 }, right: Array(x[s..<e]))
                    while pending.count >= LipSync.window + 267 {
                        pending.removeFirst(267)
                        let v = lips.vowels(pending[0..<LipSync.window])
                        for i in 0..<5 { votes[i] += v[i] }
                    }
                }
                if pass == 1 { results.append(votes) }
            }
        }
        for (k, v) in results.enumerated() {
            let best = v.indices.max { v[$0] < v[$1] }!
            print("\(voice) \(vowelTexts[k].prefix(1)) → \(["あ", "い", "う", "え", "お"][best])")
            correct += best == k ? 1 : 0
        }
    }
    #expect(correct >= 9, "\(correct)/10")
}

private func speak24(_ text: String, voice: String) throws -> [Float] {
    let url = FileManager.default.temporaryDirectory.appending(path: "ringomate-lips-\(UUID()).wav")
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/say")
    p.arguments = ["-v", voice, "-o", url.path, "--file-format=WAVE", "--data-format=LEF32@24000", text]
    try p.run()
    p.waitUntilExit()
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forReading: url)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

@Test func separatorMatchesGolden() async throws {
    let dir = VocalSeparator.directory
    guard let raw = try? Data(contentsOf: dir.appending(path: "golden_raw.f32")),
          let gold = try? Data(contentsOf: dir.appending(path: "golden_vocals.f32")) else { return }
    let floats = { (d: Data) in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    let (x, g) = (floats(raw), floats(gold))
    let n = VocalSeparator.chunk
    let sep = try await VocalSeparator()
    let t0 = Date()
    let (l, r) = try await sep.separateChunk(Array(x[0..<n]), Array(x[n..<(2 * n)]))
    print("8 s chunk in \(Date().timeIntervalSince(t0)) s")
    let y = l + r
    let cos = vDSP.dot(y, g) / (sqrt(vDSP.sumOfSquares(y)) * sqrt(vDSP.sumOfSquares(g)))
    print("cos \(cos)")
    #expect(cos > 0.99)
}
