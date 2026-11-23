import Foundation
import HookWire

extension SettingsKey {
    public static let lookAtScreen = "lookAtScreen"
    public static let windowTitles = "windowTitles"
    public static let listenMusic = "listenMusic"
    public static let findThings = "findThings"
    public static let avoidBusyScreen = "avoidBusyScreen"
    /// 改行・カンマ区切りのバンドル ID の頭
    public static let neverLookApps = "neverLookApps"

    public static let chatFrequency = "chatFrequency"
    public static let chatWorkResult = "chatWorkResult"
    public static let chatLongWork = "chatLongWork"
    public static let chatWelcomeBack = "chatWelcomeBack"
    public static let chatAppSwitch = "chatAppSwitch"
    public static let chatIdle = "chatIdle"
    public static let chatNotifications = "chatNotifications"
    public static let readNotifications = "readNotifications"
    public static let quietHours = "quietHours"
    public static let quietFrom = "quietFrom"
    public static let quietTo = "quietTo"
    public static let lineLength = "lineLength"
    public static let chatTemperature = "chatTemperature"
    public static let recentCount = "recentCount"
    public static let lookInterval = "lookInterval"

    public static let persona = "persona"
    public static let personaCustom = "personaCustom"
    public static let mascotName = "mascotName"
    public static let ownerCall = "ownerCall"

    public static let conversationMemory = "conversationMemory"
    public static let turnsBeforeSummary = "turnsBeforeSummary"
    public static let replyLength = "replyLength"

    public static let aiTools = "aiTools"
    public static let faceFromReply = "faceFromReply"
    public static let faceStrength = "faceStrength"
    public static let actAfterReply = "actAfterReply"

    public static let permissionChat = "permissionChat"
    /// `PermissionKind` の rawValue をカンマで並べる
    public static let permissionKinds = "permissionKinds"
    public static let boneAssist = "boneAssist"
}

public enum PersonaPreset: String, CaseIterable, Identifiable, Sendable {
    case gentle, cheerful, cool, polite, custom
    public var id: Self { self }
    public static let maxCustomLength = 400

    public var title: String {
        switch self {
        case .gentle: String(localized: "Gentle", bundle: #bundle)
        case .cheerful: String(localized: "Cheerful", bundle: #bundle)
        case .cool: String(localized: "Cool", bundle: #bundle)
        case .polite: String(localized: "Polite", bundle: #bundle)
        case .custom: String(localized: "Custom", bundle: #bundle)
        }
    }

    public var text: String {
        switch self {
        case .gentle, .custom:
            String(localized: "A small character who lives on the computer desktop. Spends its days near its owner and talks in a bright, gentle, casual way.", bundle: #bundle)
        case .cheerful:
            String(localized: "A small character who lives on the computer desktop. Always full of energy and curiosity, and talks in a bouncy, casual way.", bundle: #bundle)
        case .cool:
            String(localized: "A small character who lives on the computer desktop. Calm and quiet. Seems curt but truly cares about its owner, and speaks briefly and flatly.", bundle: #bundle)
        case .polite:
            String(localized: "A small character who lives on the computer desktop. Courteous, speaks in polite language, and quietly looks out for its owner.", bundle: #bundle)
        }
    }

    /// AI に渡す文。プリセットは表示の言語の文（話す言語と同じ。英語の文で渡すと日本語の文法が崩れる）。
    /// カスタムは書いたまま、空ならやさしいに戻す。
    public static func resolved(_ d: UserDefaults = .standard) -> String {
        let preset = PersonaPreset(rawValue: d.string(forKey: SettingsKey.persona) ?? "") ?? .gentle
        guard preset == .custom else { return preset.text }
        let custom = (d.string(forKey: SettingsKey.personaCustom) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? PersonaPreset.gentle.text : String(custom.prefix(maxCustomLength))
    }

    /// かぎかっこで囲んだセリフの例が 2 つ以上ある（例は場面に関係なくそのまま言うので、書き方のヒントを出す）。「〜よ」のような語尾の例は数えない。
    public static func hasQuotedLines(_ text: String) -> Bool {
        text.matches(of: /「[^〜～」][^」]*」|『[^〜～』][^』]*』/).count >= 2
    }
}

/// 吹き出しで答えてよい Claude Code の道具の種類。フックが回すのはこの 3 つだけで、危ないコマンドはいつもターミナルに回る。
public enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case bash, edit, web
    public var id: Self { self }

    public var title: String {
        switch self {
        case .bash: String(localized: "Commands (Bash)", bundle: #bundle)
        case .edit: String(localized: "File edits (Edit, Write)", bundle: #bundle)
        case .web: String(localized: "Web (WebFetch, WebSearch)", bundle: #bundle)
        }
    }

    public init?(tool: String) {
        switch tool {
        case "Bash": self = .bash
        case _ where HookWire.editTools.contains(tool): self = .edit
        case "WebFetch", "WebSearch": self = .web
        default: return nil
        }
    }

    public static func allowed(_ d: UserDefaults = .standard) -> Set<PermissionKind> {
        guard let s = d.string(forKey: SettingsKey.permissionKinds) else { return Set(allCases) }
        return Set(s.split(separator: ",").compactMap { PermissionKind(rawValue: String($0)) })
    }
}

public enum ChatFrequency: String, CaseIterable, Identifiable, Sendable {
    case few, normal, many
    public var id: Self { self }

    public var title: String {
        switch self {
        case .few: String(localized: "Fewer", bundle: #bundle)
        case .normal: String(localized: "Normal", bundle: #bundle)
        case .many: String(localized: "More", bundle: #bundle)
        }
    }

    /// 何もないときに話しかける間隔と、一言どうしの最短の間（秒）
    public var timing: (idle: ClosedRange<Double>, gap: Double) {
        switch self {
        case .few: (300...600, 180)
        case .normal: (120...300, 90)
        case .many: (60...150, 45)
        }
    }
}

/// 時（0〜23）。from > to なら日をまたぐ。
public func isQuietHour(_ hour: Int, from: Int, to: Int) -> Bool {
    from == to ? false : from < to ? (from..<to).contains(hour) : hour >= from || hour < to
}
