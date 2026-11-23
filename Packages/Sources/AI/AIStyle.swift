import Foundation

/// しゃべり方と会話の決まり。アプリが設定から組み立てて渡す。
public struct AIStyle: Sendable {
    public static let defaultPersona = "A small character who lives on the computer desktop. Spends its days near its owner and talks in a bright, gentle, casual way."

    public var persona = defaultPersona
    public var name = ""
    public var ownerCall = ""
    /// 日本語の文字数（英語はおよそ半分の語数）
    public var lineLength = 20
    public var replyLength = 40
    public var temperature = 1.0
    public var recentCount = 12
    public var useTools = true
    public var memory = true
    public var turnsBeforeSummary = 8
    public var actAfterReply = true
    public var language = SpeechLanguage.current

    public init() {}

    var character: String {
        var s = "You are the following character.\n\(persona.isEmpty ? Self.defaultPersona : persona)"
        if !name.isEmpty { s += "\nYour name is \"\(name)\"." }
        if !ownerCall.isEmpty { s += "\nYou call your owner \"\(ownerCall)\"." }
        return s + "\n" + language.instructions
    }
}
