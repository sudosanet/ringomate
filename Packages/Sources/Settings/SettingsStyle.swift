import SwiftUI

struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .fill(color.gradient)
            )
    }
}

extension SettingsTab {
    var color: Color {
        switch self {
        case .general: .gray
        case .models: .blue
        case .appearance: .pink
        case .ai: .purple
        case .voice: .red
        case .advanced: .orange
        case .diagnostics: .green
        case .licenses: .teal
        case .about: .indigo
        }
    }

    var subtitle: String {
        switch self {
        case .general: String(localized: "Character size, movement, and how it appears on screen", bundle: #bundle)
        case .models: String(localized: "Choose the character model. See its name, terms, and details", bundle: #bundle)
        case .appearance: String(localized: "Shading, post effects, and physics strength. Rendering updates live", bundle: #bundle)
        case .ai: String(localized: "On-device AI and Claude Code", bundle: #bundle)
        case .voice: String(localized: "Speak the speech bubbles aloud and choose the voice", bundle: #bundle)
        case .advanced: String(localized: "Turn features on or off and fine-tune physics (same as the environment variables)", bundle: #bundle)
        case .diagnostics: String(localized: "Information for troubleshooting", bundle: #bundle)
        case .licenses: String(localized: "Characters, motions, models, and code by other authors included in the app", bundle: #bundle)
        case .about: String(localized: "Version and licenses", bundle: #bundle)
        }
    }
}

struct PageHeader: View {
    let tab: SettingsTab

    var body: some View {
        HStack(spacing: 12) {
            SettingsIcon(symbol: tab.symbol, color: tab.color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.title).font(.title2.weight(.bold))
                Text(tab.subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

struct SettingsPage<Content: View>: View {
    let tab: SettingsTab
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(tab: tab)
            .padding(.horizontal, 20)
            .padding(.top, 38)
            .padding(.bottom, 4)
            content
        }
    }
}

/// `Label("…", systemImage:)` は Bundle.main を引くので、このパッケージの訳を引く版。
func label(_ title: LocalizedStringKey, _ symbol: String) -> Label<Text, Image> {
    Label { Text(title, bundle: #bundle) } icon: { Image(systemName: symbol) }
}

let offLabel = String(localized: "Off", bundle: #bundle)

struct BoolSetting: View {
    @AppStorage private var on: Bool
    let title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey?

    init(key: String, title: LocalizedStringKey, symbol: String, detail: LocalizedStringKey? = nil, initial: Bool) {
        _on = AppStorage(wrappedValue: initial, key)
        (self.title, self.symbol, self.detail) = (title, symbol, detail)
    }

    var body: some View {
        Toggle(isOn: $on) {
            label(title, symbol)
            if let detail { Text(detail, bundle: #bundle) }
        }
    }
}

extension Binding where Value == String {
    /// カンマ区切りの中に `token` があること（`present` が偽ならないこと）を、オン・オフにする。
    /// `order` があればその順に、なければ文字の順に並べ直して書く。
    func member(_ token: String, present: Bool = true, order: [String]? = nil) -> Binding<Bool> {
        Binding<Bool> {
            wrappedValue.split(separator: ",").contains(Substring(token)) == present
        } set: { on in
            var set = Set(wrappedValue.split(separator: ",").map(String.init))
            if on == present { set.insert(token) } else { set.remove(token) }
            wrappedValue = (order.map { $0.filter(set.contains) } ?? set.sorted()).joined(separator: ",")
        }
    }
}
