import AppKit
import MascotCore
import os
import QuartzCore
import Render

@MainActor
public final class OverlayController {
    public struct Pointer {
        public var location: SIMD2<Float>
        public var part: UInt8
        public var pressed: Bool
        public var released: Bool
    }

    public typealias FrameRate = MascotCore.FrameRate

    public struct FrameResult {
        public var root: SIMD2<Float>
        public var frameRate: FrameRate
        public var bubble: String?
        public var frozen: Bool
        public var puffs: [SIMD3<Float>]
        public var hidden = false
        public var travelling = false
        public var bounds: (SIMD2<Float>, SIMD2<Float>)?

        public init(root: SIMD2<Float>, frameRate: FrameRate, bubble: String? = nil, frozen: Bool = false,
                    puffs: [SIMD3<Float>] = [], bounds: (SIMD2<Float>, SIMD2<Float>)? = nil) {
            self.bounds = bounds
            self.puffs = puffs
            self.root = root
            self.frameRate = frameRate
            self.bubble = bubble
            self.frozen = frozen
        }
    }

    public struct Ledge: Equatable, Sendable {
        public var id: Int
        public var minX: Float
        public var maxX: Float
        public var top: Float
        public var bottom: Float
        public var climbLeft: Bool
        public var climbRight: Bool
    }

    public typealias FrameHandler = (_ dt: Float, _ pointer: Pointer, _ skin: UnsafeMutableRawBufferPointer,
                                     _ positions: UnsafeMutableRawBufferPointer) -> FrameResult
    public typealias StageHandler = (_ width: Float, _ ground: Float) -> Void

    private let renderer: Renderer
    private let onFrame: FrameHandler
    private let onStage: StageHandler
    private var panels: [OverlayPanel] = []
    private var observer: NSObjectProtocol?
    private var screenIndex = 0
    private var displayID: CGDirectDisplayID?

    public var currentScreen: NSScreen? {
        panels.indices.contains(screenIndex) ? panels[screenIndex].screen : NSScreen.screens.first
    }

    public var stageWidth: Float { Float(currentScreen?.frame.width ?? 1000) / pointsPerUnit }

    public var characterHeight: Float = 360 {
        didSet { notifyStage() }
    }

    public var maxFrameRate: Float = 120
    public var stillFrameRate: Float = 60

    public var presentsApart = false
    public var colorMatched = true

    /// false のあいだはパネルを持たない（ウィンドウも描画のループも作らない）
    public var isVisible = true {
        didSet {
            guard isVisible != oldValue else { return }
            rebuild()
        }
    }

    public init(renderer: Renderer, onFrame: @escaping FrameHandler, onStage: @escaping StageHandler) {
        self.renderer = renderer
        self.onFrame = onFrame
        self.onStage = onStage
    }

    public func start() {
        rebuild()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    public var panelCount: Int { panels.count }

    public var pointsPerUnit: Float { characterHeight / max(renderer.modelHeight ?? 20, 1) }

    public private(set) var windows: [DesktopWindow] = []
    public private(set) var ledges: [Ledge] = []
    private var lastWindowPoll: CFTimeInterval = 0
    public var hidesInFullScreen = true
    public var allowsCapture = false {
        didSet { panels.forEach { $0.sharingType = allowsCapture ? .readOnly : .none } }
    }
    public var choice: (prompt: String, answer: @MainActor (Bool) -> Void)?
    public private(set) var hiddenForFullScreen = false
    public private(set) var fullScreenActive = false

    func pollWindows(now: CFTimeInterval, fast: Bool) {
        guard now - lastWindowPoll > (fast ? 0.3 : 1.0), let screen = currentScreen,
              let mainHeight = NSScreen.screens.first?.frame.height else { return }
        lastWindowPoll = now
        windows = listDesktopWindows()
        fullScreenActive = windows.first.map { $0.frame.size == screen.frame.size } == true
        let fullScreen = hidesInFullScreen && fullScreenActive
        if fullScreen != hiddenForFullScreen {
            hiddenForFullScreen = fullScreen
            for p in panels { p.alphaValue = fullScreen ? 0 : 1 }
        }
        let ppu = pointsPerUnit
        let height = CGFloat(characterHeight)
        let screenTop = screen.visibleFrame.maxY
        ledges = windows.enumerated().compactMap { i, w in
            let top = mainHeight - w.frame.minY - screen.frame.minY
            guard w.frame.minX >= screen.frame.minX, w.frame.maxX <= screen.frame.maxX + 1,
                  top + screen.frame.minY + height * 0.85 < screenTop,
                  let (minX, maxX) = Self.visibleTop(of: w.frame, under: windows[..<i].map(\.frame), clearance: height * 0.85)
            else { return nil }
            let bottom = mainHeight - w.frame.maxY - screen.frame.minY
            let front = windows[..<i].map(\.frame)
            func side(_ x: CGFloat, _ open: Bool) -> Bool {
                let strip = CGRect(x: x - 4, y: w.frame.minY, width: 8, height: w.frame.height)
                return open && !front.contains { $0.intersects(strip) }
            }
            return Ledge(id: w.number, minX: Float(minX - screen.frame.minX) / ppu,
                         maxX: Float(maxX - screen.frame.minX) / ppu, top: Float(top) / ppu,
                         bottom: Float(bottom) / ppu,
                         climbLeft: side(w.frame.minX - 4, minX <= w.frame.minX + 1),
                         climbRight: side(w.frame.maxX + 4, maxX >= w.frame.maxX - 1))
        }
    }

    nonisolated static func visibleTop(of frame: CGRect, under front: [CGRect], clearance: CGFloat = 0) -> (CGFloat, CGFloat)? {
        var open = [(frame.minX, frame.maxX)]
        for f in front where f.minY <= frame.minY + 1 && f.maxY > frame.minY + 1 - clearance {
            open = open.flatMap { a, b -> [(CGFloat, CGFloat)] in
                [(a, min(b, f.minX)), (max(a, f.maxX), b)].filter { $0.1 - $0.0 > 1 }
            }
        }
        return open.filter { $0.1 - $0.0 >= 120 }.max { $0.1 - $0.0 < $1.1 - $1.0 }
    }

    private var mainView: CharacterView? { panels.first?.contentView as? CharacterView }

    public func snapshot() -> CGImage? { mainView?.snapshot() }

    public func modelDidLoad() { notifyStage() }

    private func notifyStage() {
        guard let screen = currentScreen else { return }
        let ppu = pointsPerUnit
        let ground = Float(screen.visibleFrame.minY - screen.frame.minY) / ppu
        onStage(Float(screen.frame.width) / ppu, ground)
    }

    private func rebuild() {
        for panel in panels {
            (panel.contentView as? CharacterView)?.detach()
            panel.close()
        }
        guard isVisible else {
            panels = []
            return
        }
        let ids = NSScreen.screens.map(Self.displayID)
        screenIndex = Self.index(of: displayID, in: ids)
        displayID = ids.indices.contains(screenIndex) ? ids[screenIndex] : nil
        panels = NSScreen.screens.enumerated().map { i, screen in
            let panel = OverlayPanel(screen: screen)
            panel.sharingType = allowsCapture ? .readOnly : .none
            if i == screenIndex {
                panel.contentView = CharacterView(controller: self, panel: panel)
            }
            return panel
        }
        panels.forEach { $0.orderFrontRegardless() }
        notifyStage()
    }

    static func neighbor(frames: [CGRect], current: Int, dir: Int) -> Int? {
        guard frames.indices.contains(current) else { return nil }
        let c = frames[current]
        return frames.indices.first { i in
            guard i != current else { return false }
            let f = frames[i]
            let touches = dir > 0 ? abs(f.minX - c.maxX) < 2 : abs(f.maxX - c.minX) < 2
            return touches && abs(f.minY - c.minY) < min(c.height, f.height) * 0.25
        }
    }

    private static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    nonisolated static func index(of id: CGDirectDisplayID?, in ids: [CGDirectDisplayID?]) -> Int {
        id.flatMap { ids.firstIndex(of: $0) } ?? 0
    }

    private var frames: [CGRect] { panels.map { $0.screen?.frame ?? .zero } }

    public var exits: (left: Bool, right: Bool) {
        (Self.neighbor(frames: frames, current: screenIndex, dir: -1) != nil,
         Self.neighbor(frames: frames, current: screenIndex, dir: 1) != nil)
    }

    public func neighborStage(_ dir: Int) -> (width: Float, ground: Float)? {
        guard let j = Self.neighbor(frames: frames, current: screenIndex, dir: dir), let s = panels[j].screen else { return nil }
        let ppu = pointsPerUnit
        return (Float(s.frame.width) / ppu, Float(s.visibleFrame.minY - s.frame.minY) / ppu)
    }

    public func moveToNeighbor(_ dir: Int) {
        guard let j = Self.neighbor(frames: frames, current: screenIndex, dir: dir) else { return }
        (panels[screenIndex].contentView as? CharacterView)?.detach()
        panels[screenIndex].contentView = nil
        panels[screenIndex].ignoresMouseEvents = true
        screenIndex = j
        displayID = panels[j].screen.flatMap(Self.displayID)
        panels[j].contentView = CharacterView(controller: self, panel: panels[j])
        notifyStage()
    }

    func followMouseToScreen(holding: Bool) {
        let mouse = NSEvent.mouseLocation
        guard holding, let j = panels.firstIndex(where: { $0.screen?.frame.contains(mouse) == true }),
              j != screenIndex else { return }
        (panels[screenIndex].contentView as? CharacterView)?.detach()
        panels[screenIndex].contentView = nil
        panels[screenIndex].ignoresMouseEvents = true
        screenIndex = j
        displayID = panels[j].screen.flatMap(Self.displayID)
        let view = CharacterView(controller: self, panel: panels[j], holding: true)
        panels[j].contentView = view
        notifyStage()
    }

    func frame(dt: Float, pointer: Pointer, skin: UnsafeMutableRawBufferPointer,
                           positions: UnsafeMutableRawBufferPointer) -> FrameResult {
        onFrame(dt, pointer, skin, positions)
    }

    var rendererForView: Renderer { renderer }
}
