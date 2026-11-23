public struct SongToml: Equatable, Sendable {
    public var schema: UInt32
    public var id: String
    public var title: String
    public var artist = ""
    public var dance: Dance
    public var versions: [Version]

    public struct Dance: Equatable, Sendable {
        public var file: String
        public var offset = 0.0
        public var front: Float?
        var fillRepeats = true
        public var parts: [(file: String, offset: Double)] = []

        public static func == (a: Dance, b: Dance) -> Bool {
            a.file == b.file && a.offset == b.offset && a.front == b.front && a.fillRepeats == b.fillRepeats
                && a.parts.map(\.file) == b.parts.map(\.file) && a.parts.map(\.offset) == b.parts.map(\.offset)
        }
    }

    public struct Version: Equatable, Sendable {
        public var name: String
        public var audio: String?
        /// `map = [[版の秒, 基準の秒], …]`。あれば DTW の代わりに使う。
        public var map: [SIMD2<Float>] = []
    }

    struct Bad: Error, CustomStringConvertible {
        let description: String
    }

    public init(parsing text: String) throws {
        let t = try TOML.parse(text)
        func only(_ t: [String: TOML], _ keys: Set<String>, _ at: String) throws {
            if let k = t.keys.sorted().first(where: { !keys.contains($0) }) { throw Bad(description: "unknown field `\(k)` in \(at)") }
        }
        func need<T>(_ v: T?, _ name: String) throws -> T {
            guard let v else { throw Bad(description: "missing or invalid field `\(name)`") }
            return v
        }
        func strings(_ v: TOML?, _ name: String) throws -> String? {
            guard let v else { return nil }
            return try need(v.string, name)
        }
        try only(t, ["schema", "id", "title", "artist", "credit", "terms", "source", "dance", "version"], "song.toml")
        let schema = try need(t["schema"]?.int, "schema")
        guard let s = UInt32(exactly: schema) else { throw Bad(description: "invalid schema") }
        self.schema = s
        id = try need(t["id"]?.string, "id")
        title = try need(t["title"]?.string, "title")
        artist = try strings(t["artist"], "artist") ?? ""
        let d = try need(t["dance"]?.table, "dance")
        try only(d, ["file", "offset", "front", "fill_repeats", "part"], "[dance]")
        dance = Dance(file: try need(d["file"]?.string, "dance.file"))
        if let o = d["offset"] { dance.offset = try need(o.double, "dance.offset") }
        if let f = d["front"] { dance.front = Float(try need(f.double, "dance.front")) }
        if let f = d["fill_repeats"] { dance.fillRepeats = try need(f.bool, "dance.fill_repeats") }
        for p in try d["part"].map({ try need($0.array, "dance.part") }) ?? [] {
            let p = try need(p.table, "dance.part")
            try only(p, ["file", "offset"], "[[dance.part]]")
            dance.parts.append((try need(p["file"]?.string, "part.file"), try need(p["offset"]?.double, "part.offset")))
        }
        versions = try need(t["version"]?.array, "version").map { v in
            let v = try need(v.table, "version")
            try only(v, ["name", "audio", "map"], "[[version]]")
            let map = try v["map"].map { try need($0.array, "version.map").map { p -> SIMD2<Float> in
                let xy = try need(p.array, "version.map").map { try need($0.double, "version.map") }
                guard xy.count == 2 else { throw Bad(description: "version.map needs [version seconds, reference seconds]") }
                return SIMD2(Float(xy[0]), Float(xy[1]))
            } } ?? []
            return Version(name: try need(v["name"]?.string, "version.name"), audio: try strings(v["audio"], "version.audio"), map: map)
        }
    }
}
