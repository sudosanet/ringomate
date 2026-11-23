import AppKit
import Behavior
import MascotCore
import os
import Senses

/// 頼まれたときだけ足もとの帯を測る。撮った絵は保存しない。
@MainActor
final class FreeSpaceWatcher {
    private var columns: [Float] = []
    private var at = Date.distantPast
    private var measuring = false
    private let log = Logger(subsystem: "app.ringomate", category: "space")
    static let freshSeconds: TimeInterval = 5

    func apply(to world: inout Mascot.World, enabled: Bool) {
        world.canLookForSpace = enabled
        if enabled, Date().timeIntervalSince(at) < Self.freshSeconds { world.busy = columns }
    }

    func request(screen: NSScreen?, characterHeight: CGFloat, windows: [DesktopWindow], neverLook: [String]) {
        guard !measuring, let screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        measuring = true
        let frame = screen.frame
        let bottom = screen.visibleFrame.minY - frame.minY
        let band = CGRect(x: 0, y: max(frame.height - bottom - characterHeight, 0), width: frame.width, height: min(characterHeight, frame.height))
        // 見ない窓は撮らないので、その列はふさがっている扱い
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        let bandGlobal = CGRect(x: frame.minX, y: mainHeight - frame.minY - bottom - characterHeight, width: frame.width, height: characterHeight)
        let hidden = windows.filter { w in
            w.frame.intersects(bandGlobal)
                && !mayLook(atApp: NSRunningApplication(processIdentifier: w.pid)?.bundleIdentifier, extra: neverLook)
        }.map { ($0.frame.minX - frame.minX) / frame.width...($0.frame.maxX - frame.minX) / frame.width }
        Task { [weak self] in
            let measured = await FreeSpace.busyColumns(displayID: id, band: band) { !mayLook(atApp: $0, extra: neverLook) }
            guard let self else { return }
            measuring = false
            guard var c = measured else {
                log.debug("space: no capture")
                return
            }
            let n = c.count
            for r in hidden {
                let lo = max(Int(r.lowerBound * CGFloat(n)), 0), hi = min(Int(r.upperBound * CGFloat(n)), n - 1)
                if lo <= hi { for i in lo...hi { c[i] = 1 } }
            }
            (columns, at) = (c, Date())
            log.debug("space: \(c.map { $0 < 0.05 ? "." : $0 < 0.3 ? "-" : "#" }.joined(), privacy: .public)")
        }
    }
}
