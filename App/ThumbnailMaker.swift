import CoreBridge
import Engine
import CoreGraphics
import Foundation
import OSLog
import Render
import Settings

/// 読み込みと焼き込みは裏のスレッド、描くのはメイン。
@MainActor
final class ThumbnailMaker {
    private let log = Logger(subsystem: "app.ringomate", category: "thumbnail")
    private let library: String?
    private var queue: [String] = []
    private var running = false
    private var renderer: Renderer?
    private let status: LoadStatus

    init(library: String?, status: LoadStatus) {
        self.library = library
        self.status = status
    }

    func request(_ path: String) {
        guard ModelThumbnails.image(for: path) == nil, !queue.contains(path), FileManager.default.fileExists(atPath: path) else { return }
        queue.append(path)
        status.thumbnailsLeft += 1
        guard !running else { return }
        running = true
        Task { [weak self] in
            while let self, !self.queue.isEmpty {
                let next = self.queue.removeFirst()
                await self.make(next)
                self.status.thumbnailsLeft = self.queue.count
                try? await Task.sleep(for: .milliseconds(300))
            }
            self?.renderer = nil
            self?.running = false
        }
    }

    private func make(_ path: String) async {
        let core = Core()
        let library = self.library
        let t0 = Date()
        let result = await Task.detached(priority: .utility) {
            Result { try core.prepare(model: path, library: library) }
        }.value
        do {
            let data = try result.get()
            core.commitLoad()
            if renderer == nil { renderer = try Renderer() }
            guard let renderer else { return }
            _ = try renderer.load(MeshInput(data, core: core))
            core.setStage(width: 50, ground: 2)
            let height = renderer.modelHeight ?? 20
            let size = CGSize(width: 200, height: 260)
            let ppu = Float(230) / height
            let placement = Placement(anchor: SIMD2(100, 15) - SIMD2(48, 2) * ppu, pointsPerUnit: ppu)
            var input = Core.Input()
            input.facing = 0.35
            var image: CGImage?
            var head: SIMD2<Float>?
            let scale = 4
            for i in 0..<45 {
                let shot = renderer.snapshot(size: size, scale: i == 44 ? scale : 1, placement: placement) { skin, positions in
                    head = core.step(dt: 1.0 / 30.0, input: input, skin: skin, positions: positions).head
                }
                if i == 44 { image = shot }
            }
            guard let image else { return }
            // ponytail: 頭の大きさを身長の 2 割、顔の中心を頭のボーンの少し上と決め打ち。ちびキャラでずれたら頭のメッシュの範囲から取る
            let face = head.map { h -> CGRect in
                let side = CGFloat(height * ppu * 0.22)
                let p = placement.anchor + h * ppu
                return CGRect(x: CGFloat(p.x) - side / 2, y: size.height - CGFloat(p.y) - side * 0.7, width: side, height: side)
                    .applying(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
            }
            ModelThumbnails.save(image, for: path, face: face)
            log.info("thumbnail \(URL(filePath: path).lastPathComponent, privacy: .private) \(Int(Date().timeIntervalSince(t0) * 1000))ms")
        } catch {
            log.error("thumbnail failed \(path, privacy: .private): \(error, privacy: .private)")
        }
    }
}
