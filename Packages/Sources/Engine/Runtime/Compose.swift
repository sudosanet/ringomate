import Foundation
import simd

/// 端末内のモデルが作ったキーフレーム（意味の名前・角度・秒）を検証して 30fps の `BakedClip` に焼く。
enum Compose {
    /// (意味の名前, ボーン, 回転の軸, 可動域（度）)
    public static let moves: [(String, String, SIMD3<Float>, Float)] = [
        ("raise_left_arm", "左腕", SIMD3(0, 0, 1), 90), ("lower_left_arm", "左腕", SIMD3(0, 0, -1), 90),
        ("raise_right_arm", "右腕", SIMD3(0, 0, -1), 90), ("lower_right_arm", "右腕", SIMD3(0, 0, 1), 90),
        ("left_arm_forward", "左腕", SIMD3(0.6, 0.8, 0), 90), ("left_arm_back", "左腕", SIMD3(-0.6, -0.8, 0), 90),
        ("right_arm_forward", "右腕", SIMD3(0.6, -0.8, 0), 90), ("right_arm_back", "右腕", SIMD3(-0.6, 0.8, 0), 90),
        ("bend_left_elbow", "左ひじ", SIMD3(0.6, 0.8, 0), 180), ("bend_right_elbow", "右ひじ", SIMD3(0.6, -0.8, 0), 180),
        ("nod", "頭", SIMD3(-1, 0, 0), 60), ("look_up", "頭", SIMD3(1, 0, 0), 90),
        ("look_left", "頭", SIMD3(0, -1, 0), 90), ("look_right", "頭", SIMD3(0, 1, 0), 90),
        ("tilt_head_left", "頭", SIMD3(0, 0, -1), 60), ("tilt_head_right", "頭", SIMD3(0, 0, 1), 60),
        ("lean_forward", "上半身", SIMD3(-1, 0, 0), 90), ("lean_back", "上半身", SIMD3(1, 0, 0), 90),
        ("twist_left", "上半身", SIMD3(0, -1, 0), 90), ("twist_right", "上半身", SIMD3(0, 1, 0), 90),
        ("sway_hips_left", "腰", SIMD3(0, 0, -1), 90), ("sway_hips_right", "腰", SIMD3(0, 0, 1), 90),
    ]

    struct Command: Sendable { public var name: String, degrees: Float }
    public struct Keyframe: Sendable { public var seconds: Float, commands: [Command] }

    static let returnSeconds: Float = 0.6

    public static func keyframes(json: String) throws -> [Keyframe] {
        let any = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return (any as? [[String: Any]] ?? []).map { k in
            Keyframe(seconds: (k["seconds"] as? NSNumber)?.floatValue ?? 0.5,
                     commands: (k["commands"] as? [[String: Any]] ?? []).map {
                         Command(name: $0["move"] as? String ?? "", degrees: ($0["degrees"] as? NSNumber)?.floatValue ?? 0)
                     })
        }
    }

    static func sample(_ keys: [(Float, simd_quatf)], _ t: Float) -> simd_quatf {
        let j = min(max(keys.partitionPoint { $0.0 <= t }, 1), keys.count - 1)
        let (a, qa) = keys[j - 1], (b, qb) = keys[j]
        let u = Math.clamp((t - a) / (b - a), 0, 1)
        return Math.slerp(qa, qb, u * u * (3 - 2 * u))
    }
}

extension Puppet {
    /// 使える動きが 1 つもなければ nil。
    func buildComposed(_ keyframes: [Compose.Keyframe]) -> BakedClip? {
        var tracks: [(Int, [(Float, simd_quatf)])] = []
        var t: Float = 0
        for k in keyframes.prefix(8) {
            t += Math.clamp(k.seconds, 0.2, 3)
            var pose: [(Int, simd_quatf)] = []
            for c in k.commands {
                guard let (_, bone, axis, limit) = Compose.moves.first(where: { $0.0 == c.name }),
                      c.degrees.isFinite, let bi = b(bone) else { continue }
                let angle = Math.radians(Math.clamp(c.degrees, 0, limit))
                let q = Math.axisAngle(simd_normalize(axis), angle)
                if let i = pose.firstIndex(where: { $0.0 == bi }) { pose[i].1 = Math.mul(pose[i].1, q) } else { pose.append((bi, q)) }
            }
            for (bi, q) in pose {
                if let i = tracks.firstIndex(where: { $0.0 == bi }) {
                    tracks[i].1.append((t, q))
                } else {
                    tracks.append((bi, [(0, Math.identity), (t, q)]))
                }
            }
        }
        if tracks.isEmpty { return nil }
        let end = t + Compose.returnSeconds
        for i in tracks.indices { tracks[i].1.append((end, Math.identity)) }
        let fps: Float = 30
        let frames = (0...Int((end * fps - 1e-3).rounded(.up))).map { i in
            BakedClip.Frame(rotations: tracks.map { ($0.0, Compose.sample($0.1, min(Float(i) / fps, end))) }, center: nil, feet: [])
        }
        return BakedClip(name: "composed", frames: frames, fps: fps, groundSpeed: 0, mapped: tracks.count)
    }
}
