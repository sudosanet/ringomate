import AppKit
import SwiftUI

struct Feature: Identifiable {
    let id: String
    let title: String
    let detail: String
    let onLoad: Bool
    /// 既定でオフ（`+名前` で持つ）
    var optIn = false

    static let all: [Feature] = [
        Feature(id: "face_normals", title: String(localized: "Edit face normals", bundle: #bundle), detail: String(localized: "Gives face shadows an anime look", bundle: #bundle), onLoad: true),
        Feature(id: "smooth_normals", title: String(localized: "Smooth normals for outlines", bundle: #bundle), detail: String(localized: "Keeps outlines from breaking at corners", bundle: #bundle), onLoad: true),
        Feature(id: "seam_normals", title: String(localized: "Average normals at seams", bundle: #bundle), detail: String(localized: "Removes shadow lines at part seams", bundle: #bundle), onLoad: true),
        Feature(id: "rigidify", title: String(localized: "Attach fixed swaying parts to bones", bundle: #bundle), detail: String(localized: "Takes chains that never move (like wings) out of physics", bundle: #bundle), onLoad: true),
        Feature(id: "physics_fix", title: String(localized: "Physics fixes", bundle: #bundle), detail: String(localized: "Fixes broken joints, initial overlaps, and fixed skirts", bundle: #bundle), onLoad: true),
        Feature(id: "bust", title: String(localized: "Bust physics", bundle: #bundle), detail: String(localized: "When off, keeps the author's rigid bodies for the chest", bundle: #bundle), onLoad: true),
        Feature(id: "hair_chains", title: String(localized: "Turn hair into supple chains", bundle: #bundle), detail: String(localized: "When off, keeps the author's rigid body chains", bundle: #bundle), onLoad: true),
        Feature(id: "vertex_cache", title: String(localized: "Reorder triangles", bundle: #bundle), detail: String(localized: "Matches the GPU vertex cache", bundle: #bundle), onLoad: true),
        Feature(id: "hidden_removal", title: String(localized: "Remove hidden body parts", bundle: #bundle), detail: String(localized: "Keeps skin under clothes from showing through", bundle: #bundle), onLoad: true),
        Feature(id: "analyzer", title: String(localized: "Detect from shape", bundle: #bundle), detail: String(localized: "Finds the face, eyes, bangs, and chest from shape when names don't match (the 5 below together)", bundle: #bundle), onLoad: true),
        Feature(id: "analyze_face", title: String(localized: "Find face materials from shape", bundle: #bundle), detail: String(localized: "Finds the face from forward-facing materials on the head when names don't match", bundle: #bundle), onLoad: true),
        Feature(id: "face_features", title: String(localized: "Stable shading for eyes and brows", bundle: #bundle), detail: String(localized: "Keeps the whites of the eyes from darkening when turned sideways", bundle: #bundle), onLoad: true),
        Feature(id: "see_through", title: String(localized: "Eyes and brows through bangs", bundle: #bundle), detail: String(localized: "Overlays the eyes and brows faintly on top of the bangs", bundle: #bundle), onLoad: true),
        Feature(id: "skin_detect", title: String(localized: "Find skin under clothes", bundle: #bundle), detail: String(localized: "For models with unclear names, skips hidden materials close to the face color (experimental)", bundle: #bundle), onLoad: true, optIn: true),
        Feature(id: "bust_detect", title: String(localized: "Find chest bones from shape", bundle: #bundle), detail: String(localized: "Sways chest bones that can't be found by name", bundle: #bundle), onLoad: true),
        Feature(id: "class_rim", title: String(localized: "Remove rim light on face and eyes", bundle: #bundle), detail: String(localized: "No edge light inside the face or on the eyes (experimental)", bundle: #bundle), onLoad: true, optIn: true),
        Feature(id: "class_ramp", title: String(localized: "Warm skin shadows", bundle: #bundle), detail: String(localized: "Shifts shadows on skin and face without an author toon slightly toward red (experimental)", bundle: #bundle), onLoad: true, optIn: true),
        Feature(id: "mtoon_fix", title: String(localized: "Lift overly dark VRM shadows", bundle: #bundle), detail: String(localized: "Lifts MToon shade colors darker than 55% of the base color (experimental)", bundle: #bundle), onLoad: true, optIn: true),
        Feature(id: "hair_time_fix", title: String(localized: "Keep hair steady when frame timing varies", bundle: #bundle), detail: String(localized: "Keeps hair speed constant when frame intervals change", bundle: #bundle), onLoad: false),
        Feature(id: "hair_hits_cloth", title: String(localized: "Let hair hit swaying clothes", bundle: #bundle), detail: String(localized: "Also collides hair with swaying rigid bodies like jacket hems and cloth meshes like hoods and sleeves (experimental)", bundle: #bundle), onLoad: true, optIn: true),
        Feature(id: "attach_locked", title: String(localized: "Attach fixed chains to swaying parts", bundle: #bundle), detail: String(localized: "Extends chains named per model (physics.attach) from their parent rigid body", bundle: #bundle), onLoad: true),
        Feature(id: "vrm_spring_params", title: String(localized: "Use the author's VRM spring settings", bundle: #bundle), detail: String(localized: "Copies the author's stiffness and drag (experimental; less sway and more hair clipping)", bundle: #bundle), onLoad: true, optIn: true),
        Feature(id: "dance_flips", title: String(localized: "Fix flipped legs in song dances", bundle: #bundle), detail: String(localized: "Restores the knee direction when loading", bundle: #bundle), onLoad: false),
        Feature(id: "step_ahead", title: String(localized: "Evaluate and simulate one frame ahead in the background", bundle: #bundle), detail: String(localized: "When off, runs on the main thread", bundle: #bundle), onLoad: true),
        Feature(id: "settle_feet", title: String(localized: "Lower floating feet with gravity", bundle: #bundle), detail: String(localized: "Keeps both feet from staying in the air after gestures", bundle: #bundle), onLoad: false),
        Feature(id: "physics_smooth", title: String(localized: "Smooth swaying on 120 Hz displays", bundle: #bundle), detail: String(localized: "Hides step-to-step jitter (swaying parts lag one frame)", bundle: #bundle), onLoad: false),
        Feature(id: "hands_out", title: String(localized: "Keep dancing hands outside the body", bundle: #bundle), detail: String(localized: "Keeps hands from sinking into the chest or face in song dances", bundle: #bundle), onLoad: false),
        Feature(id: "oit", title: String(localized: "Order-independent transparency (OIT)", bundle: #bundle), detail: String(localized: "When off, blends in PMX order", bundle: #bundle), onLoad: false),
        Feature(id: "present_transaction", title: String(localized: "Present the drawing rect and image together", bundle: #bundle), detail: String(localized: "When off, may flicker right after sitting and similar moments", bundle: #bundle), onLoad: false),
    ]
}

struct AdvancedTab: View {
    let actions: SettingsActions
    @AppStorage(SettingsKey.disabledFeatures) private var disabled = ""
    @AppStorage(SettingsKey.physicsHz) private var physicsHz = 0
    @AppStorage(SettingsKey.bustFrequency) private var bustFrequency = ""
    @AppStorage(SettingsKey.bustDamping) private var bustDamping = ""
    @AppStorage(SettingsKey.bustGravity) private var bustGravity = ""
    @AppStorage(SettingsKey.bustLimit) private var bustLimit = ""
    @AppStorage(SettingsKey.profileDir) private var profileDir = ""
    @AppStorage(SettingsKey.analyzeKnobs) private var analyzeKnobs = ""

    var body: some View {
        Form {
            Section {
                ForEach(Feature.all) { f in
                    Toggle(isOn: binding(f)) {
                        Text(f.title)
                        Text(f.onLoad ? String(localized: "\(f.detail) (applies after reloading)", bundle: #bundle) : f.detail)
                    }
                }
            } header: {
                Text("Processing", bundle: #bundle)
            } footer: {
                Text("Turn off to compare before and after (all on by default except experimental ones)", bundle: #bundle).foregroundStyle(.secondary)
            }
            Section {
                Picker(selection: $physicsHz) {
                    Text(verbatim: "60Hz").tag(0)
                    Text(verbatim: "120Hz").tag(120)
                    Text(verbatim: "240Hz").tag(240)
                } label: {
                    label("Physics step", "metronome")
                    Text("60 Hz by default. 120 and 240 are finer", bundle: #bundle)
                }
                .pickerStyle(.segmented)
                LabeledContent {
                    HStack {
                        TextField(text: $bustFrequency, prompt: Text("Frequency 2.2", bundle: #bundle)) { EmptyView() }.frame(width: 80)
                        TextField(text: $bustDamping, prompt: Text("Damping 0.18", bundle: #bundle)) { EmptyView() }.frame(width: 80)
                        TextField(text: $bustGravity, prompt: Text("Gravity 0.5", bundle: #bundle)) { EmptyView() }.frame(width: 70)
                        TextField(text: $bustLimit, prompt: Text("Limit 0.6", bundle: #bundle)) { EmptyView() }.frame(width: 70)
                    }
                } label: {
                    label("Bust physics", "waveform.path")
                }
            } header: {
                Text("Physics", bundle: #bundle)
            } footer: {
                Text("Empty fields use defaults. Strength is Bust physics strength in Appearance", bundle: #bundle).foregroundStyle(.secondary)
            }
            Section {
                let catalog = actions.rules()
                ForEach(catalog.rules, id: \.name) { r in
                    Toggle(isOn: ruleBinding(r.name)) {
                        Text(r.name)
                        Text(r.user ? String(localized: "\(r.kind) · User", bundle: #bundle) : String(localized: "\(r.kind) · Built-in", bundle: #bundle))
                    }
                    .disabled(r.name == "default")
                }
                ForEach(catalog.errors, id: \.self) { Text($0).foregroundStyle(.red) }
                LabeledContent {
                    TextField(String("skin_color=0.12"), text: $analyzeKnobs).frame(width: 200)
                } label: {
                    label("Analysis thresholds", "slider.horizontal.3")
                    Text("name=value, comma-separated. Empty uses defaults (applies after reloading)", bundle: #bundle)
                }
                LabeledContent {
                    HStack {
                        Text(profileDir.isEmpty ? String(localized: "Default (Application Support/ringomate/profiles)", bundle: #bundle) : profileDir)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button { chooseProfileDir() } label: { Text("Choose…", bundle: #bundle) }
                        if !profileDir.isEmpty { Button { profileDir = "" } label: { Text("Reset to Default", bundle: #bundle) } }
                    }
                } label: {
                    label("User rules", "folder")
                }
                Button {
                    let dir = profileDir.isEmpty
                        ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ringomate/profiles")
                        : URL(filePath: profileDir)
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                } label: {
                    Text("Open Folder", bundle: #bundle)
                }
            } header: {
                Text("Rules (profiles)", bundle: #bundle)
            } footer: {
                Text("Model-specific rules (match_name) > analysis > family rules. Turning off applies after reloading", bundle: #bundle).foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Text("Environment variables set at launch (such as MASCOT_DISABLE) take priority", bundle: #bundle).foregroundStyle(.secondary)
                    Spacer()
                    Button { actions.reload() } label: { Text("Reload and apply", bundle: #bundle) }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ f: Feature) -> Binding<Bool> { $disabled.member(f.optIn ? "+" + f.id : f.id, present: f.optIn) }

    /// `MASCOT_DISABLE` に `rule:名前`
    private func ruleBinding(_ name: String) -> Binding<Bool> { $disabled.member("rule:" + name, present: false) }

    private func chooseProfileDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        profileDir = url.path
    }
}
