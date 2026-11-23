import Behavior
import Foundation
import FoundationModels
import os

/// 道具の説明は英語で書く（日本語だと端末内のモデルが道具を呼ばない）。
@MainActor
final class AITools {
    private let mascot: Mascot
    private let makeMotion: (String) async -> Bool
    private var used = false
    private let log = Logger(subsystem: "app.ringomate", category: "tools")

    init(mascot: Mascot, makeMotion: @escaping (String) async -> Bool) {
        self.mascot = mascot
        self.makeMotion = makeMotion
    }

    func begin() { used = false }

    func pick(working: Bool, music: Bool, talking: Bool) -> [any Tool] {
        let contents = Array(Set(mascot.gestureNames.compactMap { $0.split(separator: ":").first.map(String.init) })).sorted()
        var tools: [any Tool] = [
            choice("express", "Show a facial expression for a few seconds.", ["smile", "surprise", "blush", "wink", "troubled", "angry", "calm"]) { [mascot] v in
                guard let e = Mascot.Expression.allCases.first(where: { "\($0)" == v }) else { return false }
                mascot.express(e, weight: 0.9, seconds: 3)
                return true
            },
        ]
        if !contents.isEmpty {
            tools.append(choice("gesture", "Do a body gesture (bow, wave, dance and so on), chosen by its name.", contents) { [mascot] v in
                mascot.request(.gesture(v))
            })
        }
        if !working {
            tools.append(choice("hold", "Hold a small prop for a while.", Mascot.Prop.held.map(\.label)) { [mascot] v in
                guard let p = Mascot.Prop.held.first(where: { $0.label == v }) else { return false }
                return mascot.request(.prop(p))
            })
            tools.append(choice("sit", "Go and sit on top of a nearby window.", ["window"]) { [mascot] _ in mascot.request(.sit) })
        }
        if music {
            tools.append(choice("dance", "Dance to the music that is playing.", ["now"]) { [mascot] _ in mascot.request(.dance) })
        }
        if talking || !working {
            tools.append(text("move", "Describe an upper-body movement in one short sentence (for example: wave both hands happily) and do it.") {
                [makeMotion] sentence in await makeMotion(sentence)
            })
        }
        return tools
    }

    private func choice(_ name: String, _ description: String, _ values: [String],
                        act: @escaping @MainActor (String) -> Bool) -> ActionTool {
        let schema = DynamicGenerationSchema(name: name, properties: [
            .init(name: "value", schema: DynamicGenerationSchema(name: "\(name)Value", anyOf: values)),
        ])
        return tool(name, description, schema) { act($0) }
    }

    private func text(_ name: String, _ description: String, act: @escaping @MainActor (String) async -> Bool) -> ActionTool {
        let schema = DynamicGenerationSchema(name: name, properties: [
            .init(name: "value", schema: DynamicGenerationSchema(type: String.self)),
        ])
        return tool(name, description, schema, act: act)
    }

    private func tool(_ name: String, _ description: String, _ schema: DynamicGenerationSchema,
                      act: @escaping @MainActor (String) async -> Bool) -> ActionTool {
        let parameters = (try? GenerationSchema(root: schema, dependencies: [])) ?? String.generationSchema
        return ActionTool(name: name, description: description, parameters: parameters) { [weak self] content in
            let value = (try? content.value(String.self, forProperty: "value")) ?? ""
            return await MainActor.run { self?.claim() ?? false } ? await act(value) : false
        } done: { [log] ok, value in
            log.info("tool \(name, privacy: .public)(\(value, privacy: .private)) \(ok ? "ok" : "skipped", privacy: .public)")
        }
    }

    private func claim() -> Bool {
        defer { used = true }
        return !used
    }
}

struct ActionTool: Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let act: @Sendable (GeneratedContent) async -> Bool
    let done: @Sendable (Bool, String) -> Void

    init(name: String, description: String, parameters: GenerationSchema,
         act: @escaping @Sendable (GeneratedContent) async -> Bool, done: @escaping @Sendable (Bool, String) -> Void) {
        (self.name, self.description, self.parameters, self.act, self.done) = (name, description, parameters, act, done)
    }

    @concurrent
    func call(arguments: GeneratedContent) async throws -> String {
        let ok = await act(arguments)
        done(ok, (try? arguments.value(String.self, forProperty: "value")) ?? "")
        return ok ? "done" : "not possible right now"
    }
}
