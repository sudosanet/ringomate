import AppKit
import SwiftUI

struct AboutTab: View {
    @Bindable var navigation: SettingsNavigation
    @State private var showLicense = false
    @State private var showPrivacy = false
    @State private var copied = false

    private static let info = Bundle.main.infoDictionary ?? [:]
    private static let version = info["CFBundleShortVersionString"] as? String ?? "?"
    private static let build = info["CFBundleVersion"] as? String ?? "?"

    private static let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty ? "Apple Silicon" : name
    }()

    private static let macOS: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }()

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            FlipIcon(back: ModelLibrary.current.flatMap(ModelThumbnails.face(for:)))
                .padding(.bottom, 16)
            Text(verbatim: "RingoMate").font(.largeTitle.weight(.semibold))
                .padding(.bottom, 8)
            Button(action: copyVersion) {
                HStack(spacing: 4) {
                    (copied ? Text("Copied", bundle: #bundle) : Text("Version \(Self.version)", bundle: #bundle)).font(.body.weight(.medium))
                    if !copied { Text(verbatim: "(\(Self.build))").font(.body.monospacedDigit()).opacity(0.7) }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
            .buttonStyle(.plain)
            .help(Text("Copy version, macOS, and chip", bundle: #bundle))
            HStack(spacing: 8) {
                Pill(symbol: "apple.logo", text: Self.macOS)
                Pill(symbol: "cpu", text: Self.chip)
            }
            .padding(.top, 10)
            Spacer()
            HStack(spacing: 12) {
                Card(symbol: "checkmark.seal.fill", color: .indigo, title: String(localized: "License", bundle: #bundle), value: "Apache License 2.0") {
                    showLicense = true
                }
                Card(symbol: "heart.text.square.fill", color: .pink, title: String(localized: "Assets and libraries", bundle: #bundle), value: String(localized: "\(ThirdPartyItem.all.count) items", bundle: #bundle)) {
                    navigation.tab = .licenses
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            Button { showPrivacy = true } label: { Text("Privacy Policy", bundle: #bundle) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)
        }
        .padding(.top, 20)
        .sheet(isPresented: $showLicense) { LicenseSheet() }
        .sheet(isPresented: $showPrivacy) { PrivacySheet() }
    }

    private func copyVersion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("RingoMate \(Self.version) (\(Self.build)) / \(Self.macOS) / \(Self.chip)", forType: .string)
        copied = true
        Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
    }
}

/// 表はアプリのアイコン、裏はいまのキャラクター。乗ると少し明るく、押すと裏返る。
private struct FlipIcon: View {
    let back: NSImage?
    @State private var flipped = false
    @State private var angle = 0.0
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let size: CGFloat = 128
    // accessory（LSUIElement）では NSApp.applicationIconImage が汎用アイコンのままになる。
    private static let appIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let image = NSImage(contentsOf: url) { return image }
        return NSApp.applicationIconImage
    }()

    var body: some View {
        ZStack {
            Image(nsImage: Self.appIcon).resizable().scaledToFit()
                .opacity(flipped ? 0 : 1)
            if let back {
                Image(nsImage: back).resizable().scaledToFill()
                    .frame(width: size * 0.82, height: size * 0.82)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(.primary.opacity(0.08)))
                    .opacity(flipped ? 1 : 0)
            }
        }
        .frame(width: size, height: size)
        .brightness(hover ? 0.05 : 0)
        .rotation3DEffect(.degrees(angle), axis: (0, 1, 0), perspective: 0.5)
        .onHover { h in withAnimation(.easeInOut(duration: 0.16)) { hover = h } }
        .onTapGesture { if back != nil { flip() } }
    }

    private func flip() {
        guard !reduceMotion else { return flipped.toggle() }
        withAnimation(.easeIn(duration: 0.12)) { angle = 90 } completion: {
            flipped.toggle()
            angle = -90
            withAnimation(.easeOut(duration: 0.32)) { angle = 0 }
        }
    }
}

private struct Pill: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.05)))
            .foregroundStyle(.secondary)
    }
}

private struct Card: View {
    let symbol: String, color: Color, title: String, value: String
    let tap: () -> Void
    @State private var hover = false

    init(symbol: String, color: Color, title: String, value: String, tap: @escaping () -> Void) {
        (self.symbol, self.color, self.title, self.value, self.tap) = (symbol, color, title, value, tap)
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                SettingsIcon(symbol: symbol, color: color, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption).foregroundStyle(.secondary)
                    Text(value).font(.headline)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeInOut(duration: 0.16)) { hover = h } }
    }
}

private struct PrivacySheet: View {
    @Environment(\.dismiss) private var dismiss
    private let text = Bundle.main.url(forResource: "PRIVACY", withExtension: "md")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text).font(.system(.caption)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button { dismiss() } label: { Text("Close", bundle: #bundle) }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 500)
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let text = Bundle.module.url(forResource: "apache-2.0", withExtension: "txt", subdirectory: "Licenses")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            Divider()
            HStack {
                Spacer()
                Button { dismiss() } label: { Text("Close", bundle: #bundle) }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 500)
    }
}
