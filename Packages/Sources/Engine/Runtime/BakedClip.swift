import simd

/// 30fps に焼いたクリップ。
struct BakedClip: Sendable {
    public var name: String
    public var frames: [Frame]
    public var fps: Float
    /// 接地足が止まって見える前進速度（MMD 単位/s）。足踏みしないクリップは 0。
    var groundSpeed: Float
    var mapped: Int
    /// あれば `frames` は空で、再生はこちら。
    var vmd: VMDClip? = nil

    public struct Frame: Sendable {
        /// (ボーン, 親ローカル回転)
        var rotations: [(Int, simd_quatf)]
        public var center: (Int, SIMD3<Float>)?
        public var feet: [(Int, SIMD3<Float>)]
    }
}

enum BakeCache {
    static let magic = Array("AMBAKE01".utf8)

    static func encode(_ clips: [(Slot, BakedClip)]) -> [UInt8] {
        var w = ByteWriter()
        w.out = magic
        w.u32(UInt32(clips.count))
        func v3(_ v: SIMD3<Float>) { w.f32(v.x); w.f32(v.y); w.f32(v.z) }
        for (slot, c) in clips {
            w.u32(slot.code)
            let name = Array(c.name.utf8)
            w.u32(UInt32(name.count))
            w.out += name
            w.f32(c.fps)
            w.f32(c.groundSpeed)
            w.u32(UInt32(c.mapped))
            w.u32(UInt32(c.frames.count))
            for f in c.frames {
                w.u32(UInt32(f.rotations.count))
                for (b, q) in f.rotations {
                    w.u32(UInt32(b))
                    for x in [q.imag.x, q.imag.y, q.imag.z, q.real] { w.f32(x) }
                }
                if let (b, v) = f.center {
                    w.u32(1)
                    w.u32(UInt32(b))
                    v3(v)
                } else {
                    w.u32(0)
                }
                w.u32(UInt32(f.feet.count))
                for (b, v) in f.feet {
                    w.u32(UInt32(b))
                    v3(v)
                }
            }
        }
        return w.out
    }

    static func decode(_ bytes: [UInt8]) -> [(Slot, BakedClip)]? {
        var r = ByteReader(bytes)
        func count(_ minBytes: Int) throws -> Int {
            let n = Int(try r.u32())
            guard n * minBytes <= r.remaining else { throw FormatError.sectionOverflow }
            return n
        }
        do {
            guard Array(try r.bytes(8)) == magic else { return nil }
            var out: [(Slot, BakedClip)] = []
            for _ in 0..<(try count(4)) {
                guard let slot = Slot(code: try r.u32()) else { return nil }
                let name = String(decoding: try r.bytes(try count(1)), as: UTF8.self)
                let fps = try r.f32(), ground = try r.f32(), mapped = Int(try r.u32())
                var frames: [BakedClip.Frame] = []
                for _ in 0..<(try count(12)) {
                    let rotations = try (0..<(try count(20))).map { _ in
                        (Int(try r.u32()), simd_quatf(ix: try r.f32(), iy: try r.f32(), iz: try r.f32(), r: try r.f32()))
                    }
                    let center: (Int, SIMD3<Float>)? = try r.u32() == 1 ? (Int(try r.u32()), try r.vec3()) : nil
                    let feet = try (0..<(try count(16))).map { _ in (Int(try r.u32()), try r.vec3()) }
                    frames.append(BakedClip.Frame(rotations: rotations, center: center, feet: feet))
                }
                out.append((slot, BakedClip(name: name, frames: frames, fps: fps, groundSpeed: ground, mapped: mapped)))
            }
            return r.remaining == 0 ? out : nil
        } catch {
            return nil
        }
    }
}
