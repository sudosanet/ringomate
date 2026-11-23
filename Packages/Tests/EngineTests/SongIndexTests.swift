@testable import Engine
import Testing

/// 辞書で票を数える前の実装（並べて数える今の実装と結果が同じことを確かめる）。
private func referenceLookup(_ index: SongIndex, _ query: [UInt32], minVotes: UInt32) -> [SongIndex.Hit] {
    struct Key: Hashable { let version: UInt32, d: Int }
    var votes: [Key: UInt32] = [:]
    for (qi, q) in query.enumerated() {
        for b in -1..<32 {
            let v = b < 0 ? q : q ^ (1 << UInt32(b))
            var k = index.items.partitionPoint { $0 < v }
            while k < index.items.count && index.items[k] == v {
                votes[Key(version: index.versions[k], d: Int(index.positions[k]) - qi), default: 0] += 1
                k += 1
            }
        }
    }
    func merged(_ k: Key) -> UInt32 { (-1...1).reduce(0) { $0 + (votes[Key(version: k.version, d: k.d + $1)] ?? 0) } }
    var best: [UInt32: (UInt32, Int)] = [:]
    for k in votes.keys {
        let m = merged(k)
        let e = best[k.version] ?? (0, k.d)
        if m > e.0 || (m == e.0 && k.d < e.1) { best[k.version] = (m, k.d) }
    }
    return best.filter { $0.value.0 >= minVotes }
        .map { SongIndex.Hit(version: $0.key, offset: Double($0.value.1) * Chromaprint.itemSeconds, votes: $0.value.0,
                             items: UInt32(query.count)) }
        .sorted { $0.votes != $1.votes ? $0.votes > $1.votes : $0.version < $1.version }
}

@Test func songIndexLookupMatchesDictionaryVotes() {
    var rng = SystemRandomNumberGenerator()
    // 値の種類を少なくして、1 ビット違い・時間差の前後・負の時間差がよく当たるようにする
    let alphabet = (0..<40).map { _ in UInt32.random(in: 0...UInt32.max, using: &rng) }
    let near = alphabet.flatMap { a in [a, a ^ (1 << UInt32.random(in: 0..<32, using: &rng))] }
    for _ in 0..<20 {
        var index = SongIndex()
        var songs: [[UInt32]] = []
        for v in 0..<5 {
            let song = (0..<300).map { _ in near.randomElement(using: &rng)! }
            songs.append(song)
            index.add(UInt32(v), song)
        }
        index.finish()
        for _ in 0..<5 {
            let song = songs.randomElement(using: &rng)!
            let start = Int.random(in: 0..<200, using: &rng)
            var query = Array(song[start..<(start + 60)])
            for i in query.indices where Int.random(in: 0..<4, using: &rng) == 0 { query[i] = near.randomElement(using: &rng)! }
            #expect(index.lookup(query, minVotes: 8) == referenceLookup(index, query, minVotes: 8))
            #expect(index.lookup(query, minVotes: 1) == referenceLookup(index, query, minVotes: 1))
        }
    }
}
