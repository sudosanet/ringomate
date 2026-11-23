import Foundation

extension SettingsKey {
    /// 既定値。アプリが起動時に `registerDefaults()` で登録するので、読む側は既定値を書かない（画面の @AppStorage の値より優先される）。
    /// 偽・0・空文字の既定は書かない（登録がなくても同じ）。
    public static let defaults: [String: any Sendable] = [
        // 見た目
        characterHeight: 360.0, restScale: 1.0, maxFrameRate: 120, stillFrameRate: 60, fullScreenMode: "hide", rampMode: "auto",
        selfShadow: true, colorMatch: true, bloomStrength: 0.8, rimStrength: 0.25, outlineScale: 1.0, faceShading: 0.35,
        specularStrength: 1.0, edgeTint: 0.6, antialiasing: 4, groundShadow: 0.35, bustStrength: 1.0, hairSoftness: 1.0,
        danceLipSync: true,
        // AI
        lineLength: 20.0, replyLength: 40.0, chatTemperature: 1.0, recentCount: 12.0, turnsBeforeSummary: 8.0,
        faceStrength: 1.0, lookInterval: 30.0, quietFrom: 23, quietTo: 7,
        aiTools: true, conversationMemory: true, actAfterReply: true, chatter: true, permissionChat: true,
        chatNotifications: true, frontAppContext: true, lookAtScreen: true, windowTitles: true, listenMusic: true,
        findThings: true, avoidBusyScreen: true, faceFromReply: true, boneAssist: true,
        chatWorkResult: true, chatLongWork: true, chatWelcomeBack: true, chatAppSwitch: true, chatIdle: true,
        // 声
        voiceVolume: 1.0, voiceQuietOnMic: true, voiceReply: true, voiceAgent: true, voiceNotification: true,
    ]

    public static func registerDefaults(_ d: UserDefaults = .standard) { d.register(defaults: defaults.mapValues { $0 as Any }) }
}
