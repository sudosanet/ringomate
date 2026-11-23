import Foundation

public struct SongFollower: Sendable {
    public struct Position: Equatable, Sendable {
        public var pack: Int
        public var version: Int
        public var refTime: Double
        public var clipTime: Double?
        public var rate: Double
    }

    struct Lock: Sendable {
        var pack: Int, version: Int
        /// 版の秒 = ホストの時計の秒 + lag。
        var lag: Double

        func same(_ o: Lock) -> Bool { pack == o.pack && version == o.version && abs(lag - o.lag) < 0.25 }
    }

    var lock: Lock?
    var candidate: Lock?
    var jump: Lock?
    var misses = 0
    var onset: [Float] = []
    public var debug = ""

    static let minCorr: Float = 0.75
    public static let rate = 24_000

    public init() {}

    /// 重い計算（指紋・照合・オンセット）の結果。状態を持たないので、ロックの外で作れる。
    public struct Observation: Sendable {
        var found: Lock?
        var live: [Float]
        var start: Double
        var debug: String
    }

    /// 24kHz の 1 チャンネル、最後のサンプルがホストの `end` 秒。
    public mutating func update(_ lib: SongLibrary, samples: [Float], end: Double) {
        apply(Self.observe(lib, samples: samples, end: end), lib)
    }

    public static func observe(_ lib: SongLibrary, samples: [Float], end: Double) -> Observation {
        let rate = Double(Self.rate)
        let start = end - Double(samples.count) / rate
        let take = min(samples.count, Int(8 * rate))
        let recentStart = end - Double(take) / rate
        let fp = Chromaprint.fingerprint(Array(samples.suffix(take)), rate: Self.rate)
        let raw = lib.lookup(fp)
        let debug = raw.map { r in
            String(format: "top %@#%d votes %d other %d lag %.2f", lib.packs[r.pack].toml.id, r.version, r.hit.votes,
                   r.other, r.hit.offset - recentStart)
        } ?? "no hit"
        let found = raw.flatMap { r in
            Double(r.hit.votes) >= 1.5 * max(Double(r.other), 4) ? Lock(pack: r.pack, version: r.version, lag: r.hit.offset - recentStart) : nil
        }
        return Observation(found: found, live: SongFeatures.onset(samples), start: start, debug: debug)
    }

    public mutating func apply(_ o: Observation, _ lib: SongLibrary) {
        debug = o.debug
        let (found, live, start) = (o.found, o.live, o.start)
        if let l = lock {
            if let f = found, !f.same(l) {
                if let j = jump, j.same(f) {
                    lock = nil
                    tryLock(lib, f, live, start)
                    jump = nil
                    return
                }
                jump = f
            } else {
                jump = nil
            }
            track(live, start)
        } else if let f = found {
            if let c = candidate, c.same(f) { tryLock(lib, f, live, start) }
            candidate = f
        } else {
            candidate = nil
        }
    }

    mutating func tryLock(_ lib: SongLibrary, _ c: Lock, _ live: [Float], _ start: Double) {
        let onset = lib.packs[c.pack].analysis.versions[c.version].onsetValues()
        let r = Self.refine(live, start, onset, c.lag, 0.3)
        debug += String(format: " corr %.2f", r.map { Double($0.1) } ?? -1)
        if let (lag, corr) = r, corr > Self.minCorr {
            lock = Lock(pack: c.pack, version: c.version, lag: lag)
            self.onset = onset
            misses = 0
        }
    }

    mutating func track(_ live: [Float], _ start: Double) {
        guard let l = lock else { return }
        let keep = min(live.count, Int(3 * SongFeatures.onsetFPS))
        let tailStart = start + Double(live.count - keep) / SongFeatures.onsetFPS
        if let (lag, corr) = Self.refine(Array(live.suffix(keep)), tailStart, onset, l.lag, 0.2), corr > 0.2 {
            lock = Lock(pack: l.pack, version: l.version, lag: lag)
            misses = 0
        } else {
            misses += 1
            if misses >= 4 { lock = nil }
        }
    }

    public func position(_ lib: SongLibrary, now: Double) -> Position? {
        guard let l = lock, lib.packs.indices.contains(l.pack) else { return nil }
        let pack = lib.packs[l.pack]
        guard pack.analysis.versions.indices.contains(l.version) else { return nil }
        let v = pack.analysis.versions[l.version]
        let vt = Float(now + l.lag)
        guard let ref = v.toRef.map(vt) else { return nil }
        return Position(pack: l.pack, version: l.version, refTime: Double(ref), clipTime: pack.analysis.clip.map(ref).map(Double.init),
                        rate: Double(v.toRef.slope(vt) ?? 1))
    }

    static func refine(_ live: [Float], _ start: Double, _ onset: [Float], _ lag: Double, _ reach: Double) -> (Double, Float)? {
        let fps = SongFeatures.onsetFPS
        let c = (start + lag) * fps
        guard c.isFinite, abs(c) < 1e15 else { return nil }
        let center = Int(c.rounded())
        let r = Int(reach * fps)
        return (-r...r).map { ($0, SongFeatures.ncc(live, onset, center + $0)) }.lastMax { $0.1 < $1.1 }
            .map { (lag + Double($0.0) / fps, $0.1) }
    }
}
