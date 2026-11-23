enum GLTFHumanoid {
    static let table: [(String, [String])] = [
        ("hips", ["hips", "pelvis", "jbipchips", "bippelvis", "ccbasehip"]),
        ("spine", ["spine", "spine01", "jbipcspine", "bipspine", "ccbasewaist"]),
        ("chest", ["chest", "spine2", "spine03", "jbipcchest", "bipspine1", "ccbasespine02"]),
        ("upperChest", ["jbipcupperchest", "bipspine2"]),
        ("neck", ["neck", "neck01", "jbipcneck", "bipneck", "ccbasenecktwist01"]),
        ("head", ["head", "jbipchead", "biphead", "ccbasehead"]),
        ("#Shoulder", ["clavicle@", "@shoulder", "shoulder@", "jbip@shoulder", "bip@clavicle", "ccbase@clavicle"]),
        ("#UpperArm", ["upperarm@", "@arm", "jbip@upperarm", "bip@upperarm", "ccbase@upperarm"]),
        ("#LowerArm", ["lowerarm@", "@forearm", "forearm@", "jbip@lowerarm", "bip@forearm", "ccbase@forearm"]),
        ("#Hand", ["hand@", "@hand", "jbip@hand", "bip@hand", "ccbase@hand"]),
        ("#UpperLeg", ["thigh@", "@upleg", "upperleg@", "jbip@upperleg", "bip@thigh", "ccbase@thigh"]),
        ("#LowerLeg", ["calf@", "@leg", "shin@", "lowerleg@", "jbip@lowerleg", "bip@calf", "ccbase@calf"]),
        ("#Foot", ["foot@", "@foot", "jbip@foot", "bip@foot", "ccbase@foot"]),
        ("#Toes", ["ball@", "@toebase", "toe@", "toes@", "jbip@toebase", "bip@toe0", "ccbase@toebase"]),
    ]

    static let fingers: [(String, String)] = [
        ("Thumb", "thumb"), ("Index", "index"), ("Middle", "middle"), ("Ring", "ring"), ("Little", "pinky"),
    ]

    static func normalize(_ name: String) -> String {
        let base = name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? name
        let s = String(String.UnicodeScalarView(base.unicodeScalars.filter { !"_.- ".unicodeScalars.contains($0) }))
            .lowercased()
        for p in ["bip001", "bip01"] where s.hasPrefix(p) { return "bip" + s.dropFirst(p.count) }
        return s
    }

    static func candidate(_ pattern: String, left: Bool) -> String {
        let (long, short) = left ? ("left", "l") : ("right", "r")
        if pattern.hasPrefix("@") { return long + pattern.dropFirst() }
        return pattern.replacingOccurrences(of: "@", with: short)
    }

    static func guess(_ names: [String?]) -> [(String, Int)] {
        let norm = names.map { $0.map(normalize) }
        func find(_ pats: [String]) -> Int? {
            for p in pats {
                let hits = norm.indices.filter { norm[$0] == p }
                if hits.count == 1 { return hits[0] }
            }
            return nil
        }
        var out: [(String, Int)] = []
        for (bone, pats) in table {
            if bone.hasPrefix("#") {
                for (left, side) in [(true, "left"), (false, "right")] {
                    if let n = find(pats.map { candidate($0, left: left) }) { out.append(("\(side)\(bone.dropFirst())", n)) }
                }
            } else if let n = find(pats) {
                out.append((bone, n))
            }
        }
        for (fi, (vrm, mixamo)) in fingers.enumerated() {
            let joints = vrm == "Thumb" ? ["Metacarpal", "Proximal", "Distal"] : ["Proximal", "Intermediate", "Distal"]
            for (left, side) in [(true, "left"), (false, "right")] {
                let (long, short) = left ? ("left", "l") : ("right", "r")
                for (k, joint) in joints.enumerated() {
                    let ue = mixamo
                    let vroid = vrm == "Thumb" ? "thumb" : vrm
                    let biped = k == 0 ? "bip\(short)finger\(fi)" : "bip\(short)finger\(fi)\(k)"
                    let p = [
                        "\(ue)0\(k + 1)\(short)",
                        "\(long)hand\(mixamo)\(k + 1)",
                        "jbip\(short)\(vroid.lowercased())\(k + 1)",
                        biped,
                        "ccbase\(short)\(vrm == "Middle" ? "mid" : mixamo)\(k + 1)",
                    ]
                    if let n = find(p) { out.append(("\(side)\(vrm)\(joint)", n)) }
                }
            }
        }
        return out
    }

    static func infer(parent: [Int?], pos: [SIMD3<Float>], joints allJoints: [Int]) -> [(String, Int)] {
        let joints = allJoints.filter { $0 < pos.count }
        guard joints.count >= 10 else { return [] }
        func pathUp(_ start: Int) -> [Int] {
            var v = [start], n = start
            while n < parent.count, let p = parent[n] {
                v.append(p)
                n = p
            }
            return v
        }
        func split(_ a: Int, _ b: Int) -> (Int, [Int], [Int])? {
            let pa = pathUp(a), pb = pathUp(b)
            guard let common = pa.first(where: { pb.contains($0) }) else { return nil }
            func down(_ p: [Int]) -> [Int] { Array(p.prefix { $0 != common }.reversed()) }
            return (common, down(pa), down(pb))
        }
        // 同点は、最小なら最初、最大なら最後を選ぶ
        func firstMin(_ xs: [Int], _ key: (Int) -> Float) -> Int? {
            xs.reduce(nil) { best, x in best.map { key(x) < key($0) ? x : $0 } ?? x }
        }
        let lf = firstMin(joints.filter { pos[$0].x > 1e-4 }) { pos[$0].y }
        let rf = firstMin(joints.filter { pos[$0].x < -1e-4 }) { pos[$0].y }
        let lhand = joints.lastMax { pos[$0].x }, rhand = joints.lastMax { -pos[$0].x }
        guard let lf, let rf, let lhand, let rhand, let (hips, lLeg0, rLeg0) = split(lf, rf),
              let (chest, lArm0, rArm0) = split(lhand, rhand) else { return [] }
        guard lLeg0.count >= 3, rLeg0.count >= 3, pos[chest].y > pos[hips].y else { return [] }
        func middle(_ chain: ArraySlice<Int>, _ a: Int, _ b: Int) -> Int? {
            let m = (pos[a] + pos[b]) * 0.5
            let inner = Array(chain.dropFirst().dropLast())
            return firstMin(inner) { simd_distance(pos[$0], m) }
        }
        let backwards = (pos[lf].z + pos[rf].z) * 0.5 < pos[hips].z
        let (lLeg, rLeg, lArm, rArm) = backwards ? (rLeg0, lLeg0, rArm0, lArm0) : (lLeg0, rLeg0, lArm0, rArm0)
        let (lh, rh) = backwards ? (rhand, lhand) : (lhand, rhand)
        var out: [(String, Int)] = [("hips", hips), ("chest", chest)]
        let ys = joints.map { pos[$0].y }
        let height = ys.reduce(-Float.greatestFiniteMagnitude, max) - ys.reduce(Float.greatestFiniteMagnitude, min)
        for (side, leg) in [("left", lLeg), ("right", rLeg)] {
            let floor = pos[leg.last!].y
            let footAt = leg.lastIndex { pos[$0].y > floor + height * 0.03 } ?? (leg.count - 1)
            let f = max(footAt, 2)
            let (upper, foot) = (leg[0], leg[f])
            if let knee = middle(leg[...f], upper, foot) {
                out.append(("\(side)UpperLeg", upper))
                out.append(("\(side)LowerLeg", knee))
                out.append(("\(side)Foot", foot))
                if f + 1 < leg.count { out.append(("\(side)Toes", leg[f + 1])) }
            }
        }
        func children(_ n: Int) -> Int { parent.filter { $0 == n }.count }
        for (side, arm) in [("left", lArm), ("right", rArm)] {
            guard arm.count >= 3 else { continue }
            // 並べば後のもの
            var best: (Int, Int)?
            for (i, j) in arm.dropLast().enumerated() where best == nil || children(j) >= best!.1 { best = (i, children(j)) }
            let handAt = best.flatMap { $0.1 >= 3 ? $0.0 : nil } ?? (arm.count - 2)
            guard handAt >= 2 else { continue }
            let shoulder: Int? = handAt >= 3 ? arm[0] : nil
            let upper = handAt >= 3 ? arm[1] : arm[0]
            let hand = arm[handAt]
            let start = shoulder == nil ? 0 : 1
            if let elbow = middle(arm[start...handAt], upper, hand) {
                if let shoulder { out.append(("\(side)Shoulder", shoulder)) }
                out.append(("\(side)UpperArm", upper))
                out.append(("\(side)LowerArm", elbow))
                out.append(("\(side)Hand", hand))
            }
        }
        if let s = split(hips, chest)?.2.first, s != chest { out.append(("spine", s)) }
        let halfWidth = abs(pos[lh].x - pos[rh].x) * 0.5
        let top = joints.filter { abs(pos[$0].x) < halfWidth * 0.15 && pathUp($0).contains(chest) && $0 != chest }.lastMax {
            pos[$0].y
        }
        if let top, let (_, _, up) = split(chest, top) {
            let shoulderY = max(pos[lArm[0]].y, pos[rArm[0]].y)
            if let h = up.firstIndex(where: { pos[$0].y > shoulderY + height * 0.06 }) {
                out.append(("head", up[h]))
                if h > 0 { out.append(("neck", up[h - 1])) }
            }
        }
        return out
    }
}

import simd
