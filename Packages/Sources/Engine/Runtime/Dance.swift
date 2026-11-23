import simd

enum Dance {
    /// 名前はクリップ名 `dance:<足>-<腕>` に使う。
    static let legs = ["Bounce", "StepTouch", "Twist", "KneePop", "SideStep", "Kick", "Hop", "Sway", "TwoStep", "BoxStep",
                              "KickBallChange", "Grapevine", "VStep", "HeelToe", "Charleston", "Rock", "Point", "Cross", "HipRoll",
                              "Chacha", "March", "Tiptoe", "HeelTap"]
    static let arms = ["Pump", "Clap", "Point", "Overhead", "Wave", "Roll", "Hips", "Twinkle", "Swim", "Cat", "Heart", "Punch",
                              "Peace", "Bunny", "Cheek", "Kiss", "Jazz", "Ganbare", "Burikko", "HeadHeart", "Pray", "Hello"]

    static func index(legs l: Int, arms a: Int) -> UInt16 { UInt16(l * arms.count + a) }

    static func beats(_ legs: String) -> Int { legs == "SideStep" || legs == "Grapevine" ? 8 : 4 }

    enum Hand { case fist, open, point, paw, soft, peace }
    typealias Key = (Float, Float, Float)

    /// 首の付け根から見た横・上・前（身長に対する比）。`x` は左が 1、右が −1。
    static func armPose(_ arms: String, _ x: Float, _ t: Float) -> (Key, Hand) {
        let beat = Int(t.rounded(.down)) % 4
        let p = Math.fract(t)
        let ease = p * p * (3 - 2 * p)
        func lerp(_ a: Key, _ b: Key) -> Key { (a.0 + (b.0 - a.0) * ease, a.1 + (b.1 - a.1) * ease, a.2 + (b.2 - a.2) * ease) }
        func keys(_ k: [Key]) -> Key { lerp(k[beat], k[(beat + 1) % 4]) }
        let left = x > 0
        let pi = Float.pi, tau = Math.tau
        switch arms {
        case "Pump":
            let (hi, lo): (Key, Key) = ((x * 0.17, 0.21, 0.11), (x * 0.14, -0.07, 0.1))
            return (keys(left ? [hi, lo, hi, lo] : [lo, hi, lo, hi]), .fist)
        case "Clap":
            let (open, shut): (Key, Key) = ((x * 0.17, -0.06, 0.12), (x * 0.012, -0.03, 0.17))
            return (keys([open, shut, open, shut]), .open)
        case "Point":
            if left { return ((0.14, -0.25, 0), .fist) }
            let (up, hip): (Key, Key) = ((-0.26, 0.22, 0.1), (-0.13, -0.25, 0.03))
            return (keys([up, hip, up, hip]), .point)
        case "Overhead":
            func sway(_ s: Float) -> Key { (x * 0.1 + s, 0.22, 0.07) }
            return (keys([sway(0.07), sway(-0.07), sway(0.07), sway(-0.07)]), .open)
        case "Wave":
            let phase = t * pi + (left ? 0 : pi / 2)
            return ((x * 0.22, -0.04 + 0.06 * sin(phase), 0.09), .soft)
        case "Roll":
            let a = t * pi + (left ? 0 : pi)
            return ((x * 0.03 + 0.05 * cos(a), -0.08 + 0.05 * sin(a), 0.16), .fist)
        case "Hips": return ((x * 0.14, -0.25, 0.01), .fist)
        case "Twinkle":
            let shake = 0.012 * sin(t * tau * 2)
            return ((x * 0.11 + shake, 0.1, 0.1), .open)
        case "Swim":
            let (front, out, back): (Key, Key, Key) = ((x * 0.03, 0, 0.24), (x * 0.23, -0.02, 0.12), (x * 0.07, -0.1, 0.08))
            return (keys([front, out, back, front]), .soft)
        case "Cat":
            let (up, down): (Key, Key) = ((x * 0.07, 0.07, 0.13), (x * 0.08, 0.02, 0.14))
            return (keys([down, up, down, up]), .paw)
        case "Heart":
            let (low, heart): (Key, Key) = ((x * 0.12, -0.12, 0.1), (x * 0.025, 0.02, 0.17))
            return (keys([low, low, low, heart]), beat >= 2 ? .soft : .open)
        case "Punch":
            let (punch, guardKey): (Key, Key) = ((x * 0.04, -0.02, 0.3), (x * 0.1, -0.08, 0.08))
            return (keys(left ? [punch, guardKey, punch, guardKey] : [guardKey, punch, guardKey, punch]), .fist)
        case "Peace":
            let (face, hip): (Key, Key) = ((x * 0.07, 0.07, 0.11), (x * 0.13, -0.22, 0.03))
            let up = left ? beat >= 2 : beat < 2
            return (keys(left ? [hip, hip, face, face] : [face, face, hip, hip]), up ? .peace : .fist)
        case "Bunny":
            let (ear, fold): (Key, Key) = ((x * 0.05, 0.21, 0.01), (x * 0.07, 0.17, 0.05))
            return (keys([ear, fold, ear, fold]), .open)
        case "Cheek":
            let (a, b): (Key, Key) = ((x * 0.065, 0.06, 0.085), (x * 0.07, 0.045, 0.09))
            return (keys([a, b, a, b]), .soft)
        case "Kiss":
            if left { return ((0.13, -0.22, 0.03), .fist) }
            let (mouth, out): (Key, Key) = ((-0.02, 0.05, 0.11), (-0.1, 0.09, 0.27))
            return (keys([mouth, out, mouth, out]), beat % 2 == 0 ? .soft : .open)
        case "Jazz":
            let shake = 0.012 * sin(t * tau * 3)
            return ((x * 0.17 + shake, 0.06 + 0.02 * sin(t * tau), 0.15), .open)
        case "Ganbare":
            let (up, down): (Key, Key) = ((x * 0.07, 0, 0.13), (x * 0.08, -0.08, 0.11))
            return (keys([up, down, up, down]), .fist)
        case "Burikko":
            let sway = 0.025 * sin(t * pi)
            return ((x * 0.035 + sway, 0.015, 0.12), .paw)
        case "HeadHeart":
            let (open, heart): (Key, Key) = ((x * 0.13, 0.2, 0.09), (x * 0.04, 0.26, 0.07))
            return (keys([open, open, heart, heart]), .soft)
        case "Pray":
            let bob = 0.012 * sin(t * tau)
            return ((x * 0.012, -0.04 + bob, 0.15), .open)
        default:
            if left { return ((0.13, -0.22, 0.03), .fist) }
            return ((-0.13 + 0.045 * sin(t * pi), 0.19, 0.07), .open)
        }
    }

    /// 拍 `from`〜`to` に、床の (横, 前) の `a` から `b` へ足を運ぶ。
    struct Swing {
        var from: Float, to: Float, a: (Float, Float), b: (Float, Float), lift: Float, pitch: Float
    }

    static func step(_ from: Float, _ to: Float, _ a: (Float, Float), _ b: (Float, Float), _ lift: Float) -> Swing {
        Swing(from: from, to: to, a: a, b: b, lift: lift, pitch: -0.25)
    }

    static func tap(_ from: Float, _ to: Float, _ at: (Float, Float), _ toward: (Float, Float), _ lift: Float, _ pitch: Float) -> [Swing] {
        let mid = (from + to) / 2
        return [Swing(from: from, to: mid, a: at, b: toward, lift: lift, pitch: pitch),
                Swing(from: mid, to: to, a: toward, b: at, lift: lift, pitch: pitch)]
    }

    static func footAt(_ swings: [Swing], _ t: Float) -> (SIMD3<Float>, Float) {
        var at = swings.first?.a ?? (0, 0)
        for s in swings {
            if t < s.from { break }
            if t < s.to {
                let u = (t - s.from) / (s.to - s.from)
                let e = u * u * (3 - 2 * u)
                let arc = sin(u * Float.pi)
                let (x, f) = (s.a.0 + (s.b.0 - s.a.0) * e, s.a.1 + (s.b.1 - s.a.1) * e)
                return (SIMD3(x, s.lift * arc, -f), s.pitch * arc)
            }
            at = s.b
        }
        return (SIMD3(at.0, 0, -at.1), 0)
    }

    struct LegPose {
        var center: SIMD3<Float>, feet: [SIMD3<Float>], twist: Float, pitch: [Float], lean: Float
    }

    static func legSwings(_ legs: String) -> ([Swing], [Swing]) {
        let s: Float = 0.08
        func sw(_ from: Float, _ to: Float, _ a: (Float, Float), _ b: (Float, Float), _ lift: Float, _ pitch: Float) -> Swing {
            Swing(from: from, to: to, a: a, b: b, lift: lift, pitch: pitch)
        }
        switch legs {
        case "StepTouch": return (tap(2, 2.95, (0, 0), (0.07, 0), 0.02, -0.3), tap(0.05, 0.95, (0, 0), (-0.07, 0), 0.02, -0.3))
        case "SideStep":
            let w: Float = 0.11
            return ([step(0.05, 0.6, (0, 0), (w, 0), 0.035), step(2, 2.6, (w, 0), (2 * w, 0), 0.035),
                     step(5, 5.6, (2 * w, 0), (w, 0), 0.03), step(7, 7.6, (w, 0), (0, 0), 0.03)],
                    [step(1, 1.6, (0, 0), (w, 0), 0.03), step(3, 3.6, (w, 0), (2 * w, 0), 0.03),
                     step(4, 4.6, (2 * w, 0), (w, 0), 0.035), step(6, 6.6, (w, 0), (0, 0), 0.035)])
        case "TwoStep":
            return ([sw(1, 1.55, (0, 0), (-s, 0), 0.04, -0.45), step(2, 2.55, (-s, 0), (0, 0), 0.03)],
                    [step(0.05, 0.55, (0, 0), (-s, 0), 0.03), sw(3, 3.55, (-s, 0), (0, 0), 0.04, -0.45)])
        case "BoxStep":
            return ([step(1, 1.6, (0, 0), (0, -0.07), 0.025), step(3, 3.6, (0, -0.07), (0, 0), 0.025)],
                    [step(0.05, 0.6, (0, 0), (0.06, 0.07), 0.03), step(2, 2.6, (0.06, 0.07), (0, 0), 0.03)])
        case "KickBallChange":
            return ([sw(2, 2.6, (0, 0), (0, 0), 0, 0), step(2.6, 2.9, (0, 0), (0, -0.05), 0.015), step(3.2, 3.6, (0, -0.05), (0, 0), 0.015)],
                    [sw(0.05, 0.6, (0, 0), (0, 0), 0, 0), step(0.6, 1, (0, 0), (0, -0.05), 0.015), step(1.4, 1.9, (0, -0.05), (0, 0), 0.015)])
        case "Grapevine":
            let w: Float = 0.11
            return ([step(0.05, 0.6, (0, 0), (w, 0), 0.035), step(2, 2.6, (w, 0), (2 * w, 0), 0.035),
                     step(5, 5.6, (2 * w, 0), (w, -0.06), 0.03), step(7, 7.6, (w, -0.06), (0, 0), 0.03)],
                    [step(1, 1.6, (0, 0), (w, -0.06), 0.03), step(3, 3.6, (w, -0.06), (2 * w, 0), 0.03),
                     step(4, 4.6, (2 * w, 0), (w, 0), 0.035), step(6, 6.6, (w, 0), (0, 0), 0.035)])
        case "VStep":
            return ([step(1, 1.6, (0, 0), (0.06, 0.07), 0.03), step(3, 3.6, (0.06, 0.07), (0, 0), 0.03)],
                    [step(0.05, 0.6, (0, 0), (-0.06, 0.07), 0.03), step(2, 2.6, (-0.06, 0.07), (0, 0), 0.03)])
        case "HeelToe":
            return (tap(2, 2.9, (0, 0), (0, 0.08), 0.02, 0.55) + tap(3, 3.6, (0, 0), (0, -0.07), 0.02, -0.6),
                    tap(0.05, 0.9, (0, 0), (0, 0.08), 0.02, 0.55) + tap(1, 1.9, (0, 0), (0, -0.07), 0.02, -0.6))
        case "Charleston":
            return (tap(2, 3.6, (0, 0), (0, -0.1), 0.05, -0.5), tap(0.05, 1.9, (0, 0), (0, 0.1), 0.05, 0.3))
        case "Point":
            return (tap(2.05, 2.9, (0, 0), (0.07, 0), 0.015, -0.5) + tap(3.05, 3.6, (0, 0), (0, 0.07), 0.015, -0.5),
                    tap(0.05, 0.9, (0, 0), (-0.07, 0), 0.015, -0.5) + tap(1.05, 1.9, (0, 0), (0, 0.07), 0.015, -0.5))
        case "Cross":
            return ([step(2.05, 2.6, (0, 0), (-0.04, 0.04), 0.025), step(3.05, 3.6, (-0.04, 0.04), (0, 0), 0.025)],
                    [step(0.05, 0.6, (0, 0), (0.04, 0.04), 0.025), step(1.05, 1.6, (0.04, 0.04), (0, 0), 0.025)])
        case "Chacha":
            return ([step(2.5, 2.8, (0, 0), (0, 0), 0.02)],
                    [step(0.05, 0.45, (0, 0), (0, 0.05), 0.02), step(1, 1.4, (0, 0.05), (0, 0), 0.02),
                     step(2, 2.3, (0, 0), (0, 0), 0.02), step(3, 3.3, (0, 0), (0, 0), 0.02)])
        case "March":
            return ([sw(0.05, 0.55, (0, 0), (0, 0), 0.06, -0.15), sw(2.05, 2.55, (0, 0), (0, 0), 0.06, -0.15)],
                    [sw(1.05, 1.55, (0, 0), (0, 0), 0.06, -0.15), sw(3.05, 3.55, (0, 0), (0, 0), 0.06, -0.15)])
        case "HeelTap":
            return (tap(1.05, 1.55, (0, 0), (0, 0.06), 0.015, 0.5) + tap(3.05, 3.55, (0, 0), (0, 0.06), 0.015, 0.5),
                    tap(0.05, 0.55, (0, 0), (0, 0.06), 0.015, 0.5) + tap(2.05, 2.55, (0, 0), (0, 0.06), 0.015, 0.5))
        default: return ([], [])
        }
    }

    static func legPose(_ legs: String, _ t: Float) -> LegPose {
        let pi = Float.pi, tau = Math.tau
        let p = Math.fract(t)
        let dip = pow((1 + cos(p * tau)) / 2, 1.5)
        let two = sin(t * pi)
        let (left, right) = legSwings(legs)
        let (l, r) = (footAt(left, t), footAt(right, t))
        var feet = [l.0, r.0]
        var pitch = [l.1, r.1]
        let kicks: [(Int, Float, Float)] = switch legs {
        case "Kick": [(0, 1, 0.6), (1, 3, 0.6)]
        case "KickBallChange": [(1, 0.05, 0.55), (0, 2, 0.6)]
        default: []
        }
        for (k, start, len) in kicks {
            let u = (t - start) / len
            if u >= 0 && u < 1 {
                let kick = sin(u * pi)
                feet[k] = SIMD3(feet[k].x, 0.06 * kick, feet[k].z - 0.1 * kick)
                pitch[k] = -0.5 * kick
            }
        }
        let mid = (feet[0] + feet[1]) / 2
        let support: SIMD3<Float> = feet[0].y > 1e-4 ? feet[1] - mid : (feet[1].y > 1e-4 ? feet[0] - mid : .zero)
        let lifted = max(feet[0].y, feet[1].y)
        let weight = mid + support * min(lifted / 0.03, 1) * 0.6
        func stepping(_ depth: Float) -> LegPose {
            LegPose(center: SIMD3(weight.x, -depth * dip, weight.z * 0.5), feet: feet, twist: 0, pitch: pitch, lean: 0)
        }
        func still(_ center: SIMD3<Float>, _ twist: Float) -> LegPose {
            LegPose(center: center, feet: [.zero, .zero], twist: twist, pitch: [0, 0], lean: 0)
        }
        switch legs {
        case "Bounce": return still(SIMD3(0, -0.035 * dip, 0), 0)
        case "Twist": return still(SIMD3(0, -0.025 * dip, 0), 0.3 * sin(t * pi))
        case "Sway": return still(SIMD3(0.05 * two, -0.02 * dip, 0), 0.12 * two)
        case "Rock":
            var pose = still(SIMD3(0, -0.02 * dip, 0.025 * two), 0)
            pose.lean = 0.05 * two
            return pose
        case "HipRoll":
            let a = t * pi
            return still(SIMD3(0.03 * cos(a), -0.02 * dip, 0.02 * sin(a)), 0.1 * sin(a))
        case "Tiptoe":
            let pop = sin(p * pi)
            let heel = SIMD3<Float>(0, 0.018 * pop, 0)
            return LegPose(center: SIMD3(0, 0.012 * pop - 0.015 * dip, 0), feet: [heel, heel], twist: 0, pitch: [-0.35 * pop, -0.35 * pop], lean: 0)
        case "KneePop":
            let pop = sin(p * pi)
            let isLeft = Int(t.rounded(.down)) % 2 == 0
            let w = cos(t * pi)
            let heel = SIMD3<Float>(0, 0.02 * pop, 0)
            return LegPose(center: SIMD3(0.012 * w, -0.03 * dip - 0.01 * pop, 0), feet: isLeft ? [heel, .zero] : [.zero, heel],
                           twist: 0.1 * w, pitch: isLeft ? [-0.35 * pop, 0] : [0, -0.35 * pop], lean: 0)
        case "Hop":
            let q = Math.remEuclid(t, 2)
            func bump(_ c: Float, _ w: Float) -> Float {
                let d = Math.remEuclid(q - c + 1, 2) - 1
                let r = d / w
                return exp(-(r * r))
            }
            func ease(_ u: Float) -> Float {
                let u = Math.clamp(u, 0, 1)
                return u * u * (3 - 2 * u)
            }
            let crouch: Float = q >= 1 && q < 1.38 ? ease((q - 1) / 0.38) : (q >= 1.38 && q < 1.5 ? 1 - ease((q - 1.38) / 0.12) : 0)
            let toes = -0.45 * bump(1.48, 0.07) - 0.25 * bump(1.75, 0.15) - 0.12 * bump(0, 0.05)
            let land = bump(0.06, 0.08)
            return LegPose(center: SIMD3(0, -0.085 * crouch - 0.045 * land, 0), feet: [.zero, .zero], twist: 0, pitch: [toes, toes],
                           lean: 0.2 * crouch + 0.06 * land)
        case "TwoStep":
            var pose = stepping(0.045)
            pose.lean = 0.04 * dip
            return pose
        case "Kick", "KickBallChange":
            var pose = stepping(0.025)
            pose.lean = -0.05 * lifted / 0.08
            return pose
        default: return stepping(0.03)
        }
    }

    static let cuteArms: Set<String> = ["Cat", "Twinkle", "Heart", "Peace", "Bunny", "Cheek", "Kiss", "Burikko", "HeadHeart", "Pray"]
}

extension Puppet {
    /// `Dance.legs`・`Dance.arms` の名前で 1 小節（SideStep・Grapevine は 2 小節）のクリップに焼く。
    func buildDance(_ legs: String, _ arms: String) -> BakedClip? {
        guard let base = motions[.idle]?.frames.first, let chest = b("首") else { return nil }
        let h = height
        let (lower, upper, neck, head) = (b("下半身"), b("上半身"), b("首"), b("頭"))
        let shoulders = [b("左肩"), b("右肩")]
        let thighs = [b("左足"), b("右足")]
        let names = model.pmx.bones
        func foot(_ side: String) -> Int? { base.feet.firstIndex { names[$0.0].name.hasPrefix(side) } }
        let (fl, fr) = (foot("左"), foot("右"))
        let ankles = [b("左足首"), b("右足首")]
        eval(base)
        let flats = ankles.map { $0.map { Math.rotationOf(world($0)) } }
        let nBeats = Dance.beats(legs)
        let n = 15 * nBeats
        let pi = Float.pi, tau = Math.tau
        var frames: [BakedClip.Frame] = []
        for i in 0...n {
            let t = Float(i) / Float(n) * Float(nBeats)
            let p = Math.fract(t)
            let dip = pow((1 + cos(p * tau)) / 2, 1.5)
            var frame = base
            let leg = Dance.legPose(legs, t)
            if let (c0, c) = frame.center { frame.center = (c0, c + leg.center * h) }
            for (k, idx) in [fl, fr].enumerated() {
                if let idx { frame.feet[idx].1 += leg.feet[k] * h }
            }
            Self.push(&frame, lower, Math.rotY(leg.twist))
            for thigh in thighs { Self.push(&frame, thigh, Math.rotY(-leg.twist)) }
            let lean = -leg.center.x * 1.4
            Self.push(&frame, upper, Math.mul(Math.mul(Math.rotY(-leg.twist * 0.5), Math.rotZ(lean)), Math.rotX(-dip * 0.05 - leg.lean)))
            Self.push(&frame, neck, Math.rotX(-dip * 0.06))
            Self.push(&frame, head, Math.rotZ(Dance.cuteArms.contains(arms) ? 0.08 * sin(t * pi / 2) : -lean * 0.35))
            let poses = [Dance.armPose(arms, 1, t), Dance.armPose(arms, -1, t)]
            for (k, x) in [Float(1), -1].enumerated() {
                let key = poses[k].0
                let raise = Math.clamp((key.1 + 0.03) / 0.22, 0, 1) * 0.32
                let shimmy: Float = arms == "Hips" ? 0.08 * sin(t * pi * 2 + (x > 0 ? 0 : pi)) : 0
                Self.push(&frame, shoulders[k], Math.rotZ(x * (raise + shimmy)))
            }
            eval(frame)
            let (pos, fwd, side, up) = chestFrame(chest)
            var extra: [(Int, simd_quatf)] = []
            for k in 0..<2 {
                guard let a = ankles[k], let flat = flats[k] else { continue }
                let parent = Int(model.pmx.bones[a].parentIndex)
                guard parent >= 0 else { continue }
                let pw = Math.rotationOf(world(parent))
                let want = Math.mul(Math.rotX(leg.pitch[k]), flat)
                extra.append((a, simd_normalize(Math.mul(Math.inverse(pw), want))))
            }
            for (k, (s, x)) in [("左", Float(1)), ("右", -1)].enumerated() {
                let (key, hand) = poses[k]
                let target = pos + (side * key.0 + up * key.1 + fwd * key.2) * h
                var w = Math.clamp((key.1 + 0.08) / 0.16, 0, 1)
                w = w * w * (3 - 2 * w)
                let pole = side * x + (-fwd * 0.4) * w + (-up * 0.6 - fwd * 0.2) * (1 - w)
                if let r = armIK(s, target, pole) { extra += r }
                extra += handShape(s, hand)
            }
            Self.replace(&frame, with: extra)
            frames.append(frame)
        }
        resetToIdle()
        return BakedClip(name: "dance:\(legs)-\(arms)", frames: frames, fps: 30, groundSpeed: 0, mapped: 0)
    }

    func handShape(_ side: String, _ hand: Dance.Hand) -> [(Int, simd_quatf)] {
        let sign: Float = side == "左" ? -1 : 1
        var out: [(Int, simd_quatf)] = []
        for f in Self.fingerNames {
            let thumb = f == "親指"
            let curl: Float = switch hand {
            case .fist: thumb ? 0.7 : 1.3
            case .open: 0.05
            case .point: f == "人指" ? 0 : (thumb ? 0.6 : 1.3)
            case .paw: thumb ? 0.4 : 0.9
            case .soft: thumb ? 0.2 : 0.35
            case .peace: f == "人指" || f == "中指" ? 0 : (thumb ? 0.8 : 1.3)
            }
            for (j, n) in (thumb ? ["０", "１", "２"] : ["１", "２", "３"]).enumerated() {
                let c = hand == .paw && j == 0 ? curl * 0.4 : curl
                if let bone = b("\(side)\(f)\(n)") { out.append((bone, Math.rotZ(sign * c))) }
            }
        }
        return out
    }
}
