import Foundation
import FoundationModels

/// ponytail: 時刻やいまの様子は Tool にせず前提の文に入れる。毎回要るものになったら Tool へ。
/// 予定・最前面のアプリなど個人情報に触れる道具は持たない。
@MainActor
public final class Conversation {
    /// 生成は宣言の順なので、表情を先に置く。
    @Generable
    public struct Reply: Sendable {
        @Guide(description: "AU6 cheek raiser (smiling eyes), intensity 0 to 1", .range(0...1))
        public var au6CheekRaise: Double
        @Guide(description: "AU12 lip corner puller (smile), intensity 0 to 1", .range(0...1))
        public var au12LipCornerPull: Double
        @Guide(description: "AU1+2 brow raiser (surprise, interest), intensity 0 to 1", .range(0...1))
        public var au1BrowRaise: Double
        @Guide(description: "AU4 brow lowerer (anger, annoyance), intensity 0 to 1", .range(0...1))
        public var au4BrowLower: Double
        @Guide(description: "AU15 lip corner depressor (troubled, sad), intensity 0 to 1", .range(0...1))
        public var au15LipCornerDepress: Double
        @Guide(description: "AU26 jaw drop (surprise, big laugh), intensity 0 to 1", .range(0...1))
        public var au26JawDrop: Double
        @Guide(description: "Blush (embarrassment), intensity 0 to 1", .range(0...1))
        public var blush: Double
        @Guide(description: "The reply shown in the speech bubble, in the character's spoken style and the length you were told. No emoji, decorative symbols, or quotation marks; normal punctuation is fine")
        public var text: String

        public static func expressionWeights(au6: Double?, au12: Double?, au1: Double?, au4: Double?, au15: Double?,
                                             au26: Double?, blush: Double?) -> [String: Float] {
            let c = { (v: Double?) in Float(min(max(v ?? 0, 0), 1)) }
            let (cheek, lip, brow, lower, sad, jaw) = (c(au6), c(au12), c(au1), c(au4), c(au15), c(au26))
            return [
                "smile": max(lip, cheek * 0.6),
                "calm": cheek * (1 - lip) * 0.6,
                "surprise": min(brow, max(jaw, 0.5)) * (1 - lower),
                "mouthOpen": jaw * 0.8,
                "angry": lower * (1 - lip),
                "troubled": min(sad, max(brow, 0.4)) * (1 - lip),
                "blush": c(blush),
            ].filter { $0.value > 0.05 }
        }

        public var expressionWeights: [String: Float] {
            Self.expressionWeights(au6: au6CheekRaise, au12: au12LipCornerPull, au1: au1BrowRaise, au4: au4BrowLower,
                                   au15: au15LipCornerDepress, au26: au26JawDrop, blush: blush)
        }
    }

    struct Memory: Codable {
        var summary = ""
        var turns: [Turn] = []
    }

    struct Turn: Codable {
        var user: String
        var mascot: String
    }

    private let memoryURL: URL
    private(set) var memory: Memory
    public var summary: String { memory.summary }
    private var busy = false
    public var tools: ToolPicker = { [] }
    public var style = AIStyle()

    public init(memoryURL: URL) {
        self.memoryURL = memoryURL
        memory = (try? JSONDecoder().decode(Memory.self, from: Data(contentsOf: memoryURL))) ?? Memory()
    }

    public var available: Bool { OnDevice.available }

    public func reply(to text: String, context: String,
                      onFace: @MainActor ([String: Float]) -> Void = { _ in }) async -> Reply? {
        if let r = await attempt(text, context, onFace) { return r }
        return await attempt(text, context, onFace)
    }

    private func attempt(_ text: String, _ context: String,
                         _ onFace: @MainActor ([String: Float]) -> Void) async -> Reply? {
        guard available, style.language.supported, !busy else { return nil }
        busy = true
        defer { busy = false }
        let remember = style.memory
        let recent = !remember ? "" : memory.turns.suffix(4).map { "Owner: \"\($0.user)\" → You: \"\($0.mascot)\"" }.joined(separator: "\n")
        let tools = style.useTools ? self.tools() : []
        let session = LanguageModelSession.persona("""
            \(style.character)
            You live on your owner's desktop and keep them company. When spoken to, you reply briefly, \(style.language.limit(style.replyLength)).
            Current situation: \(context)
            Summary of past conversations: \(!remember || memory.summary.isEmpty ? "none yet" : memory.summary)
            Recent exchanges:
            \(recent.isEmpty ? "none yet" : recent)
            """, tools: tools)
        do {
            let stream = session.streamResponse(to: String(text.prefix(400)) + style.language.reminder, generating: Reply.self,
                                                options: GenerationOptions(maximumResponseTokens: 300))
            var faced = false
            for try await snapshot in stream {
                let p = snapshot.content
                if !faced, p.blush != nil {
                    faced = true
                    onFace(Reply.expressionWeights(au6: p.au6CheekRaise, au12: p.au12LipCornerPull, au1: p.au1BrowRaise,
                                                   au4: p.au4BrowLower, au15: p.au15LipCornerDepress, au26: p.au26JawDrop,
                                                   blush: p.blush))
                }
            }
            var r = try await stream.collect().content
            r.text = style.language.clip(OnDevice.trimmed(r.text), style.replyLength)
            guard !r.text.isEmpty else { return nil }
            // 違う言語なら reply(to:) がもう 1 度だけ作り直す
            guard style.language.matches(r.text) else {
                lastError = "replied in another language: \(r.text.prefix(40))"
                return nil
            }
            if !tools.isEmpty, style.actAfterReply {
                _ = try? await session.respond(
                    to: "Now act out your reply: if the user asked for a movement or your reply mentions one, call the matching tool. If nothing fits, answer none.",
                    options: GenerationOptions(maximumResponseTokens: 40))
            }
            if remember {
                memory.turns.append(Turn(user: String(text.prefix(200)), mascot: r.text))
                if memory.turns.count > style.turnsBeforeSummary { await summarize() }
                save()
            }
            return r
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    public private(set) var lastError: String?

    public func setSummary(_ text: String) {
        memory.summary = String(text.prefix(400))
        save()
    }

    public func forget() {
        memory = Memory()
        save()
    }

    private func summarize() async {
        let log = memory.turns.map { "Owner: \($0.user)\nYou: \($0.mascot)" }.joined(separator: "\n")
        let session = LanguageModelSession(model: .default, instructions: """
            Summarize the conversation \(style.language.limit(200)), so that your owner's preferences and what happened are clear.
            \(style.language.instructions)
            """)
        guard let r = try? await session.respond(to: "Summary so far: \(memory.summary)\n\nNew conversation:\n\(log)",
                                                 options: GenerationOptions(maximumResponseTokens: 400)) else { return }
        memory.summary = style.language.clip(r.content, 200)
        memory.turns = Array(memory.turns.suffix(2))
    }

    private func save() {
        try? FileManager.default.createDirectory(at: memoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(memory).write(to: memoryURL, options: .atomic)
    }
}
