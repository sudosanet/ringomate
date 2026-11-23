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
    func updateModelsStatus() {
        func word(_ s: ModelStatus) -> String {
            switch s {
            case .installed: String(localized: "Installed")
            case .missing: String(localized: "Not installed")
            case .failed: String(localized: "Failed to load")
            }
        }
        let songs = songService.packs.isEmpty ? String(localized: "Not installed") : String(localized: "\(songService.packs.count) songs")
        let text = String(localized: "Beat This!: \(word(beats.modelStatus)), CLAP: \(word(moodListener.status)), song packs: \(songs)")
        guard text != modelsStatus else { return }
        modelsStatus = text
        log.info("models: \(text, privacy: .public)")
    }

    /// 差し替え（コアと描画側）はメインスレッドで同時に行う。
    func load(_ path: String, remembering: Bool = true) {
        // 非表示のあいだは選んだモデルを覚えるだけ。表示したときに読む
        guard overlay?.isVisible != false else {
            UserDefaults.standard.set(path, forKey: Self.lastModelKey)
            if remembering { ModelLibrary.remember([path]) }
            return
        }
        guard !loading else { queuedLoad = (path, remembering); return }
        loading = true
        applyLoadSettings()
        let library = Bundle.main.path(forResource: "UAL1_Standard", ofType: "glb", inDirectory: "ual")
        let core = self.core
        let t0 = Date()
        let status = loadStatus
        (status.path, status.fraction, status.stage) = (path, 0, "")
        let progress: @Sendable (Float, String) -> Void = { f, stage in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if status.path == path { (status.fraction, status.stage) = (Double(f), stage) } }
            }
        }
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try core.prepare(model: path, library: library, progress: progress) }
            }.value
            if install(path, result, since: t0), remembering { ModelLibrary.remember([path]) }
            status.path = nil
            loading = false
            if let next = queuedLoad {
                queuedLoad = nil
                load(next.path, remembering: next.remembering)
            }
        }
    }

    func suggestBones(from model: ModelData) {
        guard let line = model.diagnostics.first(where: { $0.hasPrefix("skeleton: not found ") }) else { return }
        let missing = line.dropFirst("skeleton: not found ".count).split(separator: ", ").map(String.init)
        let bones = model.boneNames
        Task { [weak self] in
            guard let self else { return }
            let s = await boneAssist.suggest(missing: missing, bones: bones)
            for (standard, candidate) in s {
                diagnostics.append("skeleton suggestion (unverified): \(standard) → \(candidate)")
            }
        }
    }

    func installSongDance() {
        mascot.songDances = [:]
        mouthSlots = [:]
        songService.forgetDances()
    }

    func install(_ path: String, _ result: Result<ModelData, Error>, since t0: Date) -> Bool {
        do {
            let model = try result.get()
            guard overlay?.isVisible != false else {
                core.unload()
                return false
            }
            core.commitLoad()
            stepHere = disabledFeatures.contains("step_ahead")
            let t1 = Date()
            (walkSpeed, seatHeight, calmWalkSpeed, carryWalkSpeed) =
                (model.walkSpeed, model.seatHeight, model.calmWalkSpeed, model.carryWalkSpeed)
            let failed = try renderer?.load(MeshInput(model, core: core)) ?? []
            log.info("load timing: core (background) \(Int(t1.timeIntervalSince(t0) * 1000))ms, gpu upload \(Int(Date().timeIntervalSince(t1) * 1000))ms")
            height = model.height
            diagnostics = []
            if diagnosticsEnabled {
                diagnostics = model.diagnostics + failed.map { "texture decode failed: \(model.textures[$0].name)" }
                    + ["translucent materials: \((renderer?.translucentMaterials ?? []).map { model.materials[$0].name }.joined(separator: ", "))"]
                for d in diagnostics { log.info("diag: \(d, privacy: .private)") }
                if ai.boneAssist { suggestBones(from: model) }
            }
            mascot.gestureNames = model.gestures
            modelGeneration += 1
            installSongDance()
            overlay?.modelDidLoad()
            UserDefaults.standard.set(path, forKey: Self.lastModelKey)
            thumbnails.request(path)
            return true
        } catch {
            log.error("load failed \(path, privacy: .private): \(error, privacy: .private)")
            loadStatus.failure = String(localized: "Couldn't load \(URL(filePath: path).lastPathComponent)\n\(error.localizedDescription)")
            return false
        }
    }
}
