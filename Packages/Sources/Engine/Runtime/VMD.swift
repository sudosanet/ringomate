import Foundation
import simd

/// mmd-anim-format・mmd-anim-runtime の移植。
struct VMDClip: Sendable {
    /// 制御点は 0〜127。
    struct Curve: Sendable {
        var x1: UInt8, y1: UInt8, x2: UInt8, y2: UInt8

        func evaluate(_ x: Float) -> Float {
            let x = min(max(x, 0), 1)
            if x <= 0 { return 0 }
            if x >= 1 { return 1 }
            if x1 == y1 && x2 == y2 { return x }
            let k: Float = 1 / 127
            return VMDClip.bezier(Float(x1) * k, Float(x2) * k, Float(y1) * k, Float(y2) * k, x)
        }
    }

    struct BoneTrack: Sendable {
        var bone: Int
        var frames: [UInt32], positions: [SIMD3<Float>], rotations: [simd_quatf]
        var positionCurves: [(Curve, Curve, Curve)], rotationCurves: [Curve]

        func sample(_ frame: Float) -> (SIMD3<Float>, simd_quatf) {
            if frames.count == 1 { return (positions[0], rotations[0]) }
            let next = VMDClip.nextKey(frames, frame)
            if next == 0 { return (positions[0], rotations[0]) }
            if next >= frames.count { return (positions[frames.count - 1], rotations[frames.count - 1]) }
            let prev = next - 1
            let (f0, f1) = (Float(frames[prev]), Float(frames[next]))
            let t = f1 == f0 ? 0 : min(max((frame - f0) / (f1 - f0), 0), 1)
            let (cx, cy, cz) = positionCurves[next]
            let (a, b) = (positions[prev], positions[next])
            let p = SIMD3(VMDClip.lerp(a.x, b.x, cx.evaluate(t)), VMDClip.lerp(a.y, b.y, cy.evaluate(t)), VMDClip.lerp(a.z, b.z, cz.evaluate(t)))
            return (p, Math.slerp(rotations[prev], rotations[next], rotationCurves[next].evaluate(t)))
        }
    }

    struct MorphTrack: Sendable {
        var morph: Int
        var frames: [UInt32], weights: [Float]

        func sample(_ frame: Float) -> Float {
            if frames.count == 1 { return weights[0] }
            let next = VMDClip.nextKey(frames, frame)
            if next == 0 { return weights[0] }
            if next >= frames.count { return weights[weights.count - 1] }
            let (f0, f1) = (Float(frames[next - 1]), Float(frames[next]))
            let t = f1 == f0 ? 0 : min(max((frame - f0) / (f1 - f0), 0), 1)
            return VMDClip.lerp(weights[next - 1], weights[next], t)
        }
    }

    var bones: [BoneTrack] = []
    var morphs: [MorphTrack] = []
    /// (フレーム, ソルバーごとの有効)
    var property: [(UInt32, [Bool])] = []
    var endFrame: Float = 0
    var hasMorphKeys = false
    var hasMouthKeys = false

    static let fps: Float = 30

    struct Invalid: Error, CustomStringConvertible { let description: String }

    public init(_ data: [UInt8], model: RuntimeModel, pmx: PMXModel) throws {
        var r = ByteReader(data)
        let magic = Array(try r.bytes(30))
        guard magic.starts(with: Array("Vocaloid Motion Data 0002\0".utf8)) else { throw Invalid(description: "not a VMD file") }
        try r.skip(20)
        // 改行より後は名前として使わない（MMD の読み込みと同じ）
        func name(_ field: ArraySlice<UInt8>, registration: Bool) -> String {
            var b = Array(field.prefix { $0 != 0 })
            if registration, let lf = b.firstIndex(of: 10) { b = Array(b[..<lf]) }
            return Self.sjis(b)
        }
        func lastIndex(_ names: [String]) -> [String: Int] {
            var m: [String: Int] = [:]
            for (i, n) in names.enumerated() { m[n] = i }
            return m
        }
        let boneIndex = lastIndex(model.boneNames)
        let morphIndex = lastIndex(pmx.morphs.map(\.name))
        var ikIndex: [String: Int] = [:]
        for (k, s) in model.ikSolvers.enumerated() { ikIndex[model.boneNames[s.ikBone]] = k }

        typealias Key = (frame: UInt32, pos: SIMD3<Float>, rot: simd_quatf, curves: (Curve, Curve, Curve), rcurve: Curve)
        var boneKeys: [Int: [Key]] = [:]
        let boneCount = Int(try r.u32())
        try r.require(boneCount * 111)
        for _ in 0..<boneCount {
            let field = try r.bytes(15)
            let frame = try r.u32()
            let pos = try r.vec3()
            let q = try r.vec4()
            let ip = Array(try r.bytes(64))
            guard let b = boneIndex[name(field, registration: true)] else { continue }
            func curve(_ o: Int) -> Curve {
                Curve(x1: min(ip[o], 127), y1: min(ip[o + 4], 127), x2: min(ip[o + 8], 127), y2: min(ip[o + 12], 127))
            }
            var rot = simd_quatf(ix: q.x, iy: q.y, iz: q.z, r: q.w)
            if let axis = model.fixedAxis[b] {
                let a = simd_normalize(axis)
                let v = SIMD3(rot.imag.x, rot.imag.y, rot.imag.z)
                let p = a * simd_length(v) * (simd_dot(v, a) < 0 ? -1 : 1)
                rot = simd_quatf(ix: p.x, iy: p.y, iz: p.z, r: rot.real)
            }
            boneKeys[b, default: []].append((frame, pos, rot, (curve(0), curve(16), curve(32)), curve(48)))
        }
        var end: UInt32 = 0
        for b in boneKeys.keys.sorted() {
            let keys = Self.lastPerFrame(boneKeys[b]!, \.frame)
            let rots = keys.map { k -> simd_quatf in
                let l2 = simd_dot(k.rot.vector, k.rot.vector)
                return abs(l2 - 1) <= 2e-4 ? k.rot : simd_normalize(k.rot)
            }
            bones.append(BoneTrack(bone: b, frames: keys.map(\.frame), positions: keys.map(\.pos), rotations: rots,
                                   positionCurves: keys.map(\.curves), rotationCurves: keys.map(\.rcurve)))
            end = max(end, keys.last!.frame)
        }

        guard r.remaining > 0 else { endFrame = Float(end); return }
        let morphStart = r.pos
        let morphCount = Int(try r.u32())
        try r.require(morphCount * 23)
        var morphKeys: [Int: [(frame: UInt32, weight: Float)]] = [:]
        for _ in 0..<morphCount {
            let field = try r.bytes(15)
            let frame = try r.u32(), w = try r.f32()
            if let m = morphIndex[name(field, registration: true)] { morphKeys[m, default: []].append((frame, w)) }
        }
        for m in morphKeys.keys.sorted() {
            let keys = Self.lastPerFrame(morphKeys[m]!, \.frame)
            morphs.append(MorphTrack(morph: m, frames: keys.map(\.frame), weights: keys.map(\.weight)))
            end = max(end, keys.last!.frame)
        }
        hasMorphKeys = morphCount > 0
        hasMouthKeys = Self.mouthKeys(data, start: morphStart)

        for size in [61, 28, 9] {
            guard r.remaining > 0 else { endFrame = Float(end); return }
            let n = Int(try r.u32())
            try r.skip(n * size)
        }
        guard r.remaining > 0 else { endFrame = Float(end); return }
        let propCount = Int(try r.u32())
        try r.require(propCount * 9)
        var frames: [(UInt32, [Bool])] = []
        for _ in 0..<propCount {
            let frame = try r.u32()
            _ = try r.u8()
            let n = Int(try r.u32())
            try r.require(n * 21)
            var enabled = [Bool](repeating: true, count: model.ikSolvers.count)
            for _ in 0..<n {
                let field = try r.bytes(20)
                let on = try r.u8()
                if let k = ikIndex[name(field, registration: false)] { enabled[k] = on != 0 }
            }
            frames.append((frame, enabled))
        }
        if !model.ikSolvers.isEmpty && !frames.isEmpty {
            property = frames.enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }.map(\.element)
            end = max(end, property.last!.0)
        }
        endFrame = Float(end)
    }

    static func sjis(_ b: [UInt8]) -> String {
        if b.allSatisfy({ $0 < 0x80 }) { return String(decoding: b, as: UTF8.self) }
        return decode(b, .shiftJIS).text
    }

    static func lastPerFrame<T>(_ keys: [T], _ frame: KeyPath<T, UInt32>) -> [T] {
        var last: [UInt32: T] = [:]
        for k in keys { last[k[keyPath: frame]] = k }
        return last.keys.sorted().map { last[$0]! }
    }

    static func mouthKeys(_ vmd: [UInt8], start: Int) -> Bool {
        func u32(_ o: Int) -> Int? { o + 4 <= vmd.count ? Int(le32(vmd, o)) : nil }
        guard let count = u32(start) else { return false }
        let mouth: [[UInt8]] = [[0x82, 0xA0], [0x82, 0xA2], [0x82, 0xA4], [0x82, 0xA6], [0x82, 0xA8]]
        var keys = 0, last = 0
        for k in 0..<count {
            let o = start + 4 + 23 * k
            guard o + 15 <= vmd.count else { break }
            last = max(last, u32(o + 15) ?? 0)
            if vmd[o + 2] == 0 && mouth.contains(where: { $0[0] == vmd[o] && $0[1] == vmd[o + 1] }) { keys += 1 }
        }
        return keys >= 4 && Float(keys) >= Float(last) / 30 * 0.5
    }

    public var duration: Float { endFrame / Self.fps }

    func apply(_ t: Float, _ pose: inout Pose) { apply(frame: t * Self.fps, &pose) }

    func apply(frame: Float, _ pose: inout Pose) {
        pose.resetLocal()
        for tr in bones {
            let (p, q) = tr.sample(frame)
            pose.localOffsets[tr.bone] = p
            pose.localRotations[tr.bone] = q
        }
        for tr in morphs where tr.morph < pose.morphWeights.count { pose.morphWeights[tr.morph] = tr.sample(frame) }
        let next = property.partitionPoint { Float($0.0) <= frame }
        if next > 0 {
            for (k, on) in property[next - 1].1.enumerated() where k < pose.ikEnabled.count { pose.ikEnabled[k] = on }
        }
    }

    static func nextKey(_ frames: [UInt32], _ frame: Float) -> Int { frames.partitionPoint { Float($0) <= frame } }

    static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }

    static func bezier(_ x1: Float, _ x2: Float, _ y1: Float, _ y2: Float, _ x: Float) -> Float {
        var c: Float = 0.5, t: Float = 0.5, s: Float = 0.5
        for _ in 0..<12 {
            let sst3 = 3 * s * s * t, stt3 = 3 * s * t * t, ttt = t * t * t
            let ft = sst3 * x1 + stt3 * x2 + ttt - x
            if ft == 0 { return sst3 * y1 + stt3 * y2 + ttt }
            c *= 0.5
            t += ft < 0 ? c : -c
            s = 1 - t
        }
        return 3 * s * s * t * y1 + 3 * s * t * t * y2 + t * t * t
    }
}

extension Puppet {
    /// いま再生中のスロットなら、いまの姿勢からフェードして頭から始め直す。
    func setVMD(_ slot: Slot, _ data: [UInt8]) throws { setVMD(slot, try makeVMD(data)) }

    /// 状態を変えないので、ロックの外で呼べる。
    func makeVMD(_ data: [UInt8]) throws -> VMDClip { try VMDClip(data, model: runtime, pmx: model.pmx) }

    func setVMD(_ slot: Slot, _ clip: VMDClip) {
        motions[slot] = BakedClip(name: "vmd", frames: [], fps: VMDClip.fps, groundSpeed: 0, mapped: clip.bones.count, vmd: clip)
        if clip.hasMorphKeys { faceSlots.insert(slot) } else { faceSlots.remove(slot) }
        if clip.hasMouthKeys { mouthSlots.insert(slot) } else { mouthSlots.remove(slot) }
        if slot == player.current {
            player.restart()
            eval.resetIKHistory()
        }
    }
}
