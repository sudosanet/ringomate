import SwiftUI

struct GeneralTab: View {
    @AppStorage(SettingsKey.characterHeight) private var height: Double = 360
    @AppStorage(SettingsKey.restScale) private var restScale: Double = 1
    @AppStorage(SettingsKey.fullScreenMode) private var fullScreenMode = "hide"
    @AppStorage(SettingsKey.allowCapture) private var allowCapture = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Slider(value: $height, in: 160...720, step: 20)
                        Text(verbatim: "\(Int(height)) pt").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                } label: {
                    label("Size", "arrow.up.and.down.square")
                }
                Picker(selection: $restScale) {
                    Text("Lively", bundle: #bundle).tag(0.5)
                    Text("Normal", bundle: #bundle).tag(1.0)
                    Text("Relaxed", bundle: #bundle).tag(2.0)
                } label: {
                    label("Activity", "figure.walk.motion")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Character", bundle: #bundle)
            }
            Section {
                Picker(selection: $fullScreenMode) {
                    Text("Hide", bundle: #bundle).tag("hide")
                    Text("Move to corner", bundle: #bundle).tag("corner")
                    Text("Stay", bundle: #bundle).tag("stay")
                } label: {
                    label("When a full-screen app is in front", "arrow.up.left.and.arrow.down.right")
                }
                .pickerStyle(.segmented)
                Toggle(isOn: $allowCapture) {
                    label("Show in screen recordings and sharing", "record.circle")
                    Text("When off, it won't appear in meeting screen shares. Turn on only when recording a demo", bundle: #bundle)
                }
            } header: {
                Text("Display", bundle: #bundle)
            }
            LanguageSection()
        }
        .formStyle(.grouped)
    }
}

struct AppearanceTab: View {
    let actions: SettingsActions
    private var families: [String] { actions.rules().rules.filter(\.family).map(\.name) }
    /// 診断の `profile:` の行から。
    private var current: String? {
        actions.diagnostics().first { $0.hasPrefix("profile: ") }.flatMap { $0.dropFirst(9).split(separator: " ").first.map(String.init) }
    }
    @AppStorage(SettingsKey.profile) private var profile = ""
    @AppStorage(SettingsKey.bustStrength) private var bustStrength = 1.0
    @AppStorage(SettingsKey.hairSoftness) private var hairSoftness = 1.0
    @AppStorage(SettingsKey.selfShadow) private var selfShadow = true
    @AppStorage(SettingsKey.bloomStrength) private var bloom = 0.8
    @AppStorage(SettingsKey.rimStrength) private var rim = 0.25
    @AppStorage(SettingsKey.rampMode) private var rampMode = "auto"
    @AppStorage(SettingsKey.outlineScale) private var outline = 1.0
    @AppStorage(SettingsKey.faceShading) private var faceShading = 0.35
    @AppStorage(SettingsKey.specularStrength) private var specular = 1.0
    @AppStorage(SettingsKey.edgeTint) private var edgeTint = 0.6
    @AppStorage(SettingsKey.groundShadow) private var groundShadow = 0.35
    @AppStorage(SettingsKey.antialiasing) private var antialiasing = 4
    @AppStorage(SettingsKey.colorMatch) private var colorMatch = true
    @AppStorage(SettingsKey.wallpaperTint) private var wallpaperTint = 0.0
    @AppStorage(SettingsKey.textureQuality) private var textureQuality = 0
    @AppStorage(SettingsKey.maxFrameRate) private var maxFrameRate = 120
    @AppStorage(SettingsKey.stillFrameRate) private var stillFrameRate = 60
    @AppStorage(SettingsKey.danceLipSync) private var danceLipSync = true

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $selfShadow) { label("Self shadow", "square.2.layers.3d.bottom.filled") }
                segmented("Bloom", "sun.max", $bloom, [(offLabel, 0.0), ("0.4", 0.4), ("0.8", 0.8), ("1.4", 1.4)])
                segmented("Rim light", "circle.lefthalf.filled", $rim, [(offLabel, 0.0), ("0.12", 0.12), ("0.25", 0.25), ("0.45", 0.45)])
                segmented("Outline width", "pencil.tip", $outline, [(offLabel, 0.0), ("×0.6", 0.6), ("×1", 1.0), ("×1.6", 1.6)])
                segmented("Lambert ratio on face", "face.smiling", $faceShading, [("0.15", 0.15), ("0.35", 0.35), ("0.6", 0.6)])
                segmented("Toon ramp", "thermometer.medium", $rampMode, [(String(localized: "Auto", bundle: #bundle), "auto"), (String(localized: "Day (warm)", bundle: #bundle), "day"), (String(localized: "Night (cool)", bundle: #bundle), "night")])
                segmented("Specular", "sparkle", $specular, [(offLabel, 0.0), ("×0.5", 0.5), (String(localized: "×1 (MMD)", bundle: #bundle), 1.0)])
                segmented("Outline color", "paintpalette", $edgeTint, [(String(localized: "PMX edge color", bundle: #bundle), 0.0), (String(localized: "Mix in 60% material color", bundle: #bundle), 0.6)])
                segmented("Ground shadow opacity", "figure.stand", $groundShadow, [(offLabel, 0.0), ("0.2", 0.2), ("0.35", 0.35)])
                segmented("MSAA", "scribble.variable", $antialiasing, [(offLabel, 1), ("4x", 4)])
                segmented("Tint shadow and rim from wallpaper", "photo", $wallpaperTint, [(offLabel, 0.0), ("0.15", 0.15), ("0.3", 0.3)])
                Toggle(isOn: $colorMatch) {
                    label("sRGB color management", "eyedropper")
                    Text("Sets the CAMetalLayer color space to sRGB. When off, colors go to P3 displays unconverted", bundle: #bundle)
                }
            } header: {
                Text("Rendering", bundle: #bundle)
            } footer: {
                Text("Changes apply immediately. Auto ramp switches to night from 8 PM to 6 AM and in Dark Mode. Wallpaper adjustment needs screen recording permission", bundle: #bundle).foregroundStyle(.secondary)
            }
            Section {
                segmented("Frame rate limit", "gauge.with.dots.needle.67percent", $maxFrameRate, [("30", 30), ("60", 60), ("120", 120)])
                segmented("Frame rate while standing still", "figure.stand", $stillFrameRate, [("30", 30), ("60", 60)])
                Toggle(isOn: $danceLipSync) {
                    label("Lip sync while dancing", "mouth")
                    Text("Listens only to the app playing the song. Nothing leaves your Mac", bundle: #bundle)
                }
            } header: {
                Text("Frame rate and lip sync", bundle: #bundle)
            } footer: {
                Text("120 fps only while moving; idle is capped at 60", bundle: #bundle).foregroundStyle(.secondary)
            }
            Section {
                Picker(selection: $profile) {
                    Group { if let current { Text("Auto (now: \(current))", bundle: #bundle) } else { Text("Auto", bundle: #bundle) } }.tag("")
                    ForEach(families, id: \.self) { ($0 == "default" ? Text("Standard (no family)", bundle: #bundle) : Text(verbatim: $0)).tag($0) }
                } label: {
                    label("Family", "person.text.rectangle")
                    Text("Rules used where analysis can't decide. Model-specific rules and analysis take priority", bundle: #bundle)
                }
                segmented("Bust physics strength", "waveform.path", $bustStrength, [(offLabel, 0.0), ("×0.5", 0.5), ("×1", 1.0), ("×1.6", 1.6)])
                segmented("Hair chain softness", "wind", $hairSoftness, [("×0.6", 0.6), ("×1", 1.0), ("×2", 2.0)])
                segmented("Texture", "photo.badge.checkmark", $textureQuality, [("ASTC 4x4", 0), (String(localized: "RGBA8 for face and eyes", bundle: #bundle), 1), (String(localized: "RGBA8 for all", bundle: #bundle), 2)])
            } header: {
                Text("Model", bundle: #bundle)
            } footer: {
                HStack {
                    Text("Applies when the model is reloaded", bundle: #bundle).foregroundStyle(.secondary)
                    Spacer()
                    Button { actions.reload() } label: { Text("Reload and apply", bundle: #bundle) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func segmented<V: Hashable>(_ title: LocalizedStringKey, _ symbol: String, _ value: Binding<V>, _ options: [(String, V)]) -> some View {
        Picker(selection: value) {
            ForEach(options, id: \.1) { Text(verbatim: $0.0).tag($0.1) }
        } label: {
            label(title, symbol)
        }
        .pickerStyle(.segmented)
    }
}
