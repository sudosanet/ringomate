import Foundation

extension Mascot {
    static let cheerfulStyles: Set<String> = ["happy", "youthful", "childish", "active", "musical"]
    static let gloomyStyles: Set<String> = ["sad", "tired", "exhausted", "not-confident", "angry"]
    static let calmStyles: Set<String> = ["feminine", "normal", "proud"]

    func pickGesture(contents: Set<String>? = nil) -> Int {
        let styles: Set<String>
        if needs.mood < -0.2 || needs.energy < 0.3 {
            styles = Self.gloomyStyles
        } else if needs.cheerful {
            styles = Self.cheerfulStyles
        } else {
            styles = Self.calmStyles.union(Self.cheerfulStyles)
        }
        let parsed = gestureNames.enumerated().map { i, n -> (Int, String, String) in
            let p = n.split(separator: ":").map(String.init)
            return (i, p.first ?? "", p.count > 1 ? p[1] : "")
        }
        func fits(_ g: (Int, String, String), styles: Set<String>?) -> Bool {
            (contents == nil || contents!.contains(g.1) || contents!.contains(where: { g.1.hasPrefix($0) }))
                && (styles == nil || styles!.contains(g.2)) && !recentGestures.contains(g.0)
        }
        var pool = parsed.filter { fits($0, styles: styles) }
        if pool.isEmpty { pool = parsed.filter { fits($0, styles: nil) } }
        let index = pool.isEmpty ? Int(random() * 8) : pool[min(Int(random() * Float(pool.count)), pool.count - 1)].0
        recentGestures = Array((recentGestures + [index]).suffix(6))
        return index
    }

    func libraryExpression(_ index: Int, set: (Expression, Float) -> Void) {
        guard gestureNames.indices.contains(index) else { return }
        let parts = gestureNames[index].split(separator: ":").map(String.init)
        let (content, style) = (parts.first ?? "", parts.count > 1 ? parts[1] : "")
        switch style {
        case _ where Self.cheerfulStyles.contains(style): set(.smile, 0.85); set(.mouthOpen, 0.3)
        case "not-confident": set(.blush, 0.6); set(.troubled, 0.4)
        case "angry": set(.angry, 0.7)
        case _ where Self.gloomyStyles.contains(style): set(.troubled, 0.6)
        default: set(.smile, 0.55); set(.mouthOpen, 0.15)
        }
        if content == "bow" { set(.calm, 0.6) }
    }
}
