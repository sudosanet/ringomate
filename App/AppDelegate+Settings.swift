import Agent
import AppKit
import Behavior
import CoreBridge
import Engine
import CoreGraphics
import Overlay
import Render
import Settings
import AI
import FoundationModels
import MascotCore
import os
import simd

extension AppDelegate {
    func watchProfiles() {
        let custom = launchEnv["MASCOT_PROFILE_DIR"] ?? UserDefaults.standard.string(forKey: SettingsKey.profileDir) ?? ""
        let dir = custom.isEmpty
            ? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ringomate/profiles")
            : URL(filePath: custom)
        guard dir.path != watchedProfileDir else { return }
        profileWatcher?.cancel()
        watchedProfileDir = dir.path
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.profileReload?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, let model = UserDefaults.standard.string(forKey: Self.lastModelKey) else { return }
                        self.log.info("profiles changed, reloading")
                        self.load(model, remembering: false)
                    }
                }
                self.profileReload = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        profileWatcher = source
    }

    @objc func showSettings() { settingsWindow.show() }

    var diagnosticsEnabled: Bool { UserDefaults.standard.bool(forKey: SettingsKey.diagnostics) }

    @objc func showModels() { settingsWindow.show(.models) }

    var fullScreenMode: String {
        let d = UserDefaults.standard
        return d.string(forKey: SettingsKey.fullScreenMode) ?? ""
    }

    func applySettings() {
        let d = UserDefaults.standard
        ai = .read()
        (chatter.style, conversation.style, desktopThings.style) = (ai.style, ai.style, ai.style)
        if chatTriggers.config != ai.triggers { chatTriggers.config = ai.triggers }
        guard let overlay else { return }
        if let h = d.object(forKey: SettingsKey.characterHeight) as? Double, Float(h) != overlay.characterHeight {
            overlay.characterHeight = Float(h)
        }
        mascot.restScale = Float(d.double(forKey: SettingsKey.restScale))
        overlay.hidesInFullScreen = fullScreenMode == "hide"
        overlay.allowsCapture = launchEnv["MASCOT_ALLOW_CAPTURE"] == "1"
            || d.bool(forKey: SettingsKey.allowCapture)
        let cap = Float(d.integer(forKey: SettingsKey.maxFrameRate))
        overlay.maxFrameRate = cap
        overlay.stillFrameRate = Float(d.integer(forKey: SettingsKey.stillFrameRate))
        let off = disabledFeatures
        rampMode = d.string(forKey: SettingsKey.rampMode) ?? ""
        watchProfiles()
        overlay.presentsApart = off.contains("present_transaction")
        guard let renderer else { return }
        renderer.shadowEnabled = d.bool(forKey: SettingsKey.selfShadow) && !off.contains("self_shadow")
        renderer.oitEnabled = !off.contains("oit")
        renderer.bloomStrength = off.contains("bloom") ? 0 : Float(d.double(forKey: SettingsKey.bloomStrength))
        renderer.rimStrength = Float(d.double(forKey: SettingsKey.rimStrength))
        renderer.outlineScale = Float(d.double(forKey: SettingsKey.outlineScale))
        renderer.faceShading = Float(d.double(forKey: SettingsKey.faceShading))
        renderer.specularStrength = off.contains("specular") ? 0 : Float(d.double(forKey: SettingsKey.specularStrength))
        renderer.edgeTint = off.contains("edge_tint") ? 0 : Float(d.double(forKey: SettingsKey.edgeTint))
        renderer.wallpaperTint = off.contains("wallpaper_tint") ? 0 : Float(d.double(forKey: SettingsKey.wallpaperTint))
        renderer.antialiasing = off.contains("msaa") ? 1 : d.integer(forKey: SettingsKey.antialiasing)
        groundShadowStrength = off.contains("ground_shadow") ? 0 : Float(d.double(forKey: SettingsKey.groundShadow))
        renderer.textureQuality = off.contains("texture_hq") ? 0 : d.integer(forKey: SettingsKey.textureQuality)
        overlay.colorMatched = d.bool(forKey: SettingsKey.colorMatch) && !off.contains("color_match")
    }

    var disabledFeatures: Set<String> {
        let names = (launchEnv["MASCOT_DISABLE"] ?? "") + "," + (UserDefaults.standard.string(forKey: SettingsKey.disabledFeatures) ?? "")
        return Set(names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    func applyLoadSettings() {
        let d = UserDefaults.standard
        let text = { (key: String) in d.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? "" }
        let hz = d.integer(forKey: SettingsKey.physicsHz)
        let bust = [SettingsKey.bustFrequency, SettingsKey.bustDamping, SettingsKey.bustGravity, SettingsKey.bustLimit].map(text)
            + ["\(d.double(forKey: SettingsKey.bustStrength))"]
        Flags.set([
            "MASCOT_PROFILE": text(SettingsKey.profile),
            "MASCOT_PROFILE_DIR": text(SettingsKey.profileDir),
            "MASCOT_DISABLE": disabledFeatures.sorted().joined(separator: ","),
            "MASCOT_ANALYZE": text(SettingsKey.analyzeKnobs),
            "MASCOT_PHYSICS_HZ": hz > 0 ? "\(hz)" : nil,
            "MASCOT_BUST": bust.joined(separator: ","),
            "MASCOT_HAIR": "soft=\(d.double(forKey: SettingsKey.hairSoftness))",
        ])
    }
}
