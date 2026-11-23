import Foundation
import FoundationModels

/// マスコットが話す言語。UI とそろえるため、アプリの表示の言語に合わせる。
public enum SpeechLanguage: Sendable {
    case japanese, english

    public static var current: SpeechLanguage { Bundle.main.preferredLocalizations.first == "ja" ? .japanese : .english }

    var locale: Locale {
        let code: Locale.LanguageCode = self == .japanese ? .japanese : .english
        return Locale.current.language.languageCode == code ? Locale.current : Locale(identifier: self == .japanese ? "ja_JP" : "en_US")
    }

    /// 「Supporting languages and locales with Foundation Models」の決まり文句（この英語のまま。en_US は省く）。
    var instructions: String {
        let id = locale.identifier
        return (id == "en_US" ? "" : "The person's locale is \(id).\n")
            + "You MUST respond in \(self == .japanese ? "Japanese" : "English")."
    }

    public var supported: Bool { SystemLanguageModel.default.supportsLocale(locale) }

    /// 長さの設定は日本語の文字数で持ち、英語ではおよそ半分の語数にする。
    func limit(_ characters: Int) -> String {
        self == .japanese ? "in at most \(characters) Japanese characters" : "in at most \(max(1, characters / 2)) words"
    }

    /// 長すぎたら切る。日本語は、切った中の後ろ半分に区切り（文の終わり → … → 、の順）があればそこまでにする。
    func clip(_ text: String, _ characters: Int) -> String {
        guard self == .english else {
            guard text.count > characters else { return text }
            let cut = Array(text.prefix(characters))
            for marks in ["。！？!?", "…", "、"] {
                guard var i = cut.lastIndex(where: { marks.contains($0) }), i >= characters / 2 else { continue }
                while i + 1 < cut.count, cut[i + 1] == "…" { i += 1 }
                return String(cut[...i])
            }
            return String(cut)
        }
        return text.split(separator: " ").prefix(max(1, characters / 2)).joined(separator: " ")
    }

    /// 端末内のモデルは英語の状況説明に引っぱられて英語で返すことがあるので、出てきた文を確かめる。
    func matches(_ text: String) -> Bool {
        self == .english || Self.isCJK(text)
    }

    /// 頼みの最後に添える一文（指示だけだと守らないことがある）。
    var reminder: String { self == .japanese ? "\n(Reply in Japanese.)" : "" }

    /// かな・漢字を含むか（日本語・中国語は文字、ほかは語で数える）。
    public static func isCJK(_ s: some StringProtocol) -> Bool {
        s.unicodeScalars.contains { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) }
    }

    /// 吹き出しを出しておく秒数。
    public static func readingSeconds(_ text: String) -> Float {
        max(5, Float(text.count) / (isCJK(text) ? 8 : 18))
    }
}
