import SwiftUI
import UniformTypeIdentifiers

struct VoiceTab: View {
    let actions: SettingsActions
    @AppStorage(SettingsKey.voiceEnabled) private var enabled = false
    @AppStorage(SettingsKey.voiceVolume) private var volume = 1.0

    private var status: VoiceStatus { actions.voice }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    label("Speak aloud", "speaker.wave.2.fill")
                    Text("Japanese is spoken with Irodori-TTS on this Mac (Neural Engine). Other languages use the macOS voice.", bundle: #bundle)
                }
                if status.model != .installed { ModelCard(actions: actions) }
            }
            VoiceChoiceSection(actions: actions)
                .disabled(!enabled)
            Section {
                scene(SettingsKey.voiceReply, "Replies in conversation", "bubble.left.and.bubble.right", true)
                scene(SettingsKey.voiceAgent, "Messages from Claude Code", "terminal", true)
                scene(SettingsKey.voiceNotification, "Notifications", "bell", true)
                scene(SettingsKey.voiceChatter, "Talking to itself", "text.bubble", false)
                QuietOnMic(apps: status.micApps)
                HStack {
                    label("Volume", "speaker.wave.1")
                    Slider(value: $volume, in: 0...1)
                    Button { actions.testVoice() } label: { Text("Try", bundle: #bundle) }
                }
            } header: {
                Text("When to speak", bundle: #bundle)
            }
            .disabled(!enabled)
            if status.model == .installed {
                Section {
                    HStack {
                        label("Japanese voice model", "shippingbox")
                        Spacer()
                        Text(status.loaded ? String(localized: "Ready", bundle: #bundle) : String(localized: "Loading…", bundle: #bundle))
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) { actions.deleteVoice() } label: { Text("Delete", bundle: #bundle) }
                    }
                    if let failure = status.failure {
                        Text(failure).font(.callout).foregroundStyle(.red)
                    }
                } header: {
                    Text("Model", bundle: #bundle)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: enabled) { actions.voiceChanged() }
        .onChange(of: volume) { actions.voiceChanged() }
    }

    private func scene(_ key: String, _ title: LocalizedStringKey, _ symbol: String, _ initial: Bool) -> some View {
        BoolSetting(key: key, title: title, symbol: symbol, initial: initial)
    }
}

/// モデルがまだないときの案内とダウンロード。
private struct ModelCard: View {
    let actions: SettingsActions
    private var status: VoiceStatus { actions.voice }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill").font(.largeTitle).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text("Download the Japanese voice (about 1 GB)", bundle: #bundle).font(.headline)
                switch status.model {
                case let .downloading(f):
                    ProgressView(value: f) {
                        Text("Downloading… \(Int(f * 100))%", bundle: #bundle).font(.callout)
                    }
                    Text("It continues in the background, even with this window closed.", bundle: #bundle)
                        .font(.callout).foregroundStyle(.secondary)
                    Button { actions.cancelVoiceDownload() } label: { Text("Pause", bundle: #bundle) }
                case .installing:
                    ProgressView { Text("Installing…", bundle: #bundle).font(.callout) }
                case let .failed(message):
                    Text(message).font(.callout).foregroundStyle(.red)
                    Button { actions.downloadVoice() } label: { Text("Retry", bundle: #bundle) }
                case .missing, .installed:
                    Text("Until then, Japanese is spoken with the macOS voice.", bundle: #bundle)
                        .font(.callout).foregroundStyle(.secondary)
                    Button { actions.downloadVoice() } label: { Text("Download", bundle: #bundle) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// 声の種類。録音以外は 1 度作った見本の声を参照にして、いつも同じ声で喋る。
private struct VoiceChoiceSection: View {
    let actions: SettingsActions
    @AppStorage(SettingsKey.voicePreset) private var selected = VoicePreset.bright
    @AppStorage(SettingsKey.voiceCaption) private var custom = ""
    @AppStorage(SettingsKey.voiceReference) private var reference = ""
    @State private var choosing = false

    private var status: VoiceStatus { actions.voice }

    var body: some View {
        Section {
            ForEach(VoicePreset.allCases) { row($0) }
            if selected == .custom {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(text: $custom, prompt: Text(VoicePreset.bright.caption), axis: .vertical) {
                        Text("Describe the voice", bundle: #bundle)
                    }
                    .lineLimit(2...3)
                    Text("Describe it in Japanese, then press Make to create the voice.", bundle: #bundle)
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
            }
            if let key = status.candidate, let preset = VoicePreset(rawValue: key) {
                CandidateBar(actions: actions, preset: preset)
            }
        } header: {
            Text("Voice", bundle: #bundle)
        } footer: {
            Text("Each voice is made once and then reused, so it sounds the same every time. Press ↻ for a different take; the current voice stays until you choose the new one.", bundle: #bundle)
                .font(.callout).foregroundStyle(.secondary)
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audio]) { result in
            if case let .success(url) = result {
                reference = url.path
                selected = .file
            }
        }
        .onChange(of: selected) { actions.voiceChanged() }
        .onChange(of: reference) { actions.voiceChanged() }
    }

    private func row(_ preset: VoicePreset) -> some View {
        let isSelected = selected == preset
        let made = status.made.contains(preset.rawValue)
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Image(systemName: preset.symbol).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title)
                Text(detail(preset)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if status.making == preset.rawValue {
                ProgressView().controlSize(.small)
                Text("Making…", bundle: #bundle).font(.caption).foregroundStyle(.secondary)
            } else if preset == .file {
                Button { choosing = true } label: { Text("Choose…", bundle: #bundle) }
            } else {
                Button { actions.previewVoice(preset.rawValue) } label: { Image(systemName: "play.fill") }
                    .help(Text("Listen", bundle: #bundle))
                    .disabled(!made)
                Button { actions.remakeVoice(preset.rawValue) } label: {
                    if made { Image(systemName: "arrow.clockwise") } else { Text("Make", bundle: #bundle) }
                }
                .help(Text("Make a new take of this voice", bundle: #bundle))
                .disabled(!status.loaded || status.making != nil)
            }
            if preset == .file, made {
                Button { actions.previewVoice(preset.rawValue) } label: { Image(systemName: "play.fill") }
                    .help(Text("Listen", bundle: #bundle))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if preset == .file, reference.isEmpty { choosing = true } else { selected = preset }
        }
    }

    private func detail(_ preset: VoicePreset) -> String {
        switch preset {
        case .file: reference.isEmpty ? String(localized: "Imitate an audio file of about 10 seconds", bundle: #bundle)
            : URL(filePath: reference).lastPathComponent
        case .custom: custom.isEmpty ? String(localized: "Write your own description", bundle: #bundle) : custom
        default: preset.caption
        }
    }
}

/// 作り直した声を聞き比べて、使うか決める。
private struct CandidateBar: View {
    let actions: SettingsActions
    let preset: VoicePreset

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars").foregroundStyle(.tint)
            Text("New take of “\(preset.title)”", bundle: #bundle)
            Spacer()
            Button { actions.previewCandidate() } label: { Label { Text("Listen", bundle: #bundle) } icon: { Image(systemName: "play.fill") } }
            Button { actions.remakeVoice(preset.rawValue) } label: { Text("Another", bundle: #bundle) }
            Button { actions.discardCandidate() } label: { Text("Keep the old one", bundle: #bundle) }
            Button { actions.acceptCandidate() } label: { Text("Use this", bundle: #bundle) }
                .buttonStyle(.borderedProminent)
        }
        .padding(8)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct QuietOnMic: View {
    @AppStorage(SettingsKey.voiceQuietOnMic) private var on = true
    let apps: [String]

    var body: some View {
        Toggle(isOn: $on) {
            label("Stay quiet while an app uses the microphone", "mic.slash")
            if on, !apps.isEmpty {
                Text("Quiet now: \(apps.joined(separator: ", ")) is using the microphone", bundle: #bundle)
            } else {
                Text("For calls. Some apps keep the microphone open even outside a call.", bundle: #bundle)
            }
        }
    }
}

