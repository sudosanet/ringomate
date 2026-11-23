import Foundation
import FoundationModels

enum OnDevice {
    static var available: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// 最初に使える行。空の行と、道具の呼び出しを文字で書いた行（`**Move**`・`{value:…}` など）は飛ばす。
    static func firstLine(_ s: String) -> String {
        s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && $0.range(of: #"\*\*|\{value|<ctrl|^\[[^\]]*\]$"#, options: .regularExpression) == nil } ?? ""
    }

    private static let quotes: [(Character, Character)] = [("「", "」"), ("『", "』"), ("\"", "\""), ("“", "”")]

    /// 前後の空白と絵文字を落とす。かっこは文全体を囲んでいるときだけ外す（`「曲名」、…` の頭だけ消さない）。
    /// 構造化出力の文の終わりに付くゴミ（`」}`・`」}```json …`・`<ctrl46>`）から後ろは捨てる。
    static func trimmed(_ s: String) -> String {
        var t = String(s.unicodeScalars.filter { !$0.properties.isEmojiPresentation }.map(Character.init))
        if let junk = t.range(of: #"[}{]|```|<ctrl"#, options: .regularExpression) { t = String(t[..<junk.lowerBound]) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in quotes where open != close && t.last == close && t.filter({ $0 == close }).count > t.filter({ $0 == open }).count {
            t = String(t.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in quotes where t.count >= 2 && t.first == open && t.last == close {
            let inner = t.dropFirst().dropLast()
            if !inner.contains(open), !inner.contains(close) { t = inner.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return t
    }
}
