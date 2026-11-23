import FoundationModels

public typealias ToolPicker = @MainActor () -> [any Tool]

struct Persona: LanguageModelSession.DynamicProfile {
    let instructions: String
    let tools: [any Tool]

    var body: some LanguageModelSession.DynamicProfile {
        Profile {
            Instructions(instructions)
            tools
        }
    }
}

extension LanguageModelSession {
    @MainActor
    static func persona(_ instructions: String, tools: [any Tool]) -> LanguageModelSession {
        tools.isEmpty
            ? LanguageModelSession(model: .default, instructions: instructions)
            : LanguageModelSession(profile: Persona(instructions: instructions, tools: tools))
    }
}
