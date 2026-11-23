@testable import Engine
import Foundation
import Testing
import simd


@Test func songTomlRejectsUnknownKeys() {
    let ok = "schema = 1\nid = \"a\"\ntitle = \"A\"\n[dance]\nfile = \"dance.glb\"\noffset = 2\n[[dance.part]]\nfile = \"b.glb\"\noffset = 1.5\n[[version]]\nname = \"x\"\n"
    let t = try? SongToml(parsing: ok)
    #expect(t?.dance.offset == 2 && t?.dance.parts.first?.offset == 1.5 && t?.dance.fillRepeats == true)
    #expect((try? SongToml(parsing: ok + "extra = 1\n")) == nil)
    #expect((try? SongToml(parsing: "credit = \"c\"\nterms = \"t\"\nsource = [\"u\"]\n" + ok)) == t)
    let m = try? SongToml(parsing: ok + "map = [[5.1, 0.0], [110.5, 116.1]]\n")
    #expect(m?.versions.first?.map == [SIMD2(5.1, 0.0), SIMD2(110.5, 116.1)])
    #expect((try? SongToml(parsing: ok + "map = [[5.1]]\n")) == nil)
}

private func clicks(_ bpm: Float, _ seconds: Float) -> [Float] {
    let rate: Float = 24_000
    let period = Int(60 / bpm * rate)
    return (0..<Int(seconds * rate)).map { $0 % period < 200 ? (Float($0 % 50) / 25 - 1) * 0.5 : 0 }
}

@Test func songOnsetPeaksOnClicks() {
    let env = SongFeatures.onset(clicks(120, 6))
    let top = env.max()!
    let peaks = (1..<env.count - 1).filter { env[$0] > 0.5 * top && env[$0] >= env[$0 - 1] && env[$0] >= env[$0 + 1] }
    let gaps = zip(peaks, peaks.dropFirst()).map { $1 - $0 }
    #expect(!gaps.isEmpty && gaps.allSatisfy { (48...52).contains($0) }, "\(gaps)")
}

@Test func songChromaFindsTheNote() {
    let a = (0..<48_000).map { sin(2 * Float.pi * 440 * Float($0) / 24_000) }
    let c = SongFeatures.chroma(a, rate: 24_000)
    #expect(c[5].indices.lastMax { c[5][$0] < c[5][$1] } == 9)
}

@Test func songNCCFindsTheLag() {
    let a = (0..<500).map { Float(($0 * 7919) % 101) }
    let b = [Float](repeating: 0, count: 37) + a
    #expect((-50..<50).lastMax { SongFeatures.ncc(a, b, $0) < SongFeatures.ncc(a, b, $1) } == 37)
}

private func song(_ frames: Int, _ speed: Float, _ shift: Int) -> [Chroma12] {
    (0..<frames).map { i in
        let t = Float(i) * speed
        var c = [Float](repeating: 0, count: 12)
        let seg = UInt64(t / 3)
        let chord = [0, 5, 7, 9][Int(((seg &* 2_654_435_761) >> 7) % 4)]
        for k in [0, 4, 7] { c[(chord + k + shift) % 12] = 1 }
        c[([0, 2, 4, 5, 7, 9, 11][Int((UInt64(t * 2) &* 40_503) >> 5) % 7] + shift) % 12] += 0.5
        let mean = c.reduce(0, +) / 12
        c = c.map { $0 - mean }
        let n = c.map { $0 * $0 }.reduce(0, +).squareRoot()
        return c.map { $0 / n }
    }
}

@Test func songWarpMapsAFasterHigherVersion() throws {
    let (map, rot) = SongWarp.align(song(1000, 1.2, 3), song(1200, 1, 0), [], [])
    #expect(rot == 3)
    for t: Float in [10, 40, 80] { #expect(abs(try #require(map.map(t)) - t * 1.2) < 0.3) }
}

@Test func songWarpMapsAVersionWithALongerIntro() throws {
    let (map, _) = SongWarp.align(song(150, 0.37, 7) + song(1000, 1, 0), song(1000, 1, 0), [], [])
    let got = try #require(map.map(15 + 30))
    #expect(abs(got - 30) < 0.3, "\(got)")
}

@Test func songRepeatsFillTheSecondChorus() throws {
    func frame(_ t: Float) -> Chroma12 {
        let part = t < 20 || t >= 40 ? 0 : 1
        let local = t >= 40 ? t - 40 : t.truncatingRemainder(dividingBy: 20)
        var c = [Float](repeating: 0, count: 12)
        c[(part * 5 + Int(local / 2) * 7) % 12] = 1
        c[(part * 3 + Int(local / 0.7) * 5) % 12] += 0.6
        let mean = c.reduce(0, +) / 12
        c = c.map { $0 - mean }
        let n = c.map { $0 * $0 }.reduce(0, +).squareRoot()
        return c.map { $0 / n }
    }
    let map = ClipMap.fill((0..<600).map { frame(Float($0) / 10) }, .single(offset: 0, length: 40))
    #expect(abs(try #require(map.map(50)) - 10) < 0.3)
}

private func motion(_ hand: [Float]) -> BVH.RawMotion {
    BVH.RawMotion(names: ["Hips", "Hand"], parents: [nil, 0], offsets: [.zero, SIMD3(0, 1, 0)], fps: 30,
                  poses: hand.map { [(SIMD3(0, 1, 0), simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)), (SIMD3($0, 1, 0), simd_quatf(ix: 0, iy: 0, iz: 0, r: 1))] })
}

@Test func danceJumpsRepairSpikesAndStepsOnly() {
    let smooth = (0..<60).map { sin(Float($0) * 0.2) * 0.3 }
    var m = motion(smooth)
    #expect(DanceJumps.find(m).isEmpty && DanceJumps.repair(&m) == 0)

    var spike = smooth
    spike[20] += 3
    m = motion(spike)
    #expect(DanceJumps.find(m).count == 2)
    #expect(DanceJumps.repair(&m) == 1)
    #expect(DanceJumps.find(m).isEmpty && abs(m.poses[20][1].0.x - smooth[20]) < 0.2)

    let long = (0..<150).map { sin(Float($0) * 0.2) * 0.3 }
    let step = long.enumerated().map { $1 + ($0 >= 75 ? 4 : 0) }
    m = motion(step)
    #expect(DanceJumps.find(m).count == 1)
    _ = DanceJumps.repair(&m)
    #expect(DanceJumps.find(m).isEmpty && m.poses[10][1].0.x == step[10] && m.poses[140][1].0.x == step[140])

    m = motion(long)
    for i in 75..<150 { m.poses[i][0].0.x += 5 }
    #expect(!DanceJumps.find(m).isEmpty)
    _ = DanceJumps.repair(&m)
    #expect(DanceJumps.find(m).isEmpty && abs(m.poses[149][0].0.x - m.poses[0][0].0.x) < 0.01)
}
