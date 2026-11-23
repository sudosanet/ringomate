import AppKit
import Update

extension AppDelegate {
    /// 起動したときと 1 日ごとに新しい版を探し、あればメニューの先頭に出す（Debug は版が 0.0.0 なので探さない）
    func startUpdates() {
        #if !DEBUG
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let updater = Updater(current: version)
        let log = self.log
        let check: @Sendable () async -> Void = {
            do {
                guard let release = try await updater.check() else { return }
                await MainActor.run { [weak self] in self?.offer(release, updater) }
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

    private func offer(_ release: Updater.Release, _ updater: Updater) {
        guard let item = statusItem?.menu?.item(withTag: Self.updateItemTag) else { return }
        item.title = String(localized: "Update to \(release.version) and Restart")
        item.isHidden = false
        item.isEnabled = true
        item.target = self
        item.action = #selector(installUpdate(_:))
        item.representedObject = UpdateOffer(release: release, updater: updater)
    }

    @objc func installUpdate(_ item: NSMenuItem) {
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
                // 置き換えられない場所（書き込めない・ダウンロードから直接開いた）なら Release のページを開く
                NSWorkspace.shared.open(offer.release.page)
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
