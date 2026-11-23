import Agent
import AI
import Foundation
import FoundationModels
import MascotCore
import Settings
import Senses

/// AI まわりの設定。設定が変わるたびに読み直す。
struct AISettings {
    var style = AIStyle()
    var triggers = ChatTriggers.Config()
    var chatter = true
    var permissionChat = true
    var notifications = true
    var readNotifications = false
    var appName = true
    var lookAtScreen = true
    var windowTitles = true
    var listenMusic = true
    var findThings = true
    var avoidBusyScreen = true
    var faceFromReply = true
    var faceStrength: Float = 1
    var boneAssist = true
    /// 秒
    var lookInterval: Double = 30
    var neverLook: [String] = []
    var quiet: (from: Int, to: Int)?

    static func read(_ d: UserDefaults = .standard) -> AISettings {
        let flag = { (key: String) in d.bool(forKey: key) }
        let number = { (key: String) in d.double(forKey: key) }
        var s = AISettings()
        s.style.persona = PersonaPreset.resolved(d)
        s.style.name = String((d.string(forKey: SettingsKey.mascotName) ?? "").prefix(20))
        s.style.ownerCall = String((d.string(forKey: SettingsKey.ownerCall) ?? "").prefix(20))
        s.style.lineLength = Int(number(SettingsKey.lineLength))
        s.style.replyLength = Int(number(SettingsKey.replyLength))
        s.style.temperature = number(SettingsKey.chatTemperature)
        s.style.recentCount = Int(number(SettingsKey.recentCount))
        s.style.useTools = flag(SettingsKey.aiTools)
        s.style.memory = flag(SettingsKey.conversationMemory)
        s.style.turnsBeforeSummary = Int(number(SettingsKey.turnsBeforeSummary))
        s.style.actAfterReply = flag(SettingsKey.actAfterReply)

        let timing = (ChatFrequency(rawValue: d.string(forKey: SettingsKey.chatFrequency) ?? "") ?? .normal).timing
        (s.triggers.idleInterval, s.triggers.minGap) = (timing.idle, timing.gap)
        s.triggers.workResult = flag(SettingsKey.chatWorkResult)
        s.triggers.longWork = flag(SettingsKey.chatLongWork)
        s.triggers.welcomeBack = flag(SettingsKey.chatWelcomeBack)
        s.triggers.appSwitch = flag(SettingsKey.chatAppSwitch)
        s.triggers.idle = flag(SettingsKey.chatIdle)

        s.chatter = flag(SettingsKey.chatter)
        s.permissionChat = flag(SettingsKey.permissionChat)
        s.notifications = flag(SettingsKey.chatNotifications)
        s.readNotifications = flag(SettingsKey.readNotifications)
        s.appName = flag(SettingsKey.frontAppContext)
        s.lookAtScreen = flag(SettingsKey.lookAtScreen)
        s.windowTitles = flag(SettingsKey.windowTitles)
        s.listenMusic = flag(SettingsKey.listenMusic)
        s.findThings = flag(SettingsKey.findThings)
        s.avoidBusyScreen = flag(SettingsKey.avoidBusyScreen)
        s.faceFromReply = flag(SettingsKey.faceFromReply)
        s.faceStrength = Float(number(SettingsKey.faceStrength))
        s.boneAssist = flag(SettingsKey.boneAssist)
        s.lookInterval = number(SettingsKey.lookInterval)
        s.neverLook = (d.string(forKey: SettingsKey.neverLookApps) ?? "")
            .split(whereSeparator: { $0.isNewline || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if d.bool(forKey: SettingsKey.quietHours) {
            s.quiet = (d.integer(forKey: SettingsKey.quietFrom), d.integer(forKey: SettingsKey.quietTo))
        }
        return s
    }

    /// 一言をしゃべってよいか（設定がオンで、黙る時間でない）。
    func maySpeak(now: Date = Date()) -> Bool { chatter && !isQuiet(now: now) }

    func isQuiet(now: Date = Date()) -> Bool {
        guard let q = quiet else { return false }
        return isQuietHour(Calendar.current.component(.hour, from: now), from: q.from, to: q.to)
    }


    var needsScreenCapture: Bool { lookAtScreen || windowTitles || listenMusic || findThings || avoidBusyScreen }

    @MainActor static func status(conversation: Conversation, canSee: Bool, readNotifications: Bool) -> [String] {
        let model = switch SystemLanguageModel.default.availability {
        case .available: String(localized: "Available")
        case let .unavailable(reason): String(localized: "Unavailable (\(String(describing: reason)))")
        }
        var lines = [String(localized: "On-device AI: \(model)"),
                     canSee ? String(localized: "Looking at the screen: Allowed") : String(localized: "Looking at the screen: Not allowed")]
        if readNotifications {
            lines.append(NotificationWatcher.trusted ? String(localized: "Reading notifications: Allowed")
                : String(localized: "Reading notifications: Needs Accessibility permission"))
        }
        if !SpeechLanguage.current.supported { lines.append(String(localized: "The on-device AI doesn't support this language")) }
        if let e = conversation.lastError { lines.append(String(localized: "Last error: \(e)")) }
        return lines
    }
}

extension SettingsActions {
    @MainActor
    func withAI(_ app: AppDelegate) -> SettingsActions {
        var a = self
        a.memorySummary = { [weak app] in app?.conversation.summary ?? "" }
        a.setMemorySummary = { [weak app] in app?.conversation.setSummary($0) }
        a.forgetMemory = { [weak app] in app?.conversation.forget() }
        a.connectClaudeCode = { await ClaudePlugin.connect(marketplace: Bundle.main.bundleURL.appending(path: "Contents/Resources/claude-plugin")) }
        a.aiStatus = { [weak app] in
            guard let app else { return [] }
            return AISettings.status(conversation: app.conversation, canSee: app.chatter.canSee, readNotifications: app.ai.readNotifications)
        }
        return a
    }
}
