import MascotCore
import simd

extension Mascot {
    func actDancing(_ c: ActContext, move: DanceMove, moveLeft: Float, left: Float, intent: inout Intent, target: inout [Float]) {
        let (dt, body, world) = (c.dt, c.body, c.world)
        intent.beat = world.env.beat
        if move == .song {
            actSongDance(c, left: left, intent: &intent, target: &target)
            return
        }
        switch move {
        case let .move(i):
            intent.motion = .dance(UInt16(clamping: i))
            if world.env.beat?.beatInBar != nil { intent.beat?.clip = Float(danceBeats) + (world.env.beat?.phase ?? 0) }
        case let .recorded(i):
            intent.motion = .gesture(UInt8(clamping: i))
        case .waiting, .song:
            intent.motion = .idle
        }
        intent.look = nil
        lastBeatInBar = world.env.beat?.beatInBar
        danceFace(phase: world.env.beat?.phase ?? 0, target: &target)
        let phase = world.env.beat?.phase ?? 0
        let newBeat = world.env.beat != nil && phase < lastDancePhase - 0.5
        lastDancePhase = phase
        if newBeat { danceBeats += 1 }
        // 混ぜる 0.4 秒の真ん中が 1 拍目に来るよう、0.2 秒前に替え始める
        let inBar = world.env.beat?.beatInBar
        let meter = world.env.beat?.meter ?? 4
        let downbeat = newBeat && inBar == 0
        let lead = 0.2 * (world.env.beat?.bpm ?? 120) / 60
        let nearDownbeat = inBar == meter - 1 && phase >= 1 - lead && danceBeats >= 0
        if downbeat { phraseBars += 1 }
        if let section = world.env.beat?.section, section != danceSection {
            danceSection = section
            sectionChanged = true
        }
        if let turn = danceTurn {
            let progress = (Float(danceBeats - turn.start) + phase) / turn.beats
            let u = min(max(progress, 0), 1)
            let e = u * u * u * (u * (u * 6 - 15) + 10)
            danceFacing = turn.from + (turn.to - turn.from) * e
            if progress >= 1 {
                danceTurn = nil
                let full = Float.pi * 2
                if abs(danceFacing) >= full - 0.01 {
                    let shift = danceFacing > 0 ? full : -full
                    danceFacing -= shift
                    facing -= shift
                }
            }
        }
        intent.facing = danceFacing
        if case .move = move, danceLegs == .hop, let beat = world.env.beat, (inBar ?? danceBeats) % 2 == 1,
           lastHopPhase < 0.45, phase >= 0.45, body.grounded {
            // 重力 122/s² で空中 0.55 拍（2・4 拍目だけ跳ぶ）
            intent.hop = min(20, 122 * 0.55 * 60 / max(beat.bpm, 60) / 2)
        }
        lastHopPhase = phase
        let l = left - dt
        let musicGone = world.env.beat == nil
        if l <= 0 || musicGone {
            danceRest = musicGone ? 0 : 4 + random() * 4
            activity = .standing(left: musicGone ? 4 + random() * 6 : danceRest)
        } else if case .recorded = move, body.motionDone || moveLeft - dt <= 0 {
            activity = inBar == nil ? nextDance(world: world, left: l) : .dancing(move: .waiting, moveLeft: 0, left: l)
        } else if case .waiting = move, inBar == nil {
            activity = nextDance(world: world, left: l)
        } else if case .waiting = move, nearDownbeat {
            activity = nextDance(world: world, left: l)
            danceBeats = -1
        } else if case .move = move, inBar != nil, nearDownbeat,
                  danceBeats + 1 >= Int(moveLeft) || sectionChanged,
                  (danceBeats + 1) % (danceLegs?.twoBars == true ? 2 * meter : meter) == 0 {
            activity = nextDance(world: world, left: l)
            danceBeats = -1
        } else if case .move = move, inBar == nil, newBeat, danceBeats % 4 == 0, danceBeats >= Int(moveLeft) {
            activity = nextDance(world: world, left: l)
        } else {
            activity = .dancing(move: move, moveLeft: moveLeft - (move.isRecorded ? dt : 0), left: l)
        }

    }

    func actSongDance(_ c: ActContext, left: Float, intent: inout Intent, target: inout [Float]) {
        let beat = c.world.env.beat
        intent.look = nil
        guard let song = c.world.env.song, let index = songDances[song.id] else {
            danceBeats = 0
            let l = max(left - c.dt, 20)
            activity = beat == nil ? .standing(left: 4 + random() * 6)
                : beat?.beatInBar != nil ? .dancing(move: .waiting, moveLeft: 0, left: l) : nextDance(world: c.world, left: l)
            return
        }
        intent.motion = .dance(UInt16(clamping: index))
        intent.song = song
        danceFacing += (0 - danceFacing) * min(1, c.dt * 4)
        intent.facing = danceFacing
        lastDancePhase = beat?.phase ?? 0
        lastBeatInBar = beat?.beatInBar
        danceMood = Int(song.clipTime / 8) % 6
        danceFace(phase: beat?.phase ?? song.clipTime.truncatingRemainder(dividingBy: 0.5) * 2, target: &target)
        activity = .dancing(move: .song, moveLeft: 0, left: left - c.dt)
    }

    func danceFace(phase: Float, target: inout [Float]) {
        func set(_ e: Expression, _ w: Float) { target[e.rawValue] = max(target[e.rawValue], w) }
        if phase < facePhase - 0.5 { faceBeat += 1 }
        facePhase = phase
        let roll = { (n: Int, salt: Int) -> Float in
            var x = UInt64(truncatingIfNeeded: n) &* 0x9E37_79B9_7F4A_7C15 ^ UInt64(salt) &* 0xBF58_476D_1CE4_E5B9
            x ^= x >> 31
            return Float(x % 10_000) / 10_000
        }
        let beat = lastBeatInBar ?? danceBeats % 4
        let hit = max(0, cos(phase * .pi * 2))
        let singing = lips?.contains { $0 > 0.05 } ?? false
        switch danceMood {
        case 0:
            set(.smile, 0.45); if !singing { set(.mouthOpen, 0.25 + 0.3 * hit) }
        case 1:
            set(.calm, 0.45); set(.smile, 0.35); if !singing { set(.mouthOpen, 0.1) }
        case 2:
            set(.smile, 0.45)
            if beat % 2 == 1 { set(.wink, hit) }
            if !singing { set(.mouthOpen, 0.2) }
        case 3:
            let vowels: [Expression] = [.mouthOpen, .mouthI, .mouthU, .mouthE, .mouthO]
            if !singing { set(vowels[(danceBeats + 5) % 5], 0.35 + 0.35 * hit) }
            set(.smile, 0.4)
        case 4:
            set(.smile, 0.3); if !singing { set(.mouthI, 0.2) }
        default:
            set(.smile, 0.45); set(.surprise, 0.25); set(.blush, 0.4); if !singing { set(.mouthOpen, 0.3 * hit) }
        }
        let phrase = faceBeat / 16
        let serious = roll(phrase, 1) < (danceMood == 4 || danceMood == 1 ? 0.7 : 0.4)
        set(serious ? .browSerious : .browJoy, 0.75)
        if beat % 2 == 1, roll(faceBeat, 2) < 0.75 { set(.browDown, 0.5 * sin(min(phase, 0.999) * .pi)) }
        if faceBeat % 8 < 2, roll(faceBeat / 8, 3) < 0.9, faceBeat % 8 == 0 || phase < 0.5 { set(.smile, 1) }
        if let turn = danceTurn, abs(turn.to - turn.from) > 3 {
            set(.surprise, 0.5); set(.mouthO, 0.4)
        }
        if beat == 0, (danceBeats / 4 + danceMood) % 5 == 0 { set(.wink, hit) }
        if danceLegs == .hop, beat % 2 == 0 { set(.smile, 0.6 + 0.4 * hit); set(.mouthOpen, 0.4 * hit) }
    }

    func nextDance(world: World, left: Float) -> Activity {
        danceBeats = 0
        let beat = world.env.beat
        let barKnown = beat?.beatInBar != nil
        let meter = beat?.meter ?? 4
        let newSection = sectionChanged
        if sectionChanged {
            sectionChanged = false
            phraseBars = 0
        }
        let phraseStart = !barKnown || newSection || phraseBars % 8 == 0
        let back = abs(danceFacing - .pi) < 0.1
        let r = phraseStart ? random() : 1
        if back, r < 0.6 {
            danceTurn = (start: 0, from: danceFacing, to: 0, beats: 1)
        } else if r < 0.18 {
            let dir: Float = random() < 0.5 ? 1 : -1
            danceTurn = (start: 0, from: danceFacing, to: danceFacing + dir * .pi * 2, beats: 2)
        } else if !back, r < 0.3 {
            danceTurn = (start: 0, from: danceFacing, to: .pi, beats: 1)
        }
        if random() > 0.9 {
            let i = pickGesture(contents: Self.inPlaceDances)
            return .dancing(move: .recorded(i), moveLeft: 8, left: left)
        }
        let bpm = world.env.beat?.bpm ?? 110
        let energy = barKnown ? max(beat?.intensity ?? 0.5, (beat?.energy ?? 0.5) * 0.6) : beat?.energy ?? 0.5
        let scene = meter == 3 ? 0 : energy >= 0.65 ? 2 : energy >= 0.35 || bpm >= 128 ? 1 : 0
        let quiet: [DanceLegs] = [.sway, .rock, .bounce, .hipRoll, .tiptoe, .twist]
        let verse: [DanceLegs] = [.stepTouch, .kneePop, .twoStep, .boxStep, .vStep, .heelToe, .point, .cross, .chacha, .heelTap]
        let chorus: [DanceLegs] = [.kick, .hop, .sideStep, .kickBallChange, .charleston, .grapevine, .march, .twoStep, .kneePop, .heelTap]
        let waltz: [DanceLegs] = [.sway, .bounce, .twist, .rock, .hipRoll]
        // ウィンドウの上では足元を固定しているので跳べない
        let pool = (meter == 3 ? waltz : [quiet, verse, chorus][scene]).filter { perch == nil || $0 != .hop }
        let keepLegs = !newSection && danceLegs.map { pool.contains($0) } == true && random() < 0.5
        var legs = keepLegs ? danceLegs! : pool.filter { $0 != danceLegs }[min(Int(random() * Float(pool.count - 1)), pool.count - 2)]
        if danceTurn != nil, meter != 3 { legs = .march }
        let cuteWeight: Float = needs.cheerful ? 0.6 : 0.4
        var kinds: [([DanceArms], Float)] = switch scene {
        case 2: [(DanceArms.energetic, 1 - cuteWeight), (DanceArms.cute, cuteWeight)]
        case 1: [(DanceArms.cute, cuteWeight + 0.1), (DanceArms.calm, 0.25), (DanceArms.cool, 0.25)]
        default: [(DanceArms.calm, needs.energy < 0.4 ? 0.7 : 0.55), (DanceArms.cute, cuteWeight)]
        }
        let moodKind: [DanceArms]? = switch world.env.musicMood {
        case .cute: DanceArms.cute
        case .energetic: DanceArms.energetic
        case .chill, .sad: DanceArms.calm
        case .cool: DanceArms.cool
        case nil: nil
        }
        if let moodKind { kinds.append((moodKind, 1.0)) }
        var pick = random() * kinds.reduce(0) { $0 + $1.1 }
        let kind = kinds.first { pick -= $0.1; return pick <= 0 }?.0 ?? DanceArms.cute
        var arms = kind.filter { !recentArms.contains($0) }
        if arms.isEmpty { arms = kind }
        let a = arms[min(Int(random() * Float(arms.count)), arms.count - 1)]
        danceLegs = legs
        let moodFaces: [Int] = switch world.env.musicMood {
        case .cute: [0, 2]
        case .energetic: [5, 0]
        case .chill: [1, 3]
        case .sad: [1]
        case .cool: [4]
        case nil: []
        }
        let fitting = moodFaces.filter { $0 != danceMood }
        if !fitting.isEmpty, random() < 0.5 {
            danceMood = fitting[min(Int(random() * Float(fitting.count)), fitting.count - 1)]
        } else {
            danceMood = (danceMood + 1 + Int(random() * 5)) % 6
        }
        recentArms = Array((recentArms + [a]).suffix(3))
        let bars = scene == 2 ? (random() < 0.75 ? 4 : 8) : (random() < 0.5 ? 4 : 8)
        return .dancing(move: .move(legs.rawValue * DanceArms.allCases.count + a.rawValue), moveLeft: Float(bars * meter), left: left)
    }

    static let inPlaceDances: Set<String> = ["macarena", "chicken-dance", "dance-long", "dancing", "lambada"]
}
