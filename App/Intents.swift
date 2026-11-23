import AppIntents
import AppKit
import Behavior

@MainActor
private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

struct TalkToMascotIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to the Mascot"
    static let description = IntentDescription("Talk to it and the mascot replies in a speech bubble (on-device model).")

    @Parameter(title: "Words")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let reply = await app?.talk(text) ?? String(localized: "RingoMate isn't running")
        return .result(dialog: "\(reply)")
    }
}

enum PerformanceOption: String, AppEnum {
    case wave, bigWave, bow, beckon, reply, bothHandsWave, cheer, dance, nod, stretch, hop

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Gesture"
    static let caseDisplayRepresentations: [PerformanceOption: DisplayRepresentation] = [
        .wave: "Wave", .bigWave: "Big Wave", .bow: "Bow", .beckon: "Beckon", .reply: "Reply",
        .bothHandsWave: "Wave with Both Hands", .cheer: "Cheer", .dance: "Dance", .nod: "Nod",
        .stretch: "Stretch", .hop: "Hop",
    ]
}

struct PerformMotionIntent: AppIntent {
    static let title: LocalizedStringResource = "Make the Mascot Gesture"

    @Parameter(title: "Gesture")
    var motion: PerformanceOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let p = Mascot.Performance(rawValue: motion.rawValue), let app else {
            return .result(dialog: "RingoMate isn't running")
        }
        let (_, ok) = app.remote.tool("perform", ["action": p.rawValue])
        return .result(dialog: ok ? "Done." : "It can't do that right now.")
    }
}

struct ToggleMascotIntent: AppIntent {
    static let title: LocalizedStringResource = "Hide or Show the Mascot"

    @Parameter(title: "Show", default: false)
    var visible: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        app?.setVisible(visible)
        return .result()
    }
}

struct MascotShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TalkToMascotIntent(), phrases: ["Talk to \(.applicationName)"],
                    shortTitle: "Talk", systemImageName: "bubble.left")
        AppShortcut(intent: PerformMotionIntent(), phrases: ["Make \(.applicationName) \(\.$motion)"],
                    shortTitle: "Gesture", systemImageName: "figure.wave")
        AppShortcut(intent: ToggleMascotIntent(), phrases: ["Hide \(.applicationName)"],
                    shortTitle: "Hide or Show", systemImageName: "eye.slash")
    }
}
