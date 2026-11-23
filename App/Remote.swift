import AI
import Agent
import Behavior
import Foundation
import Overlay
import Settings

@MainActor
final class Remote {
    private let mascot: Mascot
    init(mascot: Mascot) {
        self.mascot = mascot
    }

    weak var overlay: OverlayController?
    /// 非表示のあいだは許可の確認をターミナルに任せ、ツールは断る
    var hidden = false {
        didSet {
            guard hidden, let r = pendingReply else { return }
            pendingReply = nil
            overlay?.choice = nil
            r([:])
        }
    }
    private var pendingReply: HookServer.Reply?
    static let hiddenText = "RingoMate is hidden"

    lazy var say: (String) -> Void = { [mascot] in mascot.say($0) }

    func answer(_ request: HookServer.Request, reply: @escaping HookServer.Reply) {
        if hidden {
            if case .permission = request { return reply([:]) }
            return reply(["text": Self.hiddenText, "error": true])
        }
        switch request {
        case let .tool("compose_motion", args):
            Task { [weak self] in
                guard let self else { return reply(["text": "RingoMate has stopped", "error": true]) }
                let (text, ok) = await compose(args["description"] ?? "")
                reply(["text": text, "error": !ok])
            }
        case let .tool(name, args):
            let (text, ok) = tool(name, args)
            reply(["text": text, "error": !ok])
        case let .permission(_, tool, summary):
            ask(tool: tool, summary: summary, reply: reply)
        }
    }

    private func ask(tool: String, summary: String, reply: @escaping HookServer.Reply) {
        guard UserDefaults.standard.bool(forKey: SettingsKey.answerPermissions),
              PermissionKind(tool: tool).map(PermissionKind.allowed().contains) == true, let overlay,
              summary.unicodeScalars.count <= HookServer.maxPermissionSummary, !summary.contains(where: \.isNewline)
        else { return reply([:]) }
        let text = summary.isEmpty ? tool : "\(tool): \(summary)"
        pendingReply = reply
        overlay.choice = (String(localized: "OK to do this? \(text)"), { [weak self] allow in
            self?.pendingReply = nil
            reply(["decision": allow ? "allow" : "deny"])
        })
        let prompt = overlay.choice?.prompt
        Task { @MainActor [weak self, weak overlay] in
            try? await Task.sleep(for: .seconds(HookServer.replyTimeout))
            if overlay?.choice?.prompt == prompt {
                overlay?.choice = nil
                self?.pendingReply = nil
            }
        }
    }

    var playComposed: ((String) throws -> String)?
    private let composer = Composer()

    func compose(_ description: String) async -> (String, Bool) {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return ("description is empty", false) }
        guard let json = await composer.compose(text), let play = playComposed,
              (try? play(json)) != nil else {
            mascot.perform(.nod)
            return ("Couldn't compose the motion, so it nodded instead", false)
        }
        return mascot.performComposed() ? ("Performed the composed motion", true) : ("Composed the motion, but can't move right now", false)
    }

    func tool(_ name: String, _ args: [String: String]) -> (String, Bool) {
        guard !hidden else { return (Self.hiddenText, false) }
        let state = mascot.summary
        switch name {
        case "say":
            let raw = (args["text"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let text = String(raw.prefix(SpeechLanguage.isCJK(raw) ? 40 : 80))
            guard !text.isEmpty else { return ("text is empty", false) }
            guard mascot.canSpeak else { return ("Can't speak right now (\(state.activity)\(state.sleepy ? ", sleepy" : ""))", false) }
            say(text)
            return ("Said it", true)
        case "perform":
            guard let p = Mascot.Performance(rawValue: args["action"] ?? "") else {
                return ("action must be one of \(Mascot.Performance.allCases.map(\.rawValue).joined(separator: ", "))", false)
            }
            return mascot.perform(p) ? ("Done", true) : ("Can't do that right now (\(state.activity))", false)
        case "express":
            guard let e = Mascot.Expression.allCases.first(where: { "\($0)" == args["expression"] }) else {
                return ("Unknown expression", false)
            }
            mascot.express(e, seconds: Float(args["seconds"] ?? "") ?? 2)
            return ("Showed the expression", true)
        case "get_state":
            let mood = String(format: "%.2f", state.mood), energy = String(format: "%.2f", state.energy)
            return ("activity: \(state.activity), sleepy: \(state.sleepy), mood: \(mood), energy: \(energy)", true)
        default:
            return ("unknown tool \(name)", false)
        }
    }
}
