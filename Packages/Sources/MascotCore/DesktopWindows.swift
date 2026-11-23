import CoreGraphics
import Foundation

/// 座標は CoreGraphics のグローバル座標（主ディスプレイの左上が原点、y は下向き）。
public struct DesktopWindow: Equatable, Sendable {
    public var number: Int
    public var pid: Int32
    public var owner: String
    public var frame: CGRect
    /// 画面収録の許可があるときだけ読める。
    public var title: String?

    public init(number: Int, pid: Int32, owner: String, frame: CGRect, title: String? = nil) {
        self.title = title
        self.number = number
        self.pid = pid
        self.owner = owner
        self.frame = frame
    }
}

/// 前面から順に返す。
public func listDesktopWindows(excluding pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> [DesktopWindow] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
    return info.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let number = w[kCGWindowNumber as String] as? Int,
              let owner = w[kCGWindowOwnerPID as String] as? Int32, owner != pid,
              (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.1,
              let boundsDict = w[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width >= 120, bounds.height >= 80
        else { return nil }
        return DesktopWindow(number: number, pid: owner, owner: w[kCGWindowOwnerName as String] as? String ?? "",
                             frame: bounds, title: (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

/// 前のウィンドウに隠れていない割合（0〜1）。
public func visibleFraction(of frame: CGRect, under front: [CGRect]) -> Double {
    guard frame.width > 0, frame.height > 0 else { return 0 }
    var seen = 0
    for i in 0..<10 {
        for j in 0..<10 {
            let p = CGPoint(x: frame.minX + (Double(i) + 0.5) * frame.width / 10, y: frame.minY + (Double(j) + 0.5) * frame.height / 10)
            if !front.contains(where: { $0.contains(p) }) { seen += 1 }
        }
    }
    return Double(seen) / 100
}
