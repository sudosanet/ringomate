import simd

extension PropKind {
    /// 握った指の内側への寄せと下への寄せ（身長に対する比）。
    var gripOffset: (Float, Float) {
        switch self {
        case .mug: (0.016, 0.02)
        case .bottle: (0.012, 0.035)
        default: (0.006, 0)
        }
    }

    /// 身長に対する比。
    var puff: Float {
        switch self {
        case .phone, .toothbrush, .comb, .paintbrush, .lollipop: 0.1
        case .book, .mug, .bottle, .iceCream, .onigiri, .flower, .fan, .magnifier, .camera, .controller: 0.13
        case .headphones, .teddy, .carry: 0.2
        case .balloon, .umbrella: 0.26
        case .chair, .rug: 0.32
        }
    }
}

struct PropPlacement {
    struct Request {
        var slot: Slot
        var held: Bool
        var puttingAwayPhone: Bool
        var handProp: PropKind?
        var rightKnuckles: SIMD3<Float>?
    }

    struct Prop {
        var kind: PropKind, bone: Int, rest: SIMD3<Float>
        var shown: SIMD3<Float>?
        var pocket = false
    }

    static let away = SIMD3<Float>(0, -1.0e4, 0)

    var list: [Prop]
    var wrists: [Int?]
    var knuckles: [Int?]
    private(set) var height: Float
    var seat: SIMD3<Float>?
    var rug: SIMD3<Float>?

    init(_ list: [(PropKind, Int, SIMD3<Float>)], wrists: [Int?], knuckles: [Int?], height: Float) {
        self.list = list.map { Prop(kind: $0.0, bone: $0.1, rest: $0.2) }
        (self.wrists, self.knuckles, self.height) = (wrists, knuckles, height)
    }

    static func position(_ b: Int?, _ world: [simd_float4x4]) -> SIMD3<Float>? {
        guard let b, b < world.count else { return nil }
        return world[b].columns.3.xyz
    }

    func rightKnuckles(_ world: [simd_float4x4]) -> SIMD3<Float>? {
        guard let a = Self.position(knuckles[0], world), let b = Self.position(knuckles[1], world) else { return nil }
        return a - b
    }

    func wristPositions(_ world: [simd_float4x4]) -> [SIMD3<Float>?] {
        let w = wrists.map { Self.position($0, world) }
        return [w[0], w[1], w[2] ?? w[0], w[3] ?? w[1]]
    }

    func hide(_ pose: inout Pose) {
        for p in list { pose.localOffsets[p.bone] = Self.away }
    }

    mutating func place(_ want: Request, wrists: [SIMD3<Float>?], head: SIMD3<Float>?, pose: inout Pose) -> [(SIMD3<Float>, Float)] {
        let h = height
        var heldInHands: (SIMD3<Float>, SIMD3<Float>)?
        if let l = wrists[2], let r = wrists[3], let hd = head {
            let mid = (l + r) / 2
            heldInHands = (mid, Math.normalize(hd - mid, or: SIMD3(0, 0, 1)))
        }
        var rightHand: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)?
        if let w = wrists[1], let f = wrists[3] {
            let dir = Math.normalize(f - w, or: SIMD3(0, -1, 0))
            let up = want.rightKnuckles.map { $0 - dir * simd_dot(dir, $0) }.flatMap(Math.tryNormalize)
                ?? Math.normalize(SIMD3(0, 1, 0) - dir * dir.y, or: SIMD3(0, 1, 0))
            let inward = simd_cross(dir, up)
            rightHand = (Math.lerp(w, f, 0.6), up, inward)
        }
        var puffs: [(SIMD3<Float>, Float)] = []
        for i in list.indices {
            let kind = list[i].kind
            if let grip = kind.grip {
                var at: SIMD3<Float>?
                if want.handProp == kind {
                    switch grip {
                    case .rightHand:
                        at = rightHand.map { a, up, inward in
                            let (r, down) = kind.gripOffset
                            return a + inward * h * r - up * h * down
                        }
                    case .bothHands: at = heldInHands?.0
                    case .head: at = head.map { $0 + SIMD3(0, 1, 0) * h * 0.06 }
                    }
                }
                let spin: simd_quatf
                switch (grip, kind) {
                case (.rightHand, .fan), (.rightHand, .magnifier):
                    spin = heldInHands.map { _, face in
                        Math.rotationArc(SIMD3(0, 0, 1), Math.normalize(SIMD3(face.x, 0, face.z), or: SIMD3(0, 0, 1)))
                    } ?? Math.identity
                case (.rightHand, _):
                    spin = rightHand.map { _, up, inward in
                        let x = -inward
                        return simd_normalize(Math.rotationAxes(x, up, simd_cross(x, up)))
                    } ?? Math.identity
                case (.bothHands, .camera): spin = Math.identity
                default: spin = Math.rotY(Float.pi)
                }
                if at == nil, let from = list[i].shown { puffs.append((from, h * kind.puff)) }
                list[i].shown = at
                pose.localOffsets[list[i].bone] = at.map { $0 - list[i].rest } ?? Self.away
                pose.localRotations[list[i].bone] = spin
                continue
            }
            let sitting: Bool = switch want.slot {
            case .sitDown, .sit, .sitRead, .sitSwing, .standUp: !want.held
            default: false
            }
            var at: SIMD3<Float>?
            switch kind {
            case .chair: at = sitting ? seat : nil
            case .rug: at = want.slot == .hug ? rug : nil
            case .carry:
                if want.slot == .walkCarry, let l = wrists[0], let r = wrists[1] { at = (l + r) / 2 }
            case .phone:
                if want.slot == .idlePhone, let (mid, _) = heldInHands, let l = wrists[2], let r = wrists[3] {
                    let together = Math.clamp((h * 0.3 - simd_distance(l, r)) / (h * 0.15), 0, 1)
                    at = Math.lerp(r, mid, together)
                } else if want.slot != .idlePhone, let r = wrists[3], want.puttingAwayPhone, list[i].shown != nil {
                    list[i].pocket = true
                    at = r
                }
            case .book: at = want.slot == .sitRead ? heldInHands?.0 : nil
            default: break
            }
            func upright(_ face: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
                let up = Math.normalize(SIMD3(0, 1, 0) - face * simd_dot(SIMD3(0, 1, 0), face), or: SIMD3(0, 1, 0))
                return (face, up)
            }
            var spin = Math.identity
            if kind == .phone || kind == .book, let (_, face) = heldInHands {
                let (n, up) = upright(face)
                spin = Math.rotationAxes(simd_cross(up, -n), up, -n)
            }
            if at == nil {
                let pocket = list[i].pocket
                list[i].pocket = false
                if !pocket, let from = list[i].shown { puffs.append((from + SIMD3(0, 1, 0) * h * 0.05, h * kind.puff)) }
            }
            list[i].shown = at
            pose.localOffsets[list[i].bone] = at.map { $0 - list[i].rest } ?? Self.away
            pose.localRotations[list[i].bone] = spin
        }
        return puffs
    }
}
