import Foundation
import MascotCore
import os
import Listen
import Senses

@MainActor
final class DanceLips {
    private let log = Logger(subsystem: "app.ringomate", category: "lips")
    private let tap = AppAudioTap()
    private var lastPick = Date.distantPast
    private var source = ""

    private static let preferred = ["com.apple.Music", "com.spotify.client", "com.apple.TV", "com.apple.Safari", "com.google.Chrome",
                                    "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser"]

    func update(dancing: Bool, enabled: Bool, ownMouth: Bool, packLips: [Float]?, micApps: Set<String>) -> [Float]? {
        guard enabled, dancing else {
            stop("off")
            return nil
        }
        if ownMouth {
            stop("dance has its own mouth")
            return nil
        }
        if let packLips {
            stop("song pack")
            return packLips
        }
        if Date().timeIntervalSince(lastPick) > 2 {
            lastPick = Date()
            if let app = Self.pick(SystemSensor.outputApps(), micApps: micApps) {
                tap.start(bundleID: app)
                report("app \(app)")
            } else {
                stop("no single app")
            }
        }
        return tap.app == nil ? nil : tap.vowels()
    }

    func suspend() { stop("hidden") }

    private func stop(_ why: String) {
        if tap.app != nil { tap.stop() }
        report(why)
    }

    private func report(_ s: String) {
        guard s != source else { return }
        source = s
        log.info("lips: \(s, privacy: .public)")
    }

    static func pick(_ outputs: Set<String>, micApps: Set<String>) -> String? {
        let own = Bundle.main.bundleIdentifier ?? "app.ringomate"
        let calls = Set(micApps.map(appBundleBase))
        let apps = Set(outputs.map(appBundleBase)).filter { $0 != own && $0 != "com.apple.replayd" && !calls.contains($0) && !$0.isEmpty }
        if apps.count == 1 { return apps.first }
        return preferred.first { apps.contains($0) }
    }
}
