import AppKit
import SwiftUI

public enum SettingsKey {
    public static let characterHeight = "characterHeight"
    public static let restScale = "restScale"
    public static let fullScreenMode = "fullScreenMode"
    public static let allowCapture = "allowCapture"
    public static let bustStrength = "bustStrength"
    public static let hairSoftness = "hairSoftness"
    public static let profile = "profile"
    public static let chatter = "chatter"
    public static let answerPermissions = "answerPermissions"
    /// 一言の場面に前面のアプリの名前を入れる（端末の外へは出さない）。
    public static let frontAppContext = "frontAppContext"
    public static let selfShadow = "selfShadow"
    public static let bloomStrength = "bloomStrength"
    public static let rimStrength = "rimStrength"
    public static let rampMode = "rampMode"
    public static let outlineScale = "outlineScale"
    public static let faceShading = "faceShading"
    public static let specularStrength = "specularStrength"
    public static let edgeTint = "edgeTint"
    public static let groundShadow = "groundShadow"
    public static let antialiasing = "antialiasing"
    public static let colorMatch = "colorMatch"
    public static let wallpaperTint = "wallpaperTint"
    public static let textureQuality = "textureQuality"
    public static let maxFrameRate = "maxFrameRate"
    public static let stillFrameRate = "stillFrameRate"
    public static let danceLipSync = "danceLipSync"

    public static let disabledFeatures = "disabledFeatures"
    public static let physicsHz = "physicsHz"
    public static let bustFrequency = "bustFrequency"
    public static let bustDamping = "bustDamping"
    public static let bustGravity = "bustGravity"
    public static let bustLimit = "bustLimit"
    public static let profileDir = "profileDir"
    public static let analyzeKnobs = "analyzeKnobs"
    public static let diagnostics = "diagnostics"
    public static let lastModelPath = "lastModelPath"
    public static let recentModels = "recentModels"
}

public enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general, models, appearance, ai, voice, advanced, diagnostics, licenses, about
    public var id: Self { self }

    var title: String {
        switch self {
        case .general: String(localized: "General", bundle: #bundle)
        case .models: String(localized: "Models", bundle: #bundle)
        case .appearance: String(localized: "Appearance", bundle: #bundle)
        case .ai: "AI"
        case .voice: String(localized: "Voice", bundle: #bundle)
        case .advanced: String(localized: "Advanced", bundle: #bundle)
        case .diagnostics: String(localized: "Diagnostics", bundle: #bundle)
        case .licenses: String(localized: "Licenses", bundle: #bundle)
        case .about: String(localized: "About", bundle: #bundle)
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .models: "person.crop.square.fill"
        case .appearance: "paintpalette.fill"
        case .ai: "sparkles"
        case .voice: "speaker.wave.2.fill"
        case .advanced: "slider.horizontal.3"
        case .diagnostics: "stethoscope"
        case .licenses: "doc.text.fill"
        case .about: "info.circle.fill"
        }
    }
}

@Observable @MainActor
final class SettingsNavigation {
    var tab = SettingsTab.general
}

struct SettingsView: View {
    static let size = NSSize(width: 900, height: 640)
    let actions: SettingsActions
    @Bindable var navigation: SettingsNavigation
    let store: ModelListStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            Group {
                if navigation.tab == .about {
                    AboutTab(navigation: navigation)
                } else {
                    SettingsPage(tab: navigation.tab) { page(navigation.tab) }
                }
            }
            .id(navigation.tab)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "RingoMate").font(.headline).padding(.horizontal, 10).padding(.bottom, 8)
            ForEach(SettingsTab.allCases) { t in
                Button { navigation.tab = t } label: {
                    HStack(spacing: 9) {
                        SettingsIcon(symbol: t.symbol, color: t.color)
                        Text(t.title).font(.callout.weight(navigation.tab == t ? .semibold : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .foregroundStyle(navigation.tab == t ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(navigation.tab == t ? Color.accentColor : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 44)
        .frame(width: 200)
        .background(Color.primary.opacity(0.035))
    }

    @ViewBuilder private func page(_ t: SettingsTab) -> some View {
        switch t {
        case .general: GeneralTab()
        case .models: ModelsTab(actions: actions, store: store)
        case .appearance: AppearanceTab(actions: actions)
        case .ai: AITab(actions: actions)
        case .voice: VoiceTab(actions: actions)
        case .advanced: AdvancedTab(actions: actions)
        case .diagnostics: DiagnosticsTab(actions: actions)
        case .licenses: LicensesTab()
        case .about: AboutTab(navigation: navigation)
        }
    }
}

@MainActor
public final class SettingsWindow {
    private var window: NSWindow?
    private let actions: SettingsActions
    private let navigation = SettingsNavigation()
    private var store: ModelListStore?

    public init(actions: SettingsActions) {
        self.actions = actions
    }

    public func show(_ tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        if window == nil {
            let store = ModelListStore(actions: actions)
            self.store = store
            let w = NSWindow(contentViewController: NSHostingController(
                rootView: SettingsView(actions: actions, navigation: navigation, store: store)))
            w.title = String(localized: "RingoMate Settings", bundle: #bundle)
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setContentSize(SettingsView.size)
            window = w
        }
        guard let window else { return }
        placeOnScreen(window)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func placeOnScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        if window.isVisible, NSScreen.screens.contains(where: { $0.visibleFrame.contains(window.frame) }) { return }
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: max(visible.minY, visible.midY - size.height / 2)))
    }
}
