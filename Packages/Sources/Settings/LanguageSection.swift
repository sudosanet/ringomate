import AppKit
import SwiftUI

/// アプリの言語。システム設定のアプリごとの言語と同じ `AppleLanguages` をアプリのドメインに書く（反映は再起動後）。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ja
    var id: Self { self }

    static var stored: AppLanguage {
        let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
        return (domain?["AppleLanguages"] as? [String])?.first.flatMap { AppLanguage(rawValue: String($0.prefix(2))) } ?? .system
    }

    func store() {
        if self == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }
}

struct LanguageSection: View {
    @State private var choice = AppLanguage.stored
    private let launched = AppLanguage.stored

    var body: some View {
        Section {
            Picker(selection: $choice) {
                Text("Follow System", bundle: #bundle).tag(AppLanguage.system)
                Text(verbatim: "English").tag(AppLanguage.en)
                Text(verbatim: "日本語").tag(AppLanguage.ja)
            } label: {
                label("Language", "globe")
            }
            .onChange(of: choice) { choice.store() }
        } header: {
            Text("Language", bundle: #bundle)
        } footer: {
            HStack {
                Text("Applies after restarting RingoMate. The character speaks in this language too", bundle: #bundle).foregroundStyle(.secondary)
                Spacer()
                if choice != launched { Button { Self.relaunch() } label: { Text("Restart Now", bundle: #bundle) } }
            }
        }
    }

    private static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
