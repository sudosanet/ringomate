import simd

extension Puppet {
    /// 縁に座って左右交互にひざを振る。
    func buildSitSwing() -> BakedClip? {
        guard var clip = motions[.sit], let lk = b("左ひざ"), let rk = b("右ひざ") else { return nil }
        let knees = [lk, rk]
        let legs = ["左足", "左ひざ", "左足首", "右足", "右ひざ", "右足首"].compactMap(b)
        for i in clip.frames.indices {
            eval(clip.frames[i])
            for bone in legs {
                let parent = Int(model.pmx.bones[bone].parentIndex)
                guard parent >= 0 else { continue }
                let local = simd_normalize(Math.mul(Math.inverse(Math.rotationOf(world(parent))), Math.rotationOf(world(bone))))
                if let k = clip.frames[i].rotations.firstIndex(where: { $0.0 == bone }) {
                    clip.frames[i].rotations[k].1 = local
                } else {
                    clip.frames[i].rotations.append((bone, local))
                }
            }
        }
        resetToIdle()
        let length = Float(clip.frames.count) / clip.fps
        let period = length / max((length / 1.4).rounded(.toNearestOrAwayFromZero), 1)
        for i in clip.frames.indices {
            let a = Float(i) / clip.fps / period * Math.tau
            for (k, knee) in knees.enumerated() {
                let swing = Math.rotX(0.35 * sin(a + Float(k) * Float.pi))
                if let r = clip.frames[i].rotations.firstIndex(where: { $0.0 == knee }) {
                    clip.frames[i].rotations[r].1 = Math.mul(swing, clip.frames[i].rotations[r].1)
                } else {
                    clip.frames[i].rotations.append((knee, swing))
                }
            }
        }
        clip.name += "-swing"
        return clip
    }

    /// 体育座り（止まった 2 フレーム、呼吸と揺れは手続きアニメが足す）。
    func buildHug() -> BakedClip? {
        let h = height
        let bones = model.pmx.bones
        func leg(_ n: String) -> Int? { bones.firstIndex { $0.name == n } }
        guard let center = leg("センター"), let thigh = leg("左足"), let knee = leg("左ひざ"), let ankle = leg("左足首") else { return nil }
        func p(_ i: Int) -> SIMD3<Float> { bones[i].position }
        let shin = simd_distance(p(knee), p(ankle))
        let thighLen = simd_distance(p(thigh), p(knee))
        let hipY = p(thigh).y
        let hipH = hipY * 0.12
        let up = Math.radians(35)
        let dropRatio = Math.clamp((hipH + thighLen * sin(up) - p(ankle).y) / shin, -1, 1)
        let beta = acos(dropRatio)
        let theta = Float.pi / 2 + up
        var frame = BakedClip.Frame(rotations: [], center: (center, SIMD3(0, -(hipY - hipH), 0)), feet: [])
        for side in ["左", "右"] {
            if let t = b("\(side)足"), let k = b("\(side)ひざ") {
                frame.rotations.append((t, Math.rotX(theta)))
                frame.rotations.append((k, Math.rotX(beta - theta)))
            }
        }
        for (n, a) in [("上半身", Float(0.35)), ("上半身2", 0.25), ("首", 0.2), ("頭", 0.35)] {
            if let bone = b(n) { frame.rotations.append((bone, Math.rotX(-a))) }
        }
        eval(frame)
        for (side, x) in [("左", Float(1)), ("右", -1)] {
            guard let k = b("\(side)ひざ") else { return nil }
            let kp = world(k).columns.3.xyz
            let target = kp + SIMD3(-x * h * 0.03, -h * 0.07, -h * 0.04)
            if let r = armIK(side, target, SIMD3(x, -0.5, 0)) { frame.rotations += r }
            frame.rotations += fingers(side, 0.6, 0.3)
        }
        eval(frame)
        let clip = BakedClip(name: "hug-knees", frames: [frame, frame], fps: 30, groundSpeed: 0, mapped: 0)
        resetToIdle()
        return clip
    }

    /// 位置、前（−Z）、横（+X）、上（+Y）。
    func chestFrame(_ chest: Int) -> (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        let m = world(chest)
        let rot = Math.rotationOf(m)
        return (m.columns.3.xyz, Math.rotate(rot, SIMD3(0, 0, -1)), Math.rotate(rot, SIMD3(1, 0, 0)), Math.rotate(rot, SIMD3(0, 1, 0)))
    }

    func buildClimb() -> BakedClip? {
        let h = height
        guard let chest = b("首") else { return nil }
        let n = 30
        var frames: [BakedClip.Frame] = []
        for i in 0...n {
            let phase = Float(i) / Float(n) * Math.tau
            var frame = BakedClip.Frame(rotations: [], center: nil, feet: [])
            for (name, a) in [("上半身", Float(-0.12)), ("頭", 0.3)] { if let bone = b(name) { frame.rotations.append((bone, Math.rotX(a))) } }
            for (side, k) in [("左", Float(0)), ("右", Float.pi)] {
                let lift = 0.3 + 0.9 * max(sin(phase + k), 0)
                if let t = b("\(side)足"), let kn = b("\(side)ひざ") {
                    frame.rotations.append((t, Math.rotX(lift)))
                    frame.rotations.append((kn, Math.rotX(-lift * 1.6)))
                }
            }
            eval(frame)
            let (pos, fwd, sideAxis, _) = chestFrame(chest)
            for (side, x, k) in [("左", Float(1), Float.pi), ("右", -1, 0)] {
                let reach = 0.5 + 0.5 * sin(phase + k)
                let target = pos + fwd * h * 0.13 + sideAxis * x * h * 0.08 + SIMD3(0, 1, 0) * h * (0.02 + 0.16 * reach)
                if let r = armIK(side, target, sideAxis * x - SIMD3(0, 1, 0) * 0.3) { frame.rotations += r }
                frame.rotations += fingers(side, 0.7, 0.4)
            }
            frames.append(frame)
        }
        resetToIdle()
        return BakedClip(name: "climb", frames: frames, fps: 30, groundSpeed: 0, mapped: 0)
    }

    func buildMantle() -> BakedClip? {
        let h = height
        guard let chest = b("首") else { return nil }
        let n = 24
        var frames: [BakedClip.Frame] = []
        for i in 0...n {
            let u = Float(i) / Float(n)
            let hump = sin(u * Float.pi)
            let ease = u * u * (3 - 2 * u)
            var frame = BakedClip.Frame(rotations: [], center: nil, feet: [])
            for (name, a) in [("上半身", -0.12 - 0.45 * hump), ("頭", 0.3 * (1 - ease) + 0.2 * hump)] {
                if let bone = b(name) { frame.rotations.append((bone, Math.rotX(a))) }
            }
            for (side, lift) in [("右", 0.3 + 1.1 * hump - 0.3 * ease), ("左", 0.3 * (1 - ease))] {
                if let t = b("\(side)足"), let kn = b("\(side)ひざ") {
                    frame.rotations.append((t, Math.rotX(lift)))
                    frame.rotations.append((kn, Math.rotX(-min(lift * 1.6, 2.2))))
                }
            }
            eval(frame)
            let (pos, fwd, sideAxis, _) = chestFrame(chest)
            for (side, x) in [("左", Float(1)), ("右", -1)] {
                let target = pos + fwd * h * (0.13 + 0.05 * ease) + sideAxis * x * h * (0.08 + 0.04 * ease)
                    + SIMD3(0, 1, 0) * h * (0.18 - 0.43 * ease)
                if let r = armIK(side, target, sideAxis * x - SIMD3(0, 1, 0) * 0.3) { frame.rotations += r }
                frame.rotations += fingers(side, 0.7 - 0.4 * ease, 0.4)
            }
            frames.append(frame)
        }
        resetToIdle()
        return BakedClip(name: "mantle", frames: frames, fps: 30, groundSpeed: 0, mapped: 0)
    }

    /// `style` は 0: 腕を振る、1: 手拍子、2: 指さし。
    func buildBeatDance(_ style: Int) -> BakedClip? {
        guard let base = motions[.idle]?.frames.first, let chest = b("首") else { return nil }
        let h = height
        let (upper, neck) = (b("上半身"), b("首"))
        let n = 60
        var frames: [BakedClip.Frame] = []
        let tau = Math.tau
        for i in 0...n {
            let u = Float(i) / Float(n)
            let beats = u * 4
            let p = Math.fract(beats)
            let beat = Int(beats.rounded(.down)) % 4
            var frame = base
            let bounce = pow((1 + cos(p * tau)) / 2, 1.5)
            let shift = sin(u * tau * 2 / 2 * 2)
            if let (b0, c) = frame.center { frame.center = (b0, c + SIMD3(shift * h * 0.025, -bounce * h * 0.03, 0)) }
            Self.push(&frame, upper, Math.mul(Math.rotZ(-shift * 0.08), Math.rotX(-bounce * 0.05)))
            Self.push(&frame, neck, Math.mul(Math.rotX(-bounce * 0.12), Math.rotZ(shift * 0.06)))
            eval(frame)
            let (pos, fwd, side, _) = chestFrame(chest)
            var extra: [(Int, simd_quatf)] = []
            for (s, x) in [("左", Float(1)), ("右", -1)] {
                let target: SIMD3<Float>
                switch style {
                case 0:
                    let swing = shift * x
                    target = pos - SIMD3(0, 1, 0) * h * (0.22 - 0.05 * bounce) + side * x * h * 0.1 + fwd * h * (0.05 + 0.08 * swing)
                case 1:
                    let on: Float = beat % 2 == 1 ? max(cos(p * Float.pi), 0) : 0
                    let open = 1 - pow(on, 0.5)
                    target = pos - SIMD3(0, 1, 0) * h * 0.08 + fwd * h * 0.14 + side * x * h * (0.015 + 0.09 * open)
                default:
                    let up: Float = (beat % 2 == 0) == (x > 0) ? pow(sin((1 - p) * Float.pi / 2), 0.5) : 0
                    let hip = pos - SIMD3(0, 1, 0) * h * 0.24 + side * x * h * 0.12 + fwd * h * 0.02
                    let sky = pos + SIMD3(0, 1, 0) * h * 0.18 + side * x * h * 0.22 + fwd * h * 0.1
                    target = Math.lerp(hip, sky, up)
                }
                if let r = armIK(s, target, side * x - SIMD3(0, 1, 0) * 0.5) { extra += r }
                extra += fingers(s, style == 2 ? 0.9 : 0.25, 0.3)
            }
            Self.replace(&frame, with: extra)
            frames.append(frame)
        }
        resetToIdle()
        return BakedClip(name: "beat-dance-\(style)", frames: frames, fps: 30, groundSpeed: 0, mapped: 0)
    }

    func buildHolding(_ base: Slot, _ hold: Hold) -> BakedClip? {
        guard let src = motions[base], let chest = b("首") else { return nil }
        let h = height
        let (neck, head) = (b("首"), b("頭"))
        let tau = Math.tau
        var frames: [BakedClip.Frame] = []
        let length = Float(src.frames.count) / src.fps
        let period = length / max((length / 4).rounded(.toNearestOrAwayFromZero), 1)
        for (i, f) in src.frames.enumerated() {
            let t = Float(i) / src.fps
            var frame = f
            var sip: Float = 0
            if hold.toMouth {
                let u = t.truncatingRemainder(dividingBy: period) / 1.2
                if u < 1 { sip = pow(sin(u * Float.pi), 0.6) }
            }
            for (bone, a) in [(neck, 0.15 * hold.look), (head, 0.3 * hold.look - 0.25 * sip)] {
                if let bone, let r = frame.rotations.firstIndex(where: { $0.0 == bone }) {
                    frame.rotations[r].1 = Math.mul(Math.rotX(-a), frame.rotations[r].1)
                }
            }
            eval(frame)
            let (pos, fwd, side, _) = chestFrame(chest)
            let rot = Math.rotationOf(world(chest))
            let mid = pos + fwd * h * hold.forward - SIMD3(0, 1, 0) * h * hold.down
            let mouth = pos + SIMD3(0, 1, 0) * h * 0.06 + fwd * h * 0.07 - side * h * 0.02
            let fan = pos + SIMD3(0, 1, 0) * h * 0.05 + fwd * h * 0.1 - side * h * (0.1 + 0.035 * sin(t * 2.5 * tau))
            var extra: [(Int, simd_quatf)] = []
            let arms: [(String, Float)] = hold.oneHand ? [("右", -1)] : [("左", 1), ("右", -1)]
            for (s, x) in arms {
                var target = mid + side * x * h * hold.spread / 2
                target = hold.fan ? fan : Math.lerp(target, mouth, sip)
                if let r = armIK(s, target, side * x - SIMD3(0, 1, 0)) { extra += r }
                let thumb: Float = hold.tap ? 0.25 + 0.3 * max(sin((t * 2.5 + (x > 0 ? 0 : 0.5)) * tau), 0) : 0.2
                extra += fingers(s, 0.75, thumb)
            }
            Self.replace(&frame, with: extra)
            eval(frame)
            let up = Math.rotate(rot, SIMD3(0, 1, 0))
            if hold.oneHand && !hold.fan {
                let d = simd_normalize(fwd + side * 0.55)
                let a = simd_normalize(up - d * simd_dot(d, up))
                let tilt = Math.axisAngle(simd_cross(d, a), 0.6 * sip)
                if let r = gripWrist("右", Math.rotate(tilt, d), Math.rotate(tilt, a)) {
                    frame.rotations.removeAll { $0.0 == r.0 }
                    frame.rotations.append(r)
                }
                frames.append(frame)
                continue
            }
            let want = simd_normalize(up * 0.85 + fwd * 0.5)
            for (s, _) in arms {
                guard let w = b("\(s)手首"), let m1 = b("\(s)中指１") else { continue }
                let wrist = world(w)
                let hand = Math.normalizeOrZero((world(m1).columns.3 - wrist.columns.3).xyz)
                let parent = Int(model.pmx.bones[w].parentIndex)
                guard parent >= 0 else { continue }
                let pr = Math.rotationOf(world(parent)), wr = Math.rotationOf(wrist)
                let local = simd_normalize(Math.mul(Math.mul(Math.inverse(pr), Math.rotationArc(hand, want)), wr))
                frame.rotations.removeAll { $0.0 == w }
                frame.rotations.append((w, local))
            }
            frames.append(frame)
        }
        resetToIdle()
        var out = src
        (out.name, out.frames) = ("\(src.name)-holding", frames)
        return out
    }
}
