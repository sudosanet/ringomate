import Foundation
import FoundationModels

/// ponytail: 候補は診断レポートに出すだけ。当てるにはユーザーのプロファイル（`[aliases]`）に書く。
@MainActor
public final class BoneAssist {
    @Generable
    public struct Guess: Sendable {
        @Guide(description: "The MMD standard bone name being searched for (one of the inputs)")
        public var standard: String
        @Guide(description: "The most likely name chosen from the model's bone list, or empty if none")
        public var candidate: String
    }

    @Generable
    public struct Guesses: Sendable {
        @Guide(description: "A candidate for each standard bone", .maximumCount(24))
        public var guesses: [Guess]
    }

    public init() {}

    public var available: Bool { OnDevice.available }

    public func suggest(missing: [String], bones: [String]) async -> [(standard: String, candidate: String)] {
        guard available, !missing.isEmpty, !bones.isEmpty else { return [] }
        let session = LanguageModelSession(model: .default, instructions: """
            You are an assistant who knows 3D character bone names well. For each MMD standard bone (for example 左ひじ = left elbow, \
            左足首 = left ankle, 下半身 = lower body root below the waist), you pick the matching bone from the model's bone list \
            (a mix of Japanese, Chinese, and English).
            """)
        let list = bones.prefix(400).joined(separator: ", ")
        let prompt = "Standard bones to find: \(missing.joined(separator: ", "))\nModel bone names: \(list)"
        guard let r = try? await session.respond(to: prompt, generating: Guesses.self,
                                                 options: GenerationOptions(maximumResponseTokens: 800)) else { return [] }
        return r.content.guesses.compactMap { g in
            missing.contains(g.standard) && bones.contains(g.candidate) ? (g.standard, g.candidate) : nil
        }
    }
}
