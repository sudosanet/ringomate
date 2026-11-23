import AppKit
import Settings

/// 非表示のあいだは何もしない。ウィンドウ・描画・画面と音の取り込み・通知の監視を止めて、モデル（キャラ・声・音）を外す。
/// Claude Code のフックのイベントは記録だけ続ける（表示したときに状態が合うように）。
extension AppDelegate: NSMenuItemValidation {
    func suspend() {
        overlay?.isVisible = false
        beats.stop()
        beats.releaseModel()
        moodListener.releaseModel()
        danceLips.suspend()
        notices.suspend()
        voice.suspended = true
        remote.hidden = true
        unloadCharacter()
        log.notice("hidden: suspended")
    }

    func resume() {
        remote.hidden = false
        voice.suspended = false
        overlay?.isVisible = true
        if let path = ModelLibrary.current { load(path, remembering: false) }
        log.notice("shown: resumed")
    }

    func unloadCharacter() {
        core.unload()
        renderer?.unload()
        modelGeneration += 1
        installSongDance()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(talkFromMenu) || item.action == #selector(resetCharacter) else { return true }
        return overlay?.isVisible != false
    }
}
