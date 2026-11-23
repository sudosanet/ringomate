import Foundation
import Observation

public struct ModelDetails: Sendable {
    public var title: String
    public var titleEn: String
    public var comment: String
    public var format: String
    public var terms: [(name: String, text: String)]
    public var counts: [(label: String, value: Int)]
    public var profile: String
    public var decisions: [(item: String, value: String, source: String, reason: String)]

    public init(title: String, titleEn: String, comment: String, format: String, terms: [(name: String, text: String)],
                counts: [(label: String, value: Int)], profile: String,
                decisions: [(item: String, value: String, source: String, reason: String)] = []) {
        (self.title, self.titleEn, self.comment, self.format) = (title, titleEn, comment, format)
        (self.terms, self.counts, self.profile, self.decisions) = (terms, counts, profile, decisions)
    }
}

/// モデルの読み込みとサムネイル作りの様子。アプリ側が書き、設定画面が見る。
@Observable @MainActor
public final class LoadStatus {
    public var path: String?
    public var fraction: Double = 0
    public var stage = ""
    public var failure: String?
    public var thumbnailsLeft = 0

    public init() {}
}

@MainActor
public struct SettingsActions {
    public var loadModel: (String) -> Void
    public var reload: () -> Void
    public var diagnostics: () -> [String]
    public var details: (String) async -> ModelDetails?
    public var makeThumbnail: (String) -> Void
    public var rules: () -> (rules: [(name: String, kind: String, user: Bool, family: Bool)], errors: [String])
    public var status: LoadStatus
    public var memorySummary: () -> String = { "" }
    public var setMemorySummary: (String) -> Void = { _ in }
    public var forgetMemory: () -> Void = {}
    /// 端末内の AI が使えるか・画像を見られるか・最後の失敗
    public var aiStatus: () -> [String] = { [] }
    public var voice = VoiceStatus()
    public var downloadVoice: () -> Void = {}
    public var cancelVoiceDownload: () -> Void = {}
    public var deleteVoice: () -> Void = {}
    /// 声の設定が変わった（オンオフ・声の指定・音量）
    public var voiceChanged: () -> Void = {}
    public var testVoice: () -> Void = {}
    /// 見本の声を鳴らす（`VoicePreset` の rawValue）
    public var previewVoice: (String) -> Void = { _ in }
    /// 新しい見本を作って鳴らす。決めるまで今の声はそのまま
    public var remakeVoice: (String) -> Void = { _ in }
    public var previewCandidate: () -> Void = {}
    public var acceptCandidate: () -> Void = {}
    public var discardCandidate: () -> Void = {}
    /// アプリに入れたプラグインを Claude Code に入れる。失敗したときはその理由
    public var connectClaudeCode: () async -> String? = { nil }

    public init(loadModel: @escaping (String) -> Void, reload: @escaping () -> Void,
                diagnostics: @escaping () -> [String], details: @escaping (String) async -> ModelDetails?,
                makeThumbnail: @escaping (String) -> Void,
                rules: @escaping () -> (rules: [(name: String, kind: String, user: Bool, family: Bool)], errors: [String]) = { ([], []) },
                status: LoadStatus = LoadStatus()) {
        self.loadModel = loadModel
        self.reload = reload
        self.diagnostics = diagnostics
        self.details = details
        self.makeThumbnail = makeThumbnail
        self.rules = rules
        self.status = status
    }
}
