import MascotCore
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// 画面収録の許可が要る。撮った絵は保存しない。
public func captureWindow(number: CGWindowID, maxSide: CGFloat = 768) async -> CGImage? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
          let window = content.windows.first(where: { $0.windowID == number }) else { return nil }
    let frame = window.frame
    let scale = min(1, maxSide / max(frame.width, frame.height, 1))
    let config = SCStreamConfiguration()
    config.width = max(Int(frame.width * scale), 1)
    config.height = max(Int(frame.height * scale), 1)
    config.showsCursor = false
    return try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                       configuration: config)
}

/// 壁紙とデスクトップだけのディスプレイ 1 枚。絵の左下 = ディスプレイの左下。
public func captureDesktop(displayID: CGDirectDisplayID, maxSide: CGFloat = 1024) async -> CGImage? {
    guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
          let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
    let scale = min(1, maxSide / CGFloat(max(display.width, display.height, 1)))
    let config = SCStreamConfiguration()
    config.width = max(Int(CGFloat(display.width) * scale), 1)
    config.height = max(Int(CGFloat(display.height) * scale), 1)
    config.showsCursor = false
    let owners = Set(content.windows.filter { $0.windowLayer == 0 }.compactMap { $0.owningApplication?.processID })
    let apps = content.applications.filter { owners.contains($0.processID) && $0.bundleIdentifier != "com.apple.dock" }
    let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
    return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
}

/// パスワード管理・システム設定・ログイン画面・自分は見ない。
/// `extra` は利用者が足す分。組み込みの分は外せない。
public func mayLook(atApp bundleID: String?, extra: [String] = []) -> Bool {
    let neverLook = ["com.1password", "com.agilebits", "com.bitwarden", "com.apple.keychainaccess",
                     "com.apple.Passwords", "com.apple.systempreferences", "com.apple.SystemSettings",
                     "com.apple.loginwindow", "com.apple.SecurityAgent", "com.lastpass", "com.dashlane",
                     "app.ringomate"]
    return !(neverLook + extra).contains { !$0.isEmpty && bundleID?.hasPrefix($0) == true }
}
