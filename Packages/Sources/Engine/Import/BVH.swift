import Compression
import simd

public enum BVH {
    static let names: [String: String] = [
        "Hips": "pelvis", "Spine": "spine_01", "Chest": "spine_03", "Neck": "neck_01", "Head": "Head",
        "Shoulder_L": "clavicle_l", "UpperArm_L": "upperarm_l", "LowerArm_L": "lowerarm_l", "Hand_L": "hand_l",
        "Shoulder_R": "clavicle_r", "UpperArm_R": "upperarm_r", "LowerArm_R": "lowerarm_r", "Hand_R": "hand_r",
        "UpperLeg_L": "thigh_l", "LowerLeg_L": "calf_l", "Foot_L": "foot_l", "Toes_L": "ball_l",
        "UpperLeg_R": "thigh_r", "LowerLeg_R": "calf_r", "Foot_R": "foot_r", "Toes_R": "ball_r",
        "Spine1": "spine_03", "Spine2": "spine_03", "LeftShoulder": "clavicle_l", "LeftArm": "upperarm_l",
        "LeftForeArm": "lowerarm_l", "LeftHand": "hand_l", "RightShoulder": "clavicle_r", "RightArm": "upperarm_r",
        "RightForeArm": "lowerarm_r", "RightHand": "hand_r", "LeftUpLeg": "thigh_l", "LeftLeg": "calf_l",
        "LeftFoot": "foot_l", "LeftToeBase": "ball_l", "RightUpLeg": "thigh_r", "RightLeg": "calf_r",
        "RightFoot": "foot_r", "RightToeBase": "ball_r",
        "mixamorig:Hips": "pelvis", "mixamorig:Spine": "spine_01", "mixamorig:Spine2": "spine_03",
        "mixamorig:Neck": "neck_01", "mixamorig:Head": "Head", "mixamorig:LeftShoulder": "clavicle_l",
        "mixamorig:LeftArm": "upperarm_l", "mixamorig:LeftForeArm": "lowerarm_l", "mixamorig:LeftHand": "hand_l",
        "mixamorig:RightShoulder": "clavicle_r", "mixamorig:RightArm": "upperarm_r",
        "mixamorig:RightForeArm": "lowerarm_r", "mixamorig:RightHand": "hand_r", "mixamorig:LeftUpLeg": "thigh_l",
        "mixamorig:LeftLeg": "calf_l", "mixamorig:LeftFoot": "foot_l", "mixamorig:LeftToeBase": "ball_l",
        "mixamorig:RightUpLeg": "thigh_r", "mixamorig:RightLeg": "calf_r", "mixamorig:RightFoot": "foot_r",
        "mixamorig:RightToeBase": "ball_r",
    ]

    struct Invalid: Error, CustomStringConvertible {
        public let description: String
    }

    public typealias Local = (SIMD3<Float>, simd_quatf)

    public struct RawMotion: Sendable {
        public var names: [String]
        var parents: [Int?]
        var offsets: [SIMD3<Float>]
        public var fps: Float
        public var poses: [[Local]]
    }

    static func rot(_ axis: Int, _ a: Float) -> simd_quatf {
        let (s, c) = (sin(a / 2), cos(a / 2))
        return axis == 0 ? simd_quatf(ix: s, iy: 0, iz: 0, r: c) : axis == 1 ? simd_quatf(ix: 0, iy: s, iz: 0, r: c)
            : simd_quatf(ix: 0, iy: 0, iz: s, r: c)
    }

    public static func parse(_ text: String) throws -> RawMotion {
        var names: [String] = [], parents: [Int?] = [], offsets: [SIMD3<Float>] = []
        var channelStart: [Int] = [], layouts: [[String]] = []
        var stack: [Int?] = []
        var pending: Int?
        var channels = 0
        var bytes = Array(text.utf8)
        bytes.append(0)  // strtof の番兵
        let isSpace: (UInt8) -> Bool = { $0 == 32 || ($0 >= 9 && $0 <= 13) }
        var lines: [Range<Int>] = []
        var a = 0
        for i in 0..<(bytes.count - 1) where bytes[i] == 10 {
            lines.append(a..<(i > a && bytes[i - 1] == 13 ? i - 1 : i))
            a = i + 1
        }
        lines.append(a..<(bytes.count - 1))
        func tokens(_ r: Range<Int>) -> [Range<Int>] {
            var out: [Range<Int>] = []
            var i = r.lowerBound
            while i < r.upperBound {
                while i < r.upperBound, isSpace(bytes[i]) { i += 1 }
                let b = i
                while i < r.upperBound, !isSpace(bytes[i]) { i += 1 }
                if i > b { out.append(b..<i) }
            }
            return out
        }
        func string(_ r: Range<Int>) -> String { String(decoding: bytes[r], as: UTF8.self) }
        var k = 0
        scan: while k < lines.count {
            let t = tokens(lines[k]).map(string)
            k += 1
            switch t.first {
            case "ROOT", "JOINT":
                guard t.count > 1 else { throw Invalid(description: "joint name") }
                names.append(t[1])
                parents.append(stack.last ?? nil)
                offsets.append(.zero)
                pending = names.count - 1
            case "OFFSET":
                // End Site の OFFSET は関節ではない
                if let j = (stack.last ?? nil) ?? pending, t.count >= 4, let x = Float(t[1]), let y = Float(t[2]), let z = Float(t[3]),
                   j < offsets.count, offsets[j] == .zero, channelStart.count == j {
                    offsets[j] = SIMD3(x, y, z)
                }
            case "End": pending = nil
            case "{":
                stack.append(pending)
                pending = nil
            case "}": _ = stack.popLast()
            case "CHANNELS":
                guard t.count > 1, let n = Int(t[1]) else { throw Invalid(description: "channels") }
                let order = Array(t.dropFirst(2))
                guard order.count == n, n == 3 || n == 6 else { throw Invalid(description: "channels must be 3 or 6") }
                channelStart.append(channels)
                layouts.append(order)
                channels += n
            case "MOTION": break scan
            default: break
            }
        }
        var fps: Float = 30
        var frames: [[Float]] = []
        let frameTime = Array("Frame Time:".utf8), framesTag = Array("Frames:".utf8)
        try bytes.withUnsafeBufferPointer { buf in
            let base = UnsafeMutableRawPointer(mutating: buf.baseAddress!).assumingMemoryBound(to: CChar.self)
            func number(_ r: Range<Int>) -> Float? {
                var end: UnsafeMutablePointer<CChar>?
                let v = strtof(base + r.lowerBound, &end)
                return end == base + r.upperBound ? v : nil
            }
            for line in lines[min(k, lines.count)...] {
                if buf[line].starts(with: frameTime) {
                    let t = tokens(line.lowerBound + frameTime.count..<line.upperBound)
                    guard t.count == 1, let v = number(t[0]), v.isFinite, v > 1e-4, v < 10 else { throw Invalid(description: "frame time") }
                    fps = 1 / v
                } else if !buf[line].starts(with: framesTag) {
                    let t = tokens(line)
                    if t.isEmpty { continue }
                    let f = t.compactMap(number)
                    if f.count == channels { frames.append(f) }
                }
            }
        }
        guard names.count == channelStart.count, !frames.isEmpty else { throw Invalid(description: "joints, channels and frames") }
        let poses = frames.map { f in
            zip(zip(channelStart, layouts), offsets).map { pair, offset -> Local in
                let (c, layout) = pair
                var pos = offset
                var r = Math.identity
                // 回転は書かれた順に掛ける（Z X Y なら Rz * Rx * Ry）
                for (k, ch) in layout.enumerated() {
                    let raw = f[c + k]
                    let v: Float = raw.isFinite && abs(raw) < 1e6 ? raw : 0
                    switch ch {
                    case "Xposition": pos.x = v
                    case "Yposition": pos.y = v
                    case "Zposition": pos.z = v
                    case "Xrotation": r = Math.mul(r, rot(0, Math.radians(v)))
                    case "Yrotation": r = Math.mul(r, rot(1, Math.radians(v)))
                    case "Zrotation": r = Math.mul(r, rot(2, Math.radians(v)))
                    default: break
                    }
                }
                return (pos, simd_normalize(r))
            }
        }
        return RawMotion(names: names, parents: parents, offsets: offsets, fps: fps, poses: poses)
    }

    static func skeleton(_ p: RawMotion, _ bind: [Local]) -> SourceSkeleton {
        SourceSkeleton(names: p.names.map { names[$0] ?? $0 }, parents: p.parents, bind: bind)
    }

    static func reorient(_ h: Int, _ frames: inout [[Local]], _ yaw: simd_quatf, _ drift: (Int) -> SIMD3<Float>) {
        for k in frames.indices {
            frames[k][h].0 = Math.rotate(yaw, frames[k][h].0) - drift(k)
            frames[k][h].1 = Math.mul(yaw, frames[k][h].1)
        }
    }

    static func worldPositions(_ p: RawMotion, _ l: [Local]) -> [SIMD3<Float>] {
        var m = [simd_float4x4](repeating: matrix_identity_float4x4, count: l.count)
        for j in l.indices {
            let local = Math.matrix(l[j].1, l[j].0)
            m[j] = p.parents[j].map { Math.mul(m[$0], local) } ?? local
        }
        return m.map(\.columns.3.xyz)
    }

    static func facing(_ p: RawMotion, _ l: [Local]) -> SIMD3<Float> {
        let w = worldPositions(p, l)
        func at(_ n: String) -> SIMD3<Float>? { p.names.firstIndex(of: n).map { w[$0] } }
        guard let a = at("UpperLeg_L") ?? at("LeftUpLeg"), let b = at("UpperLeg_R") ?? at("RightUpLeg") else { return SIMD3(0, 0, 1) }
        return Math.normalize(simd_cross(a - b, SIMD3(0, 1, 0)), or: SIMD3(0, 0, 1))
    }

    static func yawToFront(_ f: SIMD3<Float>) -> simd_quatf {
        Math.rotationArc(Math.normalize(SIMD3(f.x, 0, f.z), or: SIMD3(0, 0, 1)), SIMD3(0, 0, 1))
    }

    static func hips(_ p: RawMotion) throws -> Int {
        guard let h = p.names.firstIndex(of: "Hips") else { throw Invalid(description: "no Hips") }
        return h
    }

    static func loadClip(_ text: String, name: String) throws -> (SourceSkeleton, SourceClip) {
        let p = try parse(text)
        let h = try hips(p)
        var frames = p.poses
        let yaw = yawToFront(facing(p, frames[0]))
        let start = frames[0][h].0
        reorient(h, &frames, yaw) { _ in Math.rotate(yaw, SIMD3(start.x, 0, start.z)) }
        return (skeleton(p, frames[0]), SourceClip(name: name, fps: p.fps, frames: frames))
    }

    /// `front` は Y 回りの度。nil なら全部のフレームの腰の向きの平均。
    static func clipRest(_ p: RawMotion, name: String, front: Float?) throws -> (SourceSkeleton, SourceClip) {
        let h = try hips(p)
        var frames = p.poses
        var mean = SIMD3<Float>.zero
        for k in stride(from: 0, to: frames.count, by: 5) {
            let v = facing(p, frames[k])
            mean += Math.normalizeOrZero(SIMD3(v.x, 0, v.z))
        }
        let forward: SIMD3<Float>
        if let deg = front {
            forward = Math.rotate(rot(1, Math.radians(deg)), SIMD3(0, 0, 1))
        } else if simd_length(mean) > 0.2 * Float(max(frames.count / 5, 1)) {
            forward = mean
        } else {
            forward = facing(p, frames[0])
        }
        let yaw = yawToFront(forward)
        let start = frames[0][h].0
        reorient(h, &frames, yaw) { _ in Math.rotate(yaw, SIMD3(start.x, 0, start.z)) }
        var rest: [Local] = p.offsets.map { ($0, Math.identity) }
        rest[h].0 = .zero
        let low = worldPositions(p, rest).reduce(Float(0)) { min($0, $1.y) }
        rest[h].0 = SIMD3(0, -low, 0)
        return (skeleton(p, rest), SourceClip(name: name, fps: p.fps, frames: frames))
    }

    enum Trim: Sendable {
        case handsUp
        case bow
        case active
    }

    static func loadGesture(_ text: String, name: String, trim: Trim, maxSeconds: Float) throws -> (SourceSkeleton, SourceClip) {
        let p = try parse(text)
        let (skel, full) = try loadClip(text, name: name)
        func at(_ n: String) -> Int? { p.names.firstIndex(of: n) }
        guard let chest = at("Chest"), let neck = at("Neck"), let l = at("Hand_L"), let r = at("Hand_R") else {
            throw Invalid(description: "no Chest, Neck or hands")
        }
        let h = try hips(p)
        let world = p.poses.map { worldPositions(p, $0) }
        func rel(_ k: Int, _ j: Int) -> SIMD3<Float> { world[k][j] - world[k][h] }
        let cos20 = cos(Math.radians(20))
        let active: [Bool] = world.indices.map { k in
            let w = world[k]
            switch trim {
            case .handsUp: return w[l].y > w[chest].y || w[r].y > w[chest].y
            case .bow: return Math.normalizeOrZero(w[neck] - w[chest]).y < cos20
            case .active: return [l, r].contains { simd_distance(rel(k, $0), rel(0, $0)) > 15 }
            }
        }
        guard let first = active.firstIndex(of: true), let last = active.lastIndex(of: true) else {
            throw Invalid(description: "no \(trim) section")
        }
        let margin = Int(0.5 * p.fps)
        let a = max(first - margin, 0)
        let b = min(last + margin, p.poses.count - 1, a + Int(maxSeconds * p.fps))
        let frames = (a...b).map { full.sample(skel, Float($0) / p.fps) }
        return (skel, SourceClip(name: name, fps: p.fps, frames: frames))
    }

    static func loadActiveSection(_ text: String, name: String, maxSeconds: Float) throws -> (SourceSkeleton, SourceClip) {
        let p = try parse(text)
        let h = try hips(p)
        func at(_ a: String, _ b: String) -> Int? { p.names.firstIndex { $0 == a || $0 == b } }
        guard let l = at("LeftHand", "Hand_L"), let r = at("RightHand", "Hand_R"), let head = at("Head", "Head") else {
            throw Invalid(description: "no hands or head")
        }
        guard p.poses.count >= 3 else { throw Invalid(description: "too short") }
        var frames = p.poses
        var bind = frames[0]
        bind[h].0 = SIMD3(0, bind[h].0.y, 0)
        let world = frames.map { worldPositions(p, $0) }
        let leg = world[0][h].y - world[0].reduce(Float.greatestFiniteMagnitude) { min($0, $1.y) }
        func flat(_ v: SIMD3<Float>) -> SIMD3<Float> { SIMD3(v.x, 0, v.z) }
        let moving: [Float] = (1..<world.count).map { k in
            if k == 1 { return 0 }
            return [l, r, head].reduce(Float(0)) { s, j in
                s + simd_length((world[k][j] - world[k][h]) - (world[k - 1][j] - world[k - 1][h]))
            }
        }
        let win = min(max(Int(maxSeconds * p.fps), 1), moving.count)
        var best = (0, -Float.greatestFiniteMagnitude)
        for a in 0...(moving.count - win) {
            let start = flat(world[a + 1][h])
            let travel = (a + 1..<a + 1 + win).reduce(Float(0)) { max($0, simd_distance(flat(world[$1][h]), start)) }
            let score = moving[a..<a + win].reduce(0, +) * (travel > leg * 0.5 ? 0.2 : 1)
            if score > best.1 { best = (a, score) }
        }
        let (a, b) = (best.0 + 1, best.0 + win)
        let yaw = yawToFront(facing(p, frames[a]))
        let start = frames[a][h].0
        reorient(h, &frames, yaw) { _ in Math.rotate(yaw, SIMD3(start.x, 0, start.z)) }
        return (skeleton(p, bind), SourceClip(name: name, fps: p.fps, frames: Array(frames[a...b])))
    }

    static func loadWalkCycle(_ text: String, name: String) throws -> (SourceSkeleton, SourceClip) {
        let p = try parse(text)
        let h = try hips(p)
        let all = p.poses
        let n = all.count
        let legs = ["UpperLeg_L", "LowerLeg_L", "UpperLeg_R", "LowerLeg_R", "Hips"].compactMap { p.names.firstIndex(of: $0) }
        let feet = ["Foot_L", "Foot_R"].compactMap { p.names.firstIndex(of: $0) }
        let rel: [[SIMD3<Float>]] = all.map { f in
            let w = worldPositions(p, f)
            return feet.map { w[$0] - w[h] }
        }
        func diff(_ a: Int, _ b: Int) -> Float {
            let r = legs.reduce(Float(0)) { s, j in
                let (qa, qb) = (all[a][j].1, all[b][j].1)
                return s + (1 - abs(simd_dot(qa.vector, qb.vector)))
            }
            let d = zip(rel[a], rel[b]).reduce(Float(0)) { $0 + simd_distance($1.0, $1.1) }
            return r + d * 0.002
        }
        let (lo, hi) = (Int(0.7 * p.fps), Int(1.6 * p.fps))
        var best: (Float, Int, Int) = (.greatestFiniteMagnitude, 0, 0)
        for a in (n / 3)..<(n * 2 / 3) {
            for b in (a + lo)..<max(min(a + hi, n), a + lo) {
                let d = diff(a, b)
                if d < best.0 { best = (d, a, b) }
            }
        }
        let (_, a, b) = best
        guard b > a else { throw Invalid(description: "no walk cycle") }
        var frames = Array(all[a...b])
        let (pa, pb) = (frames[0][h].0, frames[b - a][h].0)
        let step = SIMD3(pb.x - pa.x, 0, pb.z - pa.z)
        let yaw = Math.rotationArc(Math.normalize(step, or: SIMD3(0, 0, 1)), SIMD3(0, 0, 1))
        let len = Float(b - a)
        reorient(h, &frames, yaw) { k in Math.rotate(yaw, SIMD3(pa.x, 0, pa.z) + step * (Float(k) / len)) }
        var bind = all[0]
        let yaw0 = yawToFront(facing(p, bind))
        bind[h] = (SIMD3(0, bind[h].0.y, 0), Math.mul(yaw0, bind[h].1))
        var clip = SourceClip(name: name, fps: p.fps, frames: frames)
        clip.groundSpeed = simd_length(step) / (len / p.fps)
        return (skeleton(p, bind), clip)
    }

    public static func gunzipIfNeeded(_ bytes: [UInt8]) throws -> [UInt8] {
        guard bytes.count > 18, bytes[0] == 0x1f, bytes[1] == 0x8b else { return bytes }
        let flags = bytes[3]
        var p = 10
        if flags & 4 != 0 { p += 2 + Int(le16(bytes, p)) }
        if flags & 8 != 0 { while p < bytes.count, bytes[p] != 0 { p += 1 }; p += 1 }
        if flags & 16 != 0 { while p < bytes.count, bytes[p] != 0 { p += 1 }; p += 1 }
        if flags & 2 != 0 { p += 2 }
        let size = Int(le32(bytes, bytes.count - 4))
        // ponytail: 展開後 1 GiB まで
        guard p <= bytes.count - 8, size <= 1 << 30 else { throw Invalid(description: "gzip") }
        var out = [UInt8](repeating: 0, count: max(size, 1))
        let body = Array(bytes[p..<bytes.count - 8])
        let n = out.withUnsafeMutableBufferPointer { d in
            body.withUnsafeBufferPointer { s in compression_decode_buffer(d.baseAddress!, d.count, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB) }
        }
        guard n == size else { throw Invalid(description: "gzip") }
        return Array(out[0..<n])
    }
}
