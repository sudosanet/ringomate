import CoreGraphics
import Foundation
import FoundationModels
import os
import Vision

@MainActor
public final class Chatter {
    private var busy = false
    public var tools: ToolPicker = { [] }
    public var style = AIStyle()
    /// 似た言葉を続けないための最近の行（UserDefaults に書くと設定の変更通知が毎回飛ぶのでメモリだけ）
    private var recent: [String] = []
    private let log = Logger(subsystem: "app.ringomate", category: "chat")

    public init() {}

    public var available: Bool { OnDevice.available }

    public var canSee: Bool {
        if let c = seeCache, Date().timeIntervalSince(c.at) < 60 { return c.value }
        let v = available && SystemLanguageModel.default.capabilities.contains(.vision)
        seeCache = (v, Date())
        return v
    }

    private var seeCache: (value: Bool, at: Date)?

    public func line(for reason: String, always: [String] = [], extra: [String] = [], image: CGImage? = nil) async -> String? {
        guard available, style.language.supported, !busy else { return nil }
        busy = true
        defer { busy = false }
        let image = canSee ? image : nil
        for attempt in 0..<2 {
            let facts = always + extra.shuffled().prefix(2)
            guard let line = await generate(reason: reason, facts: facts, image: image) else { return nil }
            guard style.language.matches(line) else {
                log.info("chat \(attempt) wrong language: \(line, privacy: .private)")
                continue
            }
            let again = recent.contains { Self.similar($0, line) }
            log.info("chat \(attempt) reason \(reason, privacy: .public) facts \(facts.joined(separator: "; "), privacy: .private) line \(line, privacy: .private)\(again ? " (similar)" : "", privacy: .public)")
            if !again {
                recent = Array((recent + [line]).suffix(style.recentCount))
                if style.useTools { act(line) }
                return line
            }
        }
        return nil
    }

    /// 2-gram の重なり。日本語は文字、英語などは語で数える（英語を文字で数えるとほとんどが重なる）。
    nonisolated static func similar(_ a: String, _ b: String) -> Bool {
        func grams(_ s: String) -> Set<String> {
            let c: [String] = SpeechLanguage.isCJK(s)
                ? s.filter { !$0.isPunctuation && !$0.isWhitespace }.map(String.init)
                : s.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
            return c.count < 2 ? Set(c) : Set((0..<c.count - 1).map { c[$0] + " " + c[$0 + 1] })
        }
        let (x, y) = (grams(a), grams(b))
        guard !x.isEmpty, !y.isEmpty else { return a == b }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.5
    }

    /// 動きは決まったセリフに合わせて別に頼む（セリフと一緒に道具を渡すと、動きを文で書いたり `**Move**` を書いたりする）。
    private func act(_ line: String) {
        let tools = self.tools()
        guard !tools.isEmpty else { return }
        let session = LanguageModelSession.persona(style.character, tools: tools)
        Task {
            _ = try? await session.respond(
                to: "You are about to say this to your owner: \(line)\nAct it out: if a body movement, a prop or an expression fits the line, call one tool. At most one. If nothing fits, answer none.",
                options: GenerationOptions(maximumResponseTokens: 40))
        }
    }

    private func generate(reason: String, facts: [String], image: CGImage?) async -> String? {
        let tools: [any Tool] = image == nil ? [] : [OCRTool()]
        let session = LanguageModelSession.persona("""
            \(style.character)
            Reply with just one short line in the character's spoken style, \(style.language.limit(style.lineLength)). Don't use emoji, decorative symbols, or quotation marks (normal punctuation is fine).
            Say something specific to this moment, based on the trigger and the current situation. Don't make up anything that isn't in the situation.
            Don't end with only a stock phrase such as "Good luck" or "Nice work".
            \(image == nil ? "" : """
            The image is the screen your owner is looking at right now. Comment on what they're doing or what's on it. Never read out \
            personal information such as people's names, email addresses, phone numbers, addresses, passwords, or amounts of money.
            """)
            """, tools: tools)
        do {
            let ask = "Trigger: \(reason)\(facts.isEmpty ? "" : "\nCurrent situation: " + facts.joined(separator: "; "))"
                + style.language.reminder
            let prompt = image.map { img in Prompt { ask; Attachment(img).label("Your owner's screen") } } ?? Prompt(ask)
            let r = try await session.respond(
                to: prompt,
                options: GenerationOptions(sampling: .random(top: 40), temperature: style.temperature, maximumResponseTokens: max(80, style.lineLength * 4)))
            let text = OnDevice.trimmed(OnDevice.firstLine(r.content))
            guard !text.isEmpty else { return nil }
            return style.language.clip(text, style.lineLength * 7 / 5)
        } catch {
            log.error("chat failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
