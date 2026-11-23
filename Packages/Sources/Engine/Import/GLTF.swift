import Foundation
import simd

struct GLB {
    let json: JSONValue
    let bin: [UInt8]

    struct Invalid: Error, CustomStringConvertible {
        let description: String
    }

    init(_ bytes: [UInt8]) throws {
        guard bytes.count >= 20, bytes[0..<4].elementsEqual("glTF".utf8) else { throw Invalid(description: "not a GLB") }
        let total = Int(le32(bytes, 8))
        guard total >= 12, total <= bytes.count else { throw Invalid(description: "GLB length \(total)") }
        var p = 12
        var json: JSONValue?
        var bin: [UInt8] = []
        while p + 8 <= total {
            let len = Int(le32(bytes, p)), kind = le32(bytes, p + 4)
            guard p + 8 + len <= total else { throw Invalid(description: "GLB chunk out of range") }
            let body = Array(bytes[p + 8..<p + 8 + len])
            if kind == 0x4E4F_534A, json == nil { json = try JSONValue.parse(body) }
            if kind == 0x004E_4942, bin.isEmpty { bin = body }
            p += 8 + len
        }
        guard let json else { throw Invalid(description: "GLB has no JSON") }
        self.json = json
        self.bin = bin
    }

    static let componentTypes: Set<Int> = [5120, 5121, 5122, 5123, 5125, 5126]
    /// これより多い要素の accessor は壊れたファイルとみなす（確保する量を抑える）
    static let maxCount = 1 << 24

    static func componentSize(_ t: Int) -> Int {
        switch t {
        case 5120, 5121: 1
        case 5122, 5123: 2
        default: 4
        }
    }

    static func components(_ t: String) -> Int {
        switch t {
        case "SCALAR": 1
        case "VEC2": 2
        case "VEC3": 3
        case "VEC4", "MAT2": 4
        case "MAT3": 9
        case "MAT4": 16
        default: 0
        }
    }

    func view(_ i: Int) -> (data: ArraySlice<UInt8>, stride: Int?)? {
        let v = json["bufferViews"][i]
        guard v.isObject, (v["buffer"].int ?? 0) == 0, json["buffers"][0]["uri"].string == nil else { return nil }
        let off = v["byteOffset"].int ?? 0, len = v["byteLength"].int ?? 0
        guard off >= 0, len >= 0, off + len <= bin.count else { return nil }
        let stride = v["byteStride"].int
        if let stride, stride <= 0 { return nil }
        return (bin[off..<off + len], stride)
    }

    static func scalar(_ d: ArraySlice<UInt8>, _ at: Int, _ type: Int, normalized: Bool) -> Double {
        let b = d.startIndex + at
        switch type {
        case 5120:
            let v = Int8(bitPattern: d[b])
            return normalized ? Double(max(Float(v) / 127, -1)) : Double(v)
        case 5121:
            return normalized ? Double(Float(d[b]) / 255) : Double(d[b])
        case 5122:
            let v = Int16(bitPattern: UInt16(d[b]) | UInt16(d[b + 1]) << 8)
            return normalized ? Double(max(Float(v) / 32767, -1)) : Double(v)
        case 5123:
            let v = UInt16(d[b]) | UInt16(d[b + 1]) << 8
            return normalized ? Double(Float(v) / 65535) : Double(v)
        case 5125:
            return Double(UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24)
        default:
            let bits = UInt32(d[b]) | UInt32(d[b + 1]) << 8 | UInt32(d[b + 2]) << 16 | UInt32(d[b + 3]) << 24
            return Double(Float(bitPattern: bits))
        }
    }

    func accessor(_ i: Int, normalize: Bool = false) -> [[Double]]? {
        let a = json["accessors"][i]
        guard a.isObject, let count = a["count"].uint, count <= Self.maxCount, let ct = a["componentType"].int,
              Self.componentTypes.contains(ct), let t = a["type"].string
        else { return nil }
        let n = Self.components(t), size = Self.componentSize(ct)
        guard n > 0 else { return nil }
        let norm = normalize && ct != 5126
        var out = Array(repeating: Array(repeating: 0.0, count: n), count: count)
        if let bv = a["bufferView"].int {
            guard let (data, s) = view(bv) else { return nil }
            let off = a["byteOffset"].uint ?? 0
            // ponytail: MAT2・MAT3 の 1・2 バイトの成分の列の 4 バイト境界は未対応。使い始めたら足す
            let stride = s ?? n * size
            guard stride >= n * size, stride <= 1024,
                  count == 0 || off + (count - 1) * stride + n * size <= data.count else { return nil }
            for e in 0..<count {
                for c in 0..<n { out[e][c] = Self.scalar(data, off + e * stride + c * size, ct, normalized: norm) }
            }
        }
        let sp = a["sparse"]
        if sp.isObject, let sc = sp["count"].uint {
            let ix = sp["indices"], vs = sp["values"]
            guard sc <= count, let (id, _) = view(ix["bufferView"].int ?? -1), let (vd, _) = view(vs["bufferView"].int ?? -1),
                  let ict = ix["componentType"].int, [5121, 5123, 5125].contains(ict) else { return nil }
            let io = ix["byteOffset"].uint ?? 0, vo = vs["byteOffset"].uint ?? 0
            let isz = Self.componentSize(ict)
            guard io + sc * isz <= id.count, vo + sc * n * size <= vd.count else { return nil }
            for k in 0..<sc {
                let target = Int(Self.scalar(id, io + k * isz, ict, normalized: false))
                guard target < count else { return nil }
                for c in 0..<n { out[target][c] = Self.scalar(vd, vo + (k * n + c) * size, ct, normalized: norm) }
            }
        }
        return out
    }

    func floats(_ i: Int, normalize: Bool = false) -> [[Float]]? { accessor(i, normalize: normalize)?.map { $0.map(Float.init) } }

    static func nodeMatrix(_ n: JSONValue) -> simd_float4x4? {
        guard let m = n["matrix"].array, m.count == 16 else { return nil }
        let v = m.map(\.f)
        return simd_float4x4(SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                             SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
    }

    /// 書いていない・数の合わない値は既定（移動 0・回転なし・拡大 1）。
    static func nodeTRS(_ n: JSONValue) -> (SIMD3<Float>, simd_quatf, SIMD3<Float>) {
        func vector(_ key: String, _ count: Int) -> [Float]? { n[key].array.flatMap { $0.count == count ? $0.map(\.f) : nil } }
        return (vector("translation", 3).map { SIMD3($0[0], $0[1], $0[2]) } ?? .zero,
                vector("rotation", 4).map { simd_quatf(ix: $0[0], iy: $0[1], iz: $0[2], r: $0[3]) } ?? Math.identity,
                vector("scale", 3).map { SIMD3($0[0], $0[1], $0[2]) } ?? SIMD3(1, 1, 1))
    }

    /// ノードの木。子は範囲内で、最初に辿り着いた親だけを親とする（輪や親が二つあるノードを木に直す）。
    /// `order` は根からの前順で、根から届かないノードは入らない。
    static func tree(_ nodes: [JSONValue]) -> (children: [[Int]], parent: [Int?], order: [Int]) {
        let listed = nodes.map { ($0["children"].array ?? []).compactMap(\.uint).filter { $0 < nodes.count } }
        var hasParent = [Bool](repeating: false, count: nodes.count)
        for cs in listed { for c in cs { hasParent[c] = true } }
        var children = [[Int]](repeating: [], count: nodes.count)
        var parent = [Int?](repeating: nil, count: nodes.count)
        var seen = [Bool](repeating: false, count: nodes.count)
        var order: [Int] = []
        for root in nodes.indices where !hasParent[root] {
            seen[root] = true
            var stack = [root]
            while let n = stack.popLast() {
                order.append(n)
                for c in listed[n] where !seen[c] {
                    seen[c] = true
                    parent[c] = n
                    children[n].append(c)
                }
                stack += children[n].reversed()
            }
        }
        return (children, parent, order)
    }

    /// 要素の成分の数が決まっているときに使う（`$0[k]` で読んでも範囲外にならない）
    func floats(_ i: Int, components: Int, normalize: Bool = false) -> [[Float]]? {
        guard let a = floats(i, normalize: normalize), a.first.map({ $0.count == components }) ?? true else { return nil }
        return a
    }
}

indirect enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case number(Double, integer: Bool)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed])
        return JSONValue(any)
    }

    init(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else {
                self = .number(n.doubleValue, integer: !CFNumberIsFloatType(n))
            }
        case let a as [Any]: self = .array(a.map(JSONValue.init))
        case let d as [String: Any]: self = .object(d.mapValues(JSONValue.init))
        default: self = .null
        }
    }

    subscript(_ key: String) -> JSONValue {
        if case let .object(o) = self { o[key] ?? .null } else { .null }
    }

    subscript(_ i: Int) -> JSONValue {
        if case let .array(a) = self, i >= 0, i < a.count { a[i] } else { .null }
    }

    var isObject: Bool { if case .object = self { true } else { false } }
    var isArray: Bool { if case .array = self { true } else { false } }
    var string: String? { if case let .string(s) = self { s } else { nil } }
    var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
    var array: [JSONValue]? { if case let .array(a) = self { a } else { nil } }
    var double: Double? { if case let .number(d, _) = self { d } else { nil } }
    var int: Int? { if case let .number(d, true) = self, let i = Int(exactly: d) { i } else { nil } }
    var uint: Int? { int.flatMap { $0 >= 0 ? $0 : nil } }
    /// 辞書の順は実行ごとに変わるのでキーのバイト順に。
    var entries: [(String, JSONValue)] {
        guard case let .object(o) = self else { return [] }
        return o.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
    }

    var f: Float { Float(double ?? 0) }
}
