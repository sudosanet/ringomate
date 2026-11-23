#if DEBUG
import AppKit
import ImageIO
import MascotCore
import UniformTypeIdentifiers
import Listen

// 開発用: `notifyutil -p app.ringomate.<名前>`。Release には入れない（誰からでも送れるため）
extension AppDelegate {
    func installDebugHooks() {
        let hooks: [(String, @MainActor (AppDelegate) -> Void)] = [
            ("snapshot", { $0.saveSnapshot() }),
            ("dumpaudio", { $0.dumpHeardAudio() }),
            ("sit", { $0.mascot.requestSit() }),
            ("doze", { $0.mascot.requestHug(doze: 25) }),
            ("hug", { $0.mascot.requestHug() }),
            ("settings", { $0.showModels() }),
            ("toggle", { $0.setVisible(!($0.overlay?.isVisible ?? true)) }),
        ]
        for (name, action) in hooks {
            let token = UnsafeMutableRawPointer(Unmanaged.passRetained(DebugHook(app: self, action: action)).toOpaque())
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), token,
                { _, observer, _, _, _ in
                    guard let observer else { return }
                    let hook = Unmanaged<DebugHook>.fromOpaque(observer).takeUnretainedValue()
                    DispatchQueue.main.async { MainActor.assumeIsolated { hook.fire() } }
                },
                "app.ringomate.\(name)" as CFString, nil, .deliverImmediately
            )
        }
    }

    private static var logsDirectory: URL {
        let dir = URL.libraryDirectory.appending(path: "Logs/ringomate")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func saveSnapshot() {
        guard let image = overlay?.snapshot() else { return }
        let url = Self.logsDirectory.appending(path: "snapshot.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        let ok = CGImageDestinationFinalize(dest)
        log.info("snapshot saved: \(ok) \(url.path, privacy: .public) root \(self.body.root.x, privacy: .public),\(self.body.root.y, privacy: .public)")
    }

    private func dumpHeardAudio() {
        guard let audio = beats.recentAudio(seconds: 16) ?? beats.recentAudio(seconds: 8) else {
            log.notice("dumpaudio: no audio yet")
            return
        }
        let rate = UInt32(BeatTracker.rate)
        var pcm = Data(capacity: audio.samples.count * 2)
        for x in audio.samples {
            var v = Int16(max(-1, min(1, x)) * 32767).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var wav = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + UInt32(pcm.count)); wav.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count)); wav.append(pcm)
        let url = Self.logsDirectory.appending(path: "heard.wav")
        do {
            try wav.write(to: url)
            log.notice("dumpaudio: \(audio.samples.count) samples (end \(audio.end)) -> \(url.path, privacy: .public)")
        } catch {
            log.error("dumpaudio: \(error, privacy: .public)")
        }
    }
}

@MainActor
private final class DebugHook {
    let app: AppDelegate
    let action: (AppDelegate) -> Void
    init(app: AppDelegate, action: @escaping (AppDelegate) -> Void) { self.app = app; self.action = action }
    func fire() { action(app) }
}
#endif
