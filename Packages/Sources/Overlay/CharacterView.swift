import AppKit
import MascotCore
import os
import QuartzCore
import Render

private let log = Logger(subsystem: "app.ringomate", category: "overlay")

@MainActor
final class CharacterView: NSView {
    private unowned let controller: OverlayController
    private unowned let panel: OverlayPanel
    private let metalLayer = CAMetalLayer()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var root: SIMD2<Float>?
    private var pressed = false
    private var released = false
    private var holding = false
    private var frameRate = OverlayController.FrameRate.idle
    private var travelling = false
    private var ticks = 0
    private var ticksSince: CFTimeInterval = 0
    private var cost = (tick: 0.0, step: 0.0, draw: 0.0, worst: 0.0, worstStep: 0.0, worstDraw: 0.0)
    private let bubble = NSTextField(labelWithString: "")
    private lazy var choiceButtons: NSStackView = {
        let allow = NSButton(title: String(localized: "Allow", bundle: #bundle), target: self, action: #selector(allowChoice))
        let deny = NSButton(title: String(localized: "Deny", bundle: #bundle), target: self, action: #selector(denyChoice))
        allow.bezelColor = .systemGreen
        let stack = NSStackView(views: [allow, deny])
        stack.spacing = 6
        stack.isHidden = true
        return stack
    }()
    private var lastPlacement: Placement?
    private var frozen = false
    private var occlusionObserver: NSObjectProtocol?
    private var lastBounds: (SIMD2<Float>, SIMD2<Float>)?
    private var appliedCap: Float = 0
    private var appliedStill: Float = 0
    private var realLayerFrame: CGRect?

    init(controller: OverlayController, panel: OverlayPanel, holding: Bool = false) {
        self.controller = controller
        self.panel = panel
        self.holding = holding
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(metalLayer)
        bubble.font = .systemFont(ofSize: 13, weight: .semibold)
        bubble.textColor = .black
        bubble.drawsBackground = true
        bubble.backgroundColor = NSColor.white.withAlphaComponent(0.92)
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 8
        bubble.isHidden = true
        addSubview(bubble)
        addSubview(choiceButtons)
        metalLayer.contentsScale = panel.backingScaleFactor
        controller.rendererForView.attach(metalLayer)
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.setRunning(self.panel.occlusionState.contains(.visible))
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func detach() {
        link?.invalidate()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        controller.rendererForView.detach(metalLayer)
    }

    func setRunning(_ running: Bool) {
        link?.isPaused = !running
        lastTimestamp = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, link == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        applyFrameRate()
    }

    private func applyFrameRate() {
        let cap = controller.maxFrameRate
        appliedCap = cap
        appliedStill = controller.stillFrameRate
        let base = min(60, cap), still = min(appliedStill, base)
        link?.preferredFrameRateRange = switch frameRate {
        case .active: CAFrameRateRange(minimum: base, maximum: cap, preferred: base)
        case .idle: CAFrameRateRange(minimum: base, maximum: base, preferred: base)
        case .still: CAFrameRateRange(minimum: still, maximum: still, preferred: still)
        case .sleep: CAFrameRateRange(minimum: 15, maximum: 15, preferred: 15)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        pressed = true
        holding = true
    }
    override func mouseUp(with event: NSEvent) {
        released = true
        holding = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let began = CACurrentMediaTime()
        defer {
            CATransaction.commit()
            let ms = (CACurrentMediaTime() - began) * 1000
            cost.tick += ms
            cost.worst = max(cost.worst, ms)
        }
        let renderer = controller.rendererForView
        let dt = Float(min(link.targetTimestamp - (lastTimestamp ?? link.timestamp), 0.1))
        ticks += 1
        if link.timestamp - ticksSince >= 10 {
            if ticksSince > 0 {
                let n = Double(max(ticks - 1, 1))
                log.debug("measured \(Double(self.ticks) / (link.timestamp - self.ticksSince), format: .fixed(precision: 1), privacy: .public) fps, dt \(dt, privacy: .public), ms tick \(self.cost.tick / n, format: .fixed(precision: 2), privacy: .public) step \(self.cost.step / n, format: .fixed(precision: 2), privacy: .public) draw \(self.cost.draw / n, format: .fixed(precision: 2), privacy: .public) worst \(self.cost.worst, format: .fixed(precision: 1), privacy: .public) (step \(self.cost.worstStep, format: .fixed(precision: 1), privacy: .public) draw \(self.cost.worstDraw, format: .fixed(precision: 1), privacy: .public))")
            }
            (ticks, ticksSince) = (0, link.timestamp)
            cost = (0, 0, 0, 0, 0, 0)
        }
        lastTimestamp = link.targetTimestamp
        guard let height = renderer.modelHeight else { return }
        let ppu = controller.pointsPerUnit
        controller.pollWindows(now: link.timestamp, fast: travelling)

        let mouse = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let world = SIMD2(Float(mouse.x), Float(mouse.y)) / ppu

        let inLayer = CGPoint(x: mouse.x - metalLayer.frame.minX, y: metalLayer.frame.maxY - mouse.y)
        let scale = metalLayer.contentsScale
        let part = metalLayer.frame.contains(mouse)
            ? renderer.part(atPixel: Int(inLayer.x * scale), Int(inLayer.y * scale)) : 0
        if holding && NSEvent.pressedMouseButtons & 1 == 0 {
            holding = false
            released = true
        }
        let overChoice = !choiceButtons.isHidden && choiceButtons.frame.insetBy(dx: -4, dy: -4).contains(mouse)
        panel.ignoresMouseEvents = (part == 0 && !holding && !overChoice) || controller.hiddenForFullScreen

        let pointer = OverlayController.Pointer(location: world, part: part, pressed: pressed, released: released)
        (pressed, released) = (false, false)

        // 矩形を動かしたフレームだけは新しい絵と同じトランザクションで出す。
        let h = CGFloat(height * ppu)
        let placeRoot = root ?? SIMD2(Float(bounds.width) / ppu * 0.8, 0)
        let rx = CGFloat(placeRoot.x * ppu), ry = CGFloat(placeRoot.y * ppu)
        var need = CGRect(x: rx - h * 0.75, y: ry - h * 0.15, width: h * 1.5, height: h * 1.45)
        if let (lo, hi) = lastBounds {
            let m = h * 0.28
            need = CGRect(x: CGFloat(lo.x * ppu) - m, y: CGFloat(lo.y * ppu) - m,
                          width: CGFloat((hi.x - lo.x) * ppu) + 2 * m, height: CGFloat((hi.y - lo.y) * ppu) + 2 * m)
        }
        var frame = realLayerFrame ?? .zero
        if frame.isEmpty || !frame.contains(need) || frame.width * frame.height > need.width * need.height * 4 {
            let slack = h * 0.4
            frame = need.insetBy(dx: -slack, dy: -slack)
            frame = CGRect(x: frame.minX.rounded(.down), y: frame.minY.rounded(.down),
                           width: frame.width.rounded(.up), height: frame.height.rounded(.up))
        }
        let moved = frame != realLayerFrame
        metalLayer.presentsWithTransaction = moved && !controller.presentsApart
        if (metalLayer.colorspace != nil) != controller.colorMatched {
            metalLayer.colorspace = controller.colorMatched ? CGColorSpace(name: CGColorSpace.sRGB) : nil
        }
        if moved {
            setLayerFrame(frame)
            realLayerFrame = frame
        }

        let placement = Placement(anchor: SIMD2(Float(-frame.minX), Float(-frame.minY)), pointsPerUnit: ppu)
        lastPlacement = placement
        var result: OverlayController.FrameResult?
        if frozen {
            let empty = UnsafeMutableRawBufferPointer(start: nil, count: 0)
            result = controller.frame(dt: dt, pointer: pointer, skin: empty, positions: empty)
            if result?.frozen != true { frozen = false }
        } else {
            var stepMs = 0.0
            let step = { (skin: UnsafeMutableRawBufferPointer, positions: UnsafeMutableRawBufferPointer) in
                let t = CACurrentMediaTime()
                result = self.controller.frame(dt: dt, pointer: pointer, skin: skin, positions: positions)
                stepMs = (CACurrentMediaTime() - t) * 1000
            }
            let drawBegan = CACurrentMediaTime()
            defer {
                let drawMs = (CACurrentMediaTime() - drawBegan) * 1000 - stepMs
                cost.step += stepMs
                cost.draw += drawMs
                cost.worstStep = max(cost.worstStep, stepMs)
                cost.worstDraw = max(cost.worstDraw, drawMs)
                if stepMs + drawMs > 25 {
                    log.debug("slow frame: step \(stepMs, format: .fixed(precision: 1), privacy: .public) draw \(drawMs, format: .fixed(precision: 1), privacy: .public) ms")
                }
            }
            renderer.draw(metalLayer, placement: placement, update: step)
            frozen = result?.frozen == true && pointer.part == 0
        }
        if let result {
            root = result.root
            lastBounds = result.bounds
            if result.frameRate != frameRate || appliedCap != controller.maxFrameRate || appliedStill != controller.stillFrameRate {
                frameRate = result.frameRate
                applyFrameRate()
                log.debug("frame rate: \(String(describing: result.frameRate), privacy: .public)")
            }
            showBubble(controller.choice?.prompt ?? result.bubble,
                       above: SIMD2(result.root.x * ppu, (result.root.y + height * 1.05) * ppu))
            showChoice(controller.choice != nil)
            if metalLayer.isHidden != result.hidden { metalLayer.isHidden = result.hidden }
            travelling = result.travelling
            for p in result.puffs {
                layer?.addPuff(at: CGPoint(x: CGFloat(p.x * ppu), y: CGFloat(p.y * ppu)), size: CGFloat(p.z * ppu))
            }
        }
        controller.followMouseToScreen(holding: holding)
    }

    private func setLayerFrame(_ frame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = frame
        CATransaction.commit()
        let scale = metalLayer.contentsScale
        metalLayer.drawableSize = CGSize(width: frame.width * scale, height: frame.height * scale)
    }

    func snapshot() -> CGImage? {
        guard let lastPlacement else { return nil }
        return controller.rendererForView.snapshot(
            size: metalLayer.frame.size, scale: Int(metalLayer.contentsScale), placement: lastPlacement)
    }

    @objc private func allowChoice() { answerChoice(true) }
    @objc private func denyChoice() { answerChoice(false) }

    private func answerChoice(_ allow: Bool) {
        let c = controller.choice
        controller.choice = nil
        c?.answer(allow)
    }

    private func showChoice(_ visible: Bool) {
        choiceButtons.isHidden = !visible || bubble.isHidden
        guard !choiceButtons.isHidden else { return }
        let size = choiceButtons.fittingSize
        var x = bubble.frame.maxX + 6
        if x + size.width > bounds.maxX { x = bubble.frame.minX - 6 - size.width }
        choiceButtons.frame = CGRect(x: x, y: bubble.frame.midY - size.height / 2, width: size.width, height: size.height)
    }

    private func showBubble(_ text: String?, above head: SIMD2<Float>) {
        guard let text else {
            bubble.isHidden = true
            return
        }
        let padded = " \(text) "
        if bubble.stringValue != padded { bubble.stringValue = padded }
        bubble.sizeToFit()
        let size = bubble.frame.size
        let x = min(max(CGFloat(head.x) - size.width / 2, bounds.minX + 4), bounds.maxX - size.width - 4)
        let y = min(CGFloat(head.y), bounds.maxY - size.height - 4)
        bubble.setFrameOrigin(CGPoint(x: x, y: y))
        bubble.isHidden = false
    }
}
