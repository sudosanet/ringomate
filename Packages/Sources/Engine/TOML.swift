import Foundation
import TOMLKit

/// ponytail: 日時は未対応。使い始めたら足す。
public enum TOML: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case float(Double)
    case bool(Bool)
    case array([TOML])
    case table([String: TOML])

    public static func parse(_ text: String) throws -> [String: TOML] {
        let table: TOMLTable
        do {
            table = try TOMLTable(string: text)
        } catch let e as TOMLParseError {
            throw TOMLError(line: e.source.begin.line, message: e.description)
        }
        return try convert(table)
    }

    static func convert(_ t: TOMLTable) throws -> [String: TOML] {
        var out: [String: TOML] = [:]
        for (k, v) in t { out[k] = try convert(v) }
        return out
    }

    static func convert(_ v: TOMLValueConvertible) throws -> TOML {
        switch v.type {
        case .string: return .string(v.string ?? "")
        case .int: return .int(Int64(v.int ?? 0))
        case .double: return .float(v.double ?? 0)
        case .bool: return .bool(v.bool ?? false)
        case .array: return try .array((v.array.map(Array.init) ?? []).map(convert))
        case .table: return try .table(v.table.map(convert) ?? [:])
        default: throw TOMLError(line: 0, message: "dates are not supported")
        }
    }

    public subscript(key: String) -> TOML? {
        if case let .table(t) = self { t[key] } else { nil }
    }

    public var string: String? { if case let .string(s) = self { s } else { nil } }
    public var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
    public var array: [TOML]? { if case let .array(a) = self { a } else { nil } }
    public var table: [String: TOML]? { if case let .table(t) = self { t } else { nil } }
    var double: Double? {
        switch self {
        case let .float(f): f
        case let .int(i): Double(i)
        default: nil
        }
    }
    public var int: Int64? { if case let .int(i) = self { i } else { nil } }
}

struct TOMLError: Error, CustomStringConvertible {
    let line: Int
    let message: String
    var description: String { "TOML line \(line): \(message)" }
}
