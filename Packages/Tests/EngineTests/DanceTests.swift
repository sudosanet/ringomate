@testable import Engine
import Foundation
import simd
import Testing

private func fract(_ x: Float) -> Float { x - x.rounded(.towardZero) }
private func remEuclid(_ x: Float, _ m: Float) -> Float { let r = x.truncatingRemainder(dividingBy: m); return r < 0 ? r + abs(m) : r }

extension Puppet {
    /// 曲の拍と再生中のクリップの拍のずれ（−0.5〜0.5 拍、テンポ不明なら nil）。
    func beatError(_ phase: Float, _ bpm: Float) -> Float? {
        guard let tempo = tempo(of: player.current) else { return nil }
        let mult = Self.multiple(bpm, tempo)
        return remEuclid(phase - fract(player.time * tempo / 60 / mult) + 1.5, 1) - 0.5
    }

    func clipPosition(_ bpm: Float) -> Float? {
        clipBeats(bpm).map { tempo, mult, len in remEuclid(player.time * tempo / 60 / mult, len) }
    }
}

private func loadScene() throws -> (Scene, ModelData) {
    let scene = Scene()
    let data = try scene.load(model: Assets.model, library: Assets.library)
    scene.commitLoad()
    return (scene, data)
}

@Test func dancesFollowTheBeat() throws {
    let (scene, data) = try loadScene()
    let c = scene.character!
    for slot in [Slot.beatStep, .beatClap, .beatPoint] {
        for bpm: Float in [96, 128, 150] {
            var (t, late): (Float, Float) = (0, 0)
            while t < 6 {
                let phase = fract(t * bpm / 60)
                var i = Intent()
                (i.motion, i.beat) = (slot, Beat(bpm: bpm, phase: phase, energy: 1, clip: nil))
                c.step(1.0 / 60, i)
                if t > 4 { late = max(late, abs(c.beatError(phase, bpm)!)) }
                t += 1.0 / 60
            }
            print("\(slot) at \(bpm) bpm: late phase error \(late)")
            #expect(late < 0.08, "\(slot) did not follow \(bpm) bpm")
        }
    }
    let dances = data.gestures.indices.filter { data.gestures[$0].contains("dance") || data.gestures[$0].hasPrefix("macarena") }
    var synced = 0
    for k in dances {
        let slot = Slot.gesture(UInt8(k))
        var t: Float = 0
        var errors: [Float] = []
        while t < min(c.duration(of: slot), 6) {
            let phase = fract(t * 128 / 60)
            var i = Intent()
            (i.motion, i.beat) = (slot, Beat(bpm: 128, phase: phase, energy: 1, clip: nil))
            c.step(1.0 / 60, i)
            if let e = c.beatError(phase, 128) { errors.append(abs(e)) }
            t += 1.0 / 60
        }
        if c.tempo(of: slot) != nil, (errors.suffix(60).max() ?? 1) < 0.12 { synced += 1 }
    }
    print("\(synced) of \(dances.count) recorded dances followed the beat")
    #expect(!dances.isEmpty)
}

@Test func danceHopHeight() throws {
    let (scene, data) = try loadScene()
    try scene.lock.withLock {
        let st = try #require(scene.state)
        for _ in 0..<60 { _ = st.env.step(1.0 / 60, .none) }
        let ground = st.env.step(1.0 / 60, .none).y
        st.env.hop(122 * 0.55 * 0.5 / 2)
        var top = ground
        for _ in 0..<120 { top = max(top, st.env.step(1.0 / 60, .none).y) }
        print("hop: height \(top - ground) of \(data.height)")
        #expect(top - ground > data.height * 0.03)
    }
}

@Test func danceMovesFollowTheBar() throws {
    let (scene, _) = try loadScene()
    let c = scene.character!
    for (bpm, index): (Float, UInt16) in [(128, 3), (100, 91)] {
        var (t, worst): (Float, Float) = (0, 0)
        while t < 6 {
            let clip = t * bpm / 60 - 0.3
            var i = Intent()
            (i.motion, i.beat) = (.dance(index), Beat(bpm: bpm, phase: remEuclid(clip, 1), energy: 1, clip: clip))
            c.step(1.0 / 60, i)
            if let now = c.clipPosition(bpm) {
                let len: Float = (88..<110).contains(index) ? 8 : 4
                worst = max(worst, abs(remEuclid(remEuclid(clip - now, len) + len / 2, len) - len / 2))
            }
            t += 1.0 / 60
        }
        print("Dance(\(index)) at \(bpm) bpm: worst bar error \(worst) beats")
        #expect(worst < 0.15, "Dance(\(index)) drifted \(worst) beats from the bar")
        c.step(1.0 / 60, Intent())
    }
}

/// 跳ぶ・回る踊りの BVH（30fps、`seconds` 秒、`jumpAt` 秒から `airtime` 秒で `peak` だけ上がり、その間に腰が `turn` 度回る）。
func jumpBVH(fps: Float, seconds: Float, jumpAt: Float, peak: Float, airtime: Float, turn: Float) -> String {
    func joint(_ name: String, _ o: (Float, Float, Float), _ body: String) -> String {
        "JOINT \(name)\n{\nOFFSET \(o.0) \(o.1) \(o.2)\nCHANNELS 3 Zrotation Xrotation Yrotation\n\(body)}\n"
    }
    let end = "End Site\n{\nOFFSET 0 0 0\n}\n"
    func leg(_ s: Float, _ side: String) -> String {
        joint("\(side)UpLeg", (8 * s, 0, 0), joint("\(side)Leg", (0, -40, 0), joint("\(side)Foot", (0, -40, 0), joint("\(side)ToeBase", (0, -7, 14), end))))
    }
    func arm(_ s: Float, _ side: String) -> String {
        joint("\(side)Shoulder", (2.5 * s, 18.8, 0), joint("\(side)Arm", (15 * s, 0, 0), joint("\(side)ForeArm", (27 * s, 0, 0), joint("\(side)Hand", (24 * s, 0, 0), end))))
    }
    let chest = joint("Chest", (0, 19.5, 0), joint("Neck", (0, 19.5, 0), joint("Head", (0, 8.8, 0), end)) + arm(1, "Left") + arm(-1, "Right"))
    let body = joint("Spine", (0, 19.5, 0), chest) + leg(1, "Left") + leg(-1, "Right")
    let joints = 1 + body.components(separatedBy: "JOINT").count - 1
    let n = Int(seconds * fps)
    let g = 8 * peak / (airtime * airtime)
    var text = "HIERARCHY\nROOT Hips\n{\nOFFSET 0 0 0\nCHANNELS 6 Xposition Yposition Zposition Zrotation Xrotation Yrotation\n\(body)}\nMOTION\nFrames: \(n)\nFrame Time: \(1 / fps)\n"
    for i in 0..<n {
        let t = Float(i) / fps - jumpAt
        var row = [Float](repeating: 0, count: 3 + joints * 3)
        row[1] = 87 + (t >= 0 && t < airtime ? g * t * (airtime - t) / 2 : 0)
        row[5] = turn * min(max(t / airtime, 0), 1)
        text += row.map { String(format: "%.3f", $0) }.joined(separator: " ") + "\n"
    }
    return text
}

private func writeTemp(_ name: String, _ text: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: name)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
}

private func playSong(_ c: Puppet, seconds: Float, _ each: (Float) -> Void) {
    var t: Float = 0
    while t < seconds {
        var i = Intent()
        (i.motion, i.song) = (.dance(508), SongPlay(clipTime: t, rate: 1))
        c.step(1.0 / 60, i)
        each(t)
        t += 1.0 / 60
    }
}

@Test func recordedJumpsKeepTheirHeight() throws {
    let path = try writeTemp("ringomate-jump-test.bvh", jumpBVH(fps: 30, seconds: 4, jumpAt: 2, peak: 25, airtime: 0.5, turn: 0))
    let (scene, data) = try loadScene()
    try scene.assignSongDance(index: 508, path: path, front: nil)
    let c = scene.character!
    var (gap, seen, hasFeet): (Float, Float, Bool) = (0, 0, false)
    playSong(c, seconds: 3.5) { t in
        if t > 1, let g = c.feetGap() {
            hasFeet = true
            gap = max(gap, g)
            seen = max(seen, g - c.drop)
        }
    }
    #expect(hasFeet, "no foot bones")
    print("clip lifts the feet \(gap), drawn \(seen) (height \(data.height))")
    #expect(gap > data.height * 0.05, "the clip jumps: \(gap)")
    #expect(seen > gap * 0.9, "drawn jump \(seen) of \(gap)")
}

@Test func recordedTurnsKeepTheirRotation() throws {
    let path = try writeTemp("ringomate-turn-test.bvh", jumpBVH(fps: 30, seconds: 4, jumpAt: 1, peak: 0, airtime: 1, turn: 180))
    let (scene, _) = try loadScene()
    try scene.assignSongDance(index: 508, path: path, front: nil)
    let c = scene.character!
    let upper = c.bone("上半身")!
    var facing: [(Float, Float)] = []
    playSong(c, seconds: 3) { t in
        let f = xyz(c.boneWorld(upper) * SIMD4(0, 0, -1, 0))
        facing.append((t, atan2(f.x, -f.z) * 180 / .pi))
    }
    func at(_ s: Float) -> Float { facing.min { abs($0.0 - s) < abs($1.0 - s) }!.1 }
    let turned = remEuclid(at(2.5) - at(0.8), 360)
    print("turn: \(turned) degrees")
    #expect(abs(turned - 180) < 20, "turned \(turned)")
}
