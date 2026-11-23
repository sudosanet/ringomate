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
    func buildMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = statusImage()
        let menu = NSMenu()
        let assets = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        assets.isEnabled = false
        assets.isHidden = true
        songService.onSyncProgress = { p in
            assets.isHidden = p == nil
            if let p { assets.title = String(localized: "Downloading assets… \(p.done)/\(p.total)") }
        }
        let update = menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        update.isHidden = true
        update.tag = Self.updateItemTag
        startUpdates()
        let hide = menu.addItem(withTitle: String(localized: "Hide Character"), action: #selector(toggleVisible(_:)), keyEquivalent: "h")
        hide.target = self
        hide.tag = Self.visibleItemTag
        menu.addItem(withTitle: String(localized: "Talk…"), action: #selector(talkFromMenu), keyEquivalent: "t").target = self
        menu.addItem(withTitle: String(localized: "Reset Character"), action: #selector(resetCharacter), keyEquivalent: "r").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "About RingoMate"), action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        buildEditMenu()
    }

    /// アプリアイコン（吹き出しのりんご）のシルエット。点は 18pt では元の大きさだと潰れるので大きくしてある。
    private func statusImage() -> NSImage {
        let side: CGFloat = 18
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let body = NSBezierPath()
            let leaf = NSBezierPath()
            let tail = NSBezierPath()
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: 512 + x * 2.9, y: 500 + y * 2.9)
            }
            body.move(to: p(0, -70))
            body.curve(to: p(110, 0), controlPoint1: p(40, -100), controlPoint2: p(110, -80))
            body.curve(to: p(30, 110), controlPoint1: p(110, 70), controlPoint2: p(60, 110))
            body.curve(to: p(0, 100), controlPoint1: p(15, 110), controlPoint2: p(10, 100))
            body.curve(to: p(-30, 110), controlPoint1: p(-10, 100), controlPoint2: p(-15, 110))
            body.curve(to: p(-110, 0), controlPoint1: p(-60, 110), controlPoint2: p(-110, 70))
            body.curve(to: p(0, -70), controlPoint1: p(-110, -80), controlPoint2: p(-40, -100))
            body.close()
            let dot: CGFloat = 46
            for x in [CGFloat(400), 512, 624] {
                body.appendOval(in: CGRect(x: x - dot, y: 540 - dot, width: dot * 2, height: dot * 2))
            }
            body.windingRule = .evenOdd
            leaf.move(to: p(0, -70))
            leaf.curve(to: p(55, -135), controlPoint1: p(0, -110), controlPoint2: p(20, -130))
            leaf.curve(to: p(0, -70), controlPoint1: p(55, -100), controlPoint2: p(30, -75))
            leaf.close()
            tail.move(to: CGPoint(x: 300, y: 700))
            tail.line(to: CGPoint(x: 190, y: 860))
            tail.line(to: CGPoint(x: 420, y: 770))
            tail.close()

            let bounds = {
                let all = NSBezierPath()
                all.append(body)
                all.append(leaf)
                all.append(tail)
                return all.bounds
            }()
            let box = rect.insetBy(dx: 0.5, dy: 0.5)
            let scale = min(box.width / bounds.width, box.height / bounds.height)
            let drawn = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let origin = CGPoint(x: box.midX - drawn.width / 2, y: box.midY - drawn.height / 2)
            let transform = NSAffineTransform()
            transform.translateX(by: origin.x, yBy: origin.y + drawn.height)
            transform.scaleX(by: scale, yBy: -scale)
            transform.translateX(by: -bounds.minX, yBy: -bounds.minY)
            transform.concat()
            NSColor.black.setFill()
            body.fill()
            leaf.fill()
            tail.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "RingoMate"
        return image
    }

    /// 入力欄の ⌘C・⌘V などはメインメニューの「編集」を通る。メニューバーに出ないアプリ（accessory）でもこのメニューは要る（表示はされない）。
    private func buildEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let root = NSMenuItem()
        root.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem())
        main.addItem(root)
        NSApp.mainMenu = main
    }

    @objc func toggleVisible(_ sender: NSMenuItem) {
        setVisible(!(overlay?.isVisible ?? true))
    }

    func setVisible(_ visible: Bool) {
        guard let overlay, overlay.isVisible != visible else { return }
        visible ? resume() : suspend()
        statusItem?.menu?.item(withTag: Self.visibleItemTag)?.title = visible ? String(localized: "Hide Character") : String(localized: "Show Character")
    }

    @objc func resetCharacter() {
        guard let model = ModelLibrary.current else { return }
        load(model, remembering: false)
    }

    @objc func showAbout() { settingsWindow.show(.about) }
}
