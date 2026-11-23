import CoreGraphics
import FoundationModels

@MainActor
public enum ObjectNamer {
    @Generable
    public struct Description: Sendable {
        @Guide(description: "A short name for the object in the picture. If it isn't an object, answer none")
        public var name: String
        @Guide(description: "Whether it is a sturdy object with a flat top that a small doll could sit on")
        public var sittable: Bool
        @Guide(description: "One short line from the character who found it, in the character's spoken style, without emoji")
        public var comment: String
    }

    public static func describe(_ image: CGImage, style: AIStyle = AIStyle()) async -> Description? {
        guard SystemLanguageModel.default.capabilities.contains(.vision), style.language.supported,
              OnDevice.available else { return nil }
        let session = LanguageModelSession(model: .default, instructions: "\(style.character)\nLook at the object in the desktop wallpaper and answer.")
        guard let r = try? await session.respond(to: Prompt { "What is this?"; Attachment(image) }, generating: Description.self,
                                                 options: GenerationOptions(maximumResponseTokens: 120)),
              !["none", "なし"].contains(r.content.name.lowercased()), !r.content.name.isEmpty else { return nil }
        var d = r.content
        d.name = style.language.clip(d.name, 10)
        d.comment = style.language.clip(d.comment, 24)
        return d
    }
}
