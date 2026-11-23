import Foundation
import Observation

extension SettingsKey {
    public static let voiceEnabled = "voiceEnabled"
    public static let voiceChatter = "voiceChatter"
    public static let voiceReply = "voiceReply"
    public static let voiceAgent = "voiceAgent"
    public static let voiceNotification = "voiceNotification"
    /// `VoicePreset` の rawValue（選んでいる声）
    public static let voicePreset = "voicePreset"
    /// `.custom` の言葉
    public static let voiceCaption = "voiceCaption"
    /// `.file` の録音のパス
    public static let voiceReference = "voiceReference"
    public static let voiceVolume = "voiceVolume"
    /// マイクを使っているアプリ（通話など）があるときは声を出さない
    public static let voiceQuietOnMic = "voiceQuietOnMic"
}

/// 声の種類。録音以外は、言葉（キャプション）から 1 度だけ見本の声を作り、それを参照の録音にして声をそろえる。
/// キャプションはモデルへの入力なので日本語のまま。
public enum VoicePreset: String, CaseIterable, Identifiable, Sendable {
    case bright, gentle, calm, energetic, custom, file
    public var id: Self { self }

    public var title: String {
        switch self {
        case .bright: String(localized: "Bright", bundle: #bundle)
        case .gentle: String(localized: "Gentle", bundle: #bundle)
        case .calm: String(localized: "Calm", bundle: #bundle)
        case .energetic: String(localized: "Energetic", bundle: #bundle)
        case .custom: String(localized: "Describe it yourself", bundle: #bundle)
        case .file: String(localized: "From a recording", bundle: #bundle)
        }
    }

    public var symbol: String {
        switch self {
        case .bright: "sun.max"
        case .gentle: "leaf"
        case .calm: "moon"
        case .energetic: "sparkles"
        case .custom: "pencil"
        case .file: "waveform"
        }
    }

    public var caption: String {
        switch self {
        case .bright, .custom: "明るくやさしい、少し高めの若い女性の声。親しみやすく話す。"
        case .gentle: "穏やかでやわらかい、ささやくような若い女性の声。ゆっくり話す。"
        case .calm: "落ち着いた低めの女性の声。はっきりと話す。"
        case .energetic: "元気で弾むような、高めの少女の声。テンポよく話す。"
        case .file: ""
        }
    }

    public static func selected(_ d: UserDefaults = .standard) -> VoicePreset {
        VoicePreset(rawValue: d.string(forKey: SettingsKey.voicePreset) ?? "") ?? .bright
    }

    /// 見本を作るときの言葉。
    public func caption(_ d: UserDefaults = .standard) -> String {
        guard self == .custom else { return caption }
        let custom = (d.string(forKey: SettingsKey.voiceCaption) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? VoicePreset.bright.caption : custom
    }
}

/// 声のモデルと読み込みの様子。アプリ側が書き、設定画面が見る。
@Observable @MainActor
public final class VoiceStatus {
    public enum Model: Equatable, Sendable {
        case missing, downloading(Double), installing, installed, failed(String)
    }

    public var model = Model.missing
    public var loaded = false
    public var failure: String?
    /// 見本の声ができている種類（`VoicePreset` の rawValue）
    public var made: Set<String> = []
    /// 見本を作っている種類
    public var making: String?
    /// 作り直して、まだ決めていない種類
    public var candidate: String?
    /// マイクを使っているアプリの名前
    public var micApps: [String] = []

    public init() {}
}
