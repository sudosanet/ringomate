import AppKit
import SwiftUI

struct AITab: View {
    let actions: SettingsActions
    @State private var summary = ""

    var body: some View {
        Form {
            PersonaSection()
            ChatSection()
            SensesSection()
            Section {
                toggle(SettingsKey.conversationMemory, "Remember conversations", "brain", "Saves a summary on this Mac and uses it for later replies")
                segmented(SettingsKey.replyLength, "Reply length", "text.alignleft", 40, [(String(localized: "Short", bundle: #bundle), 25), (String(localized: "Normal", bundle: #bundle), 40), (String(localized: "Long", bundle: #bundle), 50)])
                segmented(SettingsKey.turnsBeforeSummary, "Turns before summarizing", "list.bullet.rectangle", 8,
                          [4, 8, 16].map { (String(localized: "\($0) turns", bundle: #bundle), $0) })
                VStack(alignment: .leading) {
                    label("Conversation summary so far", "note.text")
                    TextEditor(text: $summary).font(.callout).frame(height: 70)
                    HStack {
                        Spacer()
                        Button(role: .destructive) {
                            actions.forgetMemory()
                            summary = ""
                        } label: { Text("Delete", bundle: #bundle) }
                        Button { actions.setMemorySummary(summary) } label: { Text("Save", bundle: #bundle) }
                    }
                }
            } header: {
                Text("Conversation", bundle: #bundle)
            }
            Section {
                toggle(SettingsKey.aiTools, "Let the AI move the body", "figure.wave", "Calls gesture, prop, and expression tools while talking")
                toggle(SettingsKey.actAfterReply, "Add a motion after replying", "arrow.turn.down.right", "Replies come a little faster when off")
                toggle(SettingsKey.faceFromReply, "Match the expression to the reply", "face.smiling", nil)
                segmented(SettingsKey.faceStrength, "Expression strength", "dial.medium", 1.0, [(String(localized: "Subtle", bundle: #bundle), 0.5), (String(localized: "Normal", bundle: #bundle), 1.0), (String(localized: "Strong", bundle: #bundle), 1.5)])
            } header: {
                Text("Motion and expressions", bundle: #bundle)
            }
            ClaudeCodeSection()
        }
        .formStyle(.grouped)
        .onAppear {
            summary = actions.memorySummary()
        }
    }
}

private struct PersonaSection: View {
    @AppStorage(SettingsKey.persona) private var preset = PersonaPreset.gentle
    @AppStorage(SettingsKey.personaCustom) private var custom = ""
    @AppStorage(SettingsKey.mascotName) private var name = ""
    @AppStorage(SettingsKey.ownerCall) private var ownerCall = ""

    var body: some View {
        Section {
            Picker(selection: Binding(get: { preset }, set: { new in
                if new == .custom, custom.isEmpty { custom = preset.text }
                preset = new
            })) {
                ForEach(PersonaPreset.allCases) { Text($0.title).tag($0) }
            } label: {
                label("Personality and tone", "person.text.rectangle")
            }
            .pickerStyle(.segmented)
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: preset == .custom ? $custom : .constant(preset.text))
                    .font(.callout)
                    .frame(height: 64)
                    .disabled(preset != .custom)
                    .onChange(of: custom) { if custom.count > PersonaPreset.maxCustomLength { custom = String(custom.prefix(PersonaPreset.maxCustomLength)) } }
                (preset == .custom ? Text("\(custom.count) / \(PersonaPreset.maxCustomLength) characters. Rules against reading out personal info and length limits are added separately", bundle: #bundle)
                                       : Text("Choose Custom to edit starting from this text", bundle: #bundle))
                    .font(.caption).foregroundStyle(.secondary)
                if preset == .custom, PersonaPreset.hasQuotedLines(custom) {
                    Label {
                        Text("Example lines are copied as they are, even where they don't fit. Use only short lines that work in any situation, and don't write words you don't want said", bundle: #bundle)
                    } icon: {
                        Image(systemName: "lightbulb")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField(text: $name, prompt: Text("None", bundle: #bundle)) { label("Name", "tag") }
            TextField(text: $ownerCall, prompt: Text("Not set", bundle: #bundle)) { label("What to call you", "person") }
        } header: {
            Text("Character", bundle: #bundle)
        }
    }
}

private struct ChatSection: View {
    @AppStorage(SettingsKey.chatter) private var chatter = true
    @AppStorage(SettingsKey.quietHours) private var quiet = false
    @AppStorage(SettingsKey.quietFrom) private var from = 23
    @AppStorage(SettingsKey.quietTo) private var to = 7

    var body: some View {
        Section {
            Toggle(isOn: $chatter) {
                label("Say a line now and then", "text.bubble")
                Text("Uses only on-device Apple Foundation Models", bundle: #bundle)
            }
            Group {
                segmented(SettingsKey.chatFrequency, "Frequency", "metronome", ChatFrequency.normal,
                          ChatFrequency.allCases.map { ($0.title, $0) })
                toggle(SettingsKey.chatWorkResult, "Claude Code finished or failed a task", "checkmark.circle", nil)
                toggle(SettingsKey.chatLongWork, "A Claude Code task ran over 5 minutes", "hourglass", nil)
                toggle(SettingsKey.chatWelcomeBack, "You came back to your desk", "figure.walk.arrival", nil)
                toggle(SettingsKey.chatAppSwitch, "You switched apps", "macwindow.on.rectangle", nil)
                toggle(SettingsKey.chatIdle, "Small talk when nothing is happening", "ellipsis.bubble", nil)
                Toggle(isOn: $quiet) { label("Stay quiet during set hours", "moon.zzz") }
                if quiet {
                    HStack {
                        Picker(selection: $from) { ForEach(0..<24) { Text(hour($0)).tag($0) } } label: { Text("From", bundle: #bundle) }
                        Picker(selection: $to) { ForEach(0..<24) { Text(hour($0)).tag($0) } } label: { Text("To", bundle: #bundle) }
                    }
                }
                segmented(SettingsKey.lineLength, "Line length", "textformat.size", 20, [(String(localized: "Short", bundle: #bundle), 12), (String(localized: "Normal", bundle: #bundle), 20), (String(localized: "Long", bundle: #bundle), 28)])
                segmented(SettingsKey.chatTemperature, "Word variety", "dice", 1.0, [(String(localized: "Calm", bundle: #bundle), 0.6), (String(localized: "Normal", bundle: #bundle), 1.0), (String(localized: "Whimsical", bundle: #bundle), 1.4)])
                segmented(SettingsKey.recentCount, "Recent lines remembered to avoid repeats", "repeat", 12, [("6", 6), ("12", 12), ("24", 24)])
            }
            .disabled(!chatter)
            toggle(SettingsKey.chatNotifications, "Announce app notifications", "bell.badge", "Announces even when lines are off, but not during quiet hours")
        } header: {
            Text("Lines", bundle: #bundle)
        }
    }
}

private struct SensesSection: View {
    @AppStorage(SettingsKey.neverLookApps) private var neverLook = ""
    @AppStorage(SettingsKey.lookAtScreen) private var lookAtScreen = true
    @AppStorage(SettingsKey.windowTitles) private var windowTitles = true
    @AppStorage(SettingsKey.listenMusic) private var listenMusic = true
    @AppStorage(SettingsKey.findThings) private var findThings = true
    @AppStorage(SettingsKey.avoidBusyScreen) private var avoidBusyScreen = true
    @AppStorage(SettingsKey.readNotifications) private var readNotifications = false
    @State private var screenAllowed = true
    @State private var accessibilityAllowed = true

    var body: some View {
        Section {
            if (lookAtScreen || windowTitles || listenMusic || findThings || avoidBusyScreen) && !screenAllowed {
                PermissionWarning(text: "Screen recording isn't allowed, so the settings that need it don't work", pane: "Privacy_ScreenCapture")
            }
            if readNotifications && !accessibilityAllowed {
                PermissionWarning(text: "Accessibility isn't allowed, so notification banners can't be read", pane: "Privacy_Accessibility")
            }
            toggle(SettingsKey.frontAppContext, "Use the front app's name", "macwindow", "Adds it to the scene for lines")
            toggle(SettingsKey.lookAtScreen, "Look at the front window", "eye", "Takes one capture and shows it to the AI without saving it. Needs screen recording permission")
            segmented(SettingsKey.lookInterval, "Look interval", "timer", 30, [30, 120, 300].map { (Duration.seconds($0).formatted(.units(width: .abbreviated)), $0) })
            toggle(SettingsKey.windowTitles, "Use window titles and the playing song", "text.below.photo", "Titles need screen recording permission")
            toggle(SettingsKey.listenMusic, "Listen to your Mac's audio and groove to music", "music.note", "Needs screen recording permission")
            toggle(SettingsKey.findThings, "Find things in the wallpaper", "photo.on.rectangle", "Sits on or talks about the things it finds")
            toggle(SettingsKey.avoidBusyScreen, "Walk where the screen is empty", "rectangle.dashed",
                   "Takes a small capture of the strip by its feet when picking where to go, without saving it. Needs screen recording permission")
            toggle(SettingsKey.readNotifications, "Read notification banners", "bell.and.waves.left.and.right",
                   "Tells you the gist of new banners in a line. Needs Accessibility permission. Banners don't appear during Focus or screen mirroring",
                   default: false)
            VStack(alignment: .leading, spacing: 4) {
                label("Apps to never look at", "eye.slash")
                TextEditor(text: $neverLook).font(.system(.callout, design: .monospaced)).frame(height: 50)
                Text("One bundle ID prefix per line (e.g. com.tinyspeck.slackmacgap). Password managers, System Settings, and similar apps are never looked at", bundle: #bundle)
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Seeing and hearing", bundle: #bundle)
        } footer: {
            Text("Nothing leaves your Mac", bundle: #bundle).foregroundStyle(.secondary)
        }
        .onAppear(perform: check)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in check() }
    }

    private func check() {
        screenAllowed = CGPreflightScreenCaptureAccess()
        accessibilityAllowed = AXIsProcessTrusted()
    }
}

private struct PermissionWarning: View {
    let text: LocalizedStringKey
    /// システム設定の「プライバシーとセキュリティ」の中の場所
    let pane: String

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text, bundle: #bundle).font(.callout)
            Spacer()
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
            } label: { Text("Open System Settings", bundle: #bundle) }
        }
    }
}

private struct ClaudeCodeSection: View {
    @AppStorage(SettingsKey.answerPermissions) private var answer = false
    @AppStorage(SettingsKey.permissionKinds) private var kinds = PermissionKind.allCases.map(\.rawValue).joined(separator: ",")

    var body: some View {
        Section {
            toggle(SettingsKey.permissionChat, "Announce pending approvals", "exclamationmark.bubble", nil)
            Toggle(isOn: $answer) {
                label("Answer approvals in the speech bubble", "checkmark.bubble")
                Text("Deletes, pushes, sudo, and similar commands are always confirmed in the terminal", bundle: #bundle)
            }
            ForEach(PermissionKind.allCases) { k in
                Toggle(isOn: $kinds.member(k.rawValue, order: PermissionKind.allCases.map(\.rawValue))) { Text(k.title) }
                .padding(.leading, 28)
                .disabled(!answer)
            }
        } header: {
            Text(verbatim: "Claude Code")
        }
    }
}

/// 「時」だけを、今の言語の書き方で。
private func hour(_ h: Int) -> String {
    Calendar.current.date(from: DateComponents(hour: h)).map { $0.formatted(.dateTime.hour()) } ?? "\(h)"
}

@MainActor private func toggle(_ key: String, _ title: LocalizedStringKey, _ symbol: String, _ detail: LocalizedStringKey?,
                               default value: Bool = true) -> some View {
    BoolSetting(key: key, title: title, symbol: symbol, detail: detail, initial: value)
}


@MainActor private func segmented<V: Hashable & Sendable>(_ key: String, _ title: LocalizedStringKey, _ symbol: String, _ initial: V,
                                    _ options: [(String, V)]) -> some View {
    SegmentedSetting(key: key, initial: initial, title: title, symbol: symbol, options: options)
}

private struct SegmentedSetting<V: Hashable & Sendable>: View {
    let key: String, title: LocalizedStringKey, symbol: String, options: [(String, V)]
    @State private var current: V

    init(key: String, initial: V, title: LocalizedStringKey, symbol: String, options: [(String, V)]) {
        (self.key, self.title, self.symbol, self.options) = (key, title, symbol, options)
        _current = State(initialValue: Self.read(key) ?? initial)
    }

    var body: some View {
        Picker(selection: Binding(get: { current }, set: { current = $0; Self.write(key, $0) })) {
            ForEach(options, id: \.1) { Text(verbatim: $0.0).tag($0.1) }
        } label: {
            label(title, symbol)
        }
        .pickerStyle(.segmented)
    }

    private static func read(_ key: String) -> V? {
        let raw = UserDefaults.standard.object(forKey: key)
        if V.self == ChatFrequency.self { return (raw as? String).flatMap(ChatFrequency.init(rawValue:)) as? V }
        return raw as? V
    }

    private static func write(_ key: String, _ value: V) {
        UserDefaults.standard.set((value as? ChatFrequency)?.rawValue ?? value, forKey: key)
    }
}
