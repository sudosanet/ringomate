import MascotCore
import Foundation

/// Dock のバッジの未読の数を読む（`lsappinfo`、中身は読まない）。
public final class AppBadges: @unchecked Sendable {
    public static let apps = [("Slack", "com.tinyspeck.slackmacgap"), ("Discord", "com.hnc.Discord")]
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var last = Date.distantPast
    private var busy = false
    private let queue = DispatchQueue(label: "ringomate.badges", qos: .utility)

    private var seen: [String: Int]?

    public init() {}

    /// 最初の 1 回は何も返さない。
    public func increased(_ now: [String: Int]) -> [(app: String, count: Int)] {
        defer { seen = now }
        guard let seen else { return [] }
        return now.filter { $0.value > (seen[$0.key] ?? 0) }.map { ($0.key, $0.value) }.sorted { $0.app < $1.app }
    }

    /// `running` は起動しているアプリのバンドル ID。
    public func current(running: Set<String>) -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        if !busy, Date().timeIntervalSince(last) > 8 {
            (busy, last) = (true, Date())
            let apps = Self.apps.filter { running.contains($0.1) }
            queue.async { [weak self] in
                guard let self else { return }
                let found = read(apps)
                lock.lock()
                (counts, busy) = (found, false)
                lock.unlock()
            }
        }
        return counts
    }

    /// bundle ID → ASN（`queue` からだけ触る）。アプリが終わると `info` に出なくなるので、そのとき探しなおす。
    private var asns: [String: String] = [:]

    /// `lsappinfo find` は ASN が分からないときだけ、`info` は全部のアプリを 1 回で読む。
    private func read(_ apps: [(String, String)]) -> [String: Int] {
        for (_, id) in apps where asns[id] == nil {
            let found = Self.run(["find", "bundleid=\(id)"])
            asns[id] = found.range(of: Self.asnPattern, options: .regularExpression).map { String(found[$0]) }
        }
        let known = apps.compactMap { app in asns[app.1].map { (app.0, app.1, $0) } }
        guard !known.isEmpty else { return [:] }
        let labels = Self.labels(Self.run(["info", "-only", "StatusLabel"] + known.map { $0.2 + ":" }))
        var out: [String: Int] = [:]
        for (name, id, asn) in known {
            guard let label = labels[asn] else {
                asns[id] = nil
                continue
            }
            if let n = label { out[name] = n }
        }
        return out
    }

    static let asnPattern = #"ASN:0x[0-9a-fA-F]+-0x[0-9a-fA-F]+"#

    /// `lsappinfo info` の出力を ASN ごとに分けて、バッジの数（なければ nil）を返す。出てこない ASN はもう動いていない。
    static func labels(_ output: String) -> [String: Int?] {
        var heads: [Range<String.Index>] = []
        var from = output.startIndex
        while let r = output.range(of: asnPattern, options: .regularExpression, range: from..<output.endIndex) {
            heads.append(r)
            from = r.upperBound
        }
        var out: [String: Int?] = [:]
        for (i, h) in heads.enumerated() {
            let block = output[h.upperBound..<(i + 1 < heads.count ? heads[i + 1].lowerBound : output.endIndex)]
            let label = block.range(of: "\"label\"=\"").map { block[$0.upperBound...].prefix { $0 != "\"" } }
            out.updateValue(label.flatMap { $0.isEmpty ? nil : Int($0) ?? 1 }, forKey: String(output[h]))
        }
        return out
    }

    private static func run(_ args: [String]) -> String { runTool("/usr/bin/lsappinfo", args) ?? "" }
}
