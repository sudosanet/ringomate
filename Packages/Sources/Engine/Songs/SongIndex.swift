struct SongIndex: Sendable {
    /// 版の秒 = 聞いている音の秒 + `offset`。
    struct Hit: Equatable, Sendable {
        public var version: UInt32
        public var offset: Double
        var votes: UInt32
        public var items: UInt32
    }

    var items: [UInt32] = []
    var versions: [UInt32] = []
    var positions: [UInt32] = []
    var pending: [(UInt32, UInt32, UInt32)] = []

    public init() {}

    public mutating func add(_ version: UInt32, _ fingerprint: [UInt32]) {
        for (i, v) in fingerprint.enumerated() { pending.append((v, version, UInt32(i))) }
    }

    public mutating func finish() {
        pending += zip(items, zip(versions, positions)).map { ($0, $1.0, $1.1) }
        pending.sort { $0 < $1 }
        items = pending.map(\.0)
        versions = pending.map(\.1)
        positions = pending.map(\.2)
        pending = []
    }

    public var count: Int { items.count }

    /// 票は (版, 時間差) を詰めた値を並べて数える（辞書より速い）。d は符号を反転して上位の版と並び順をそろえる。
    func lookup(_ query: [UInt32], minVotes: UInt32) -> [Hit] {
        var keys: [UInt64] = []
        for (qi, q) in query.enumerated() {
            for b in -1..<32 {
                let v = b < 0 ? q : q ^ (1 << UInt32(b))
                var k = items.partitionPoint { $0 < v }
                while k < items.count && items[k] == v {
                    let d = UInt32(bitPattern: Int32(Int(positions[k]) - qi)) ^ 0x8000_0000
                    keys.append(UInt64(versions[k]) << 32 | UInt64(d))
                    k += 1
                }
            }
        }
        keys.sort()
        var runs: [(key: UInt64, count: UInt32)] = []
        for k in keys {
            if runs.last?.key == k { runs[runs.count - 1].count += 1 } else { runs.append((k, 1)) }
        }
        // 版ごとに、前後 ±1 の時間差の票を足して一番多いもの（同じ票なら時間差の小さいほう）
        var best: [(version: UInt32, votes: UInt32, d: Int)] = []
        for (i, r) in runs.enumerated() {
            var m = r.count
            if i > 0, runs[i - 1].key == r.key &- 1 { m += runs[i - 1].count }
            if i + 1 < runs.count, runs[i + 1].key == r.key &+ 1 { m += runs[i + 1].count }
            let version = UInt32(r.key >> 32), d = Int(Int32(bitPattern: UInt32(truncatingIfNeeded: r.key) ^ 0x8000_0000))
            if best.last?.version != version {
                best.append((version, m, d))
            } else if m > best[best.count - 1].votes {
                best[best.count - 1] = (version, m, d)
            }
        }
        return best.filter { $0.votes >= minVotes }
            .map { Hit(version: $0.version, offset: Double($0.d) * Chromaprint.itemSeconds, votes: $0.votes, items: UInt32(query.count)) }
            .sorted { $0.votes != $1.votes ? $0.votes > $1.votes : $0.version < $1.version }
    }
}
