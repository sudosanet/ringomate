import AppKit
import Update

extension AppDelegate {
    /// 起動したときと 1 日ごとに新しい版を探し、あれば入れ替えて開き直す。入れ替えられなければメニューの先頭に出す（Debug は版が 0.0.0 なので探さない）
    func startUpdates() {
        #if !DEBUG
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let updater = Updater(current: version)
        let log = self.log
        let check: @Sendable () async -> Void = {
            do {
                guard let release = try await updater.check() else { return }
                await MainActor.run { [weak self] in
                    guard let self, let item = self.offer(release, updater) else { return }
                    self.install(item, automatic: true)
                }
            } catch {
                log.error("update check: \(error, privacy: .public)")
            }
        }
        Task(priority: .utility) { await check() }
        let s = NSBackgroundActivityScheduler(identifier: "app.ringomate.update-check")
        s.repeats = true
        s.interval = 24 * 60 * 60
        s.qualityOfService = .utility
        s.schedule { done in Task { await check(); done(.finished) } }
        updateScheduler = s
        #endif
    }

    private func offer(_ release: Updater.Release, _ updater: Updater) -> NSMenuItem? {
        // 入れ替えている途中なら何もしない
        guard let item = statusItem?.menu?.item(withTag: Self.updateItemTag), item.isHidden || item.isEnabled else { return nil }
        item.title = String(localized: "Update to \(release.version) and Restart")
        item.isHidden = false
        item.isEnabled = true
        item.target = self
        item.action = #selector(installUpdate(_:))
        item.representedObject = UpdateOffer(release: release, updater: updater)
        return item
    }

    @objc func installUpdate(_ item: NSMenuItem) { install(item, automatic: false) }

    private func install(_ item: NSMenuItem, automatic: Bool) {
        guard let offer = item.representedObject as? UpdateOffer else { return }
        item.isEnabled = false
        item.title = String(localized: "Updating…")
        Task { [weak self] in
            do {
                try await offer.updater.install(offer.release)
                try offer.updater.relaunch()
                NSApp.terminate(nil)
            } catch {
                self?.log.error("update: \(error, privacy: .public)")
                // 置き換えられない場所（書き込めない・ダウンロードから直接開いた）なら、メニューから選んだときに Release のページを開く
                if !automatic { NSWorkspace.shared.open(offer.release.page) }
                item.title = String(localized: "Update to \(offer.release.version) and Restart")
                item.isEnabled = true
            }
        }
    }
}

private final class UpdateOffer: NSObject {
    let release: Updater.Release
    let updater: Updater
    init(release: Updater.Release, updater: Updater) { (self.release, self.updater) = (release, updater) }
}
