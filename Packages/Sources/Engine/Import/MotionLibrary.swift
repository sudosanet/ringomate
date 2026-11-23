import Foundation

enum MotionLibrary {
    static let librarySlots: [(Slot, String)] = [
        (.idle, "Idle_Loop"), (.fall, "Jump_Loop"), (.falling, "Jump_Loop"), (.thrown, "Jump_Loop"), (.land, "Jump_Land"),
        (.walk, "Walk_Formal_Loop"), (.sitDown, "Sitting_Enter"), (.sit, "Sitting_Idle_Loop"), (.standUp, "Sitting_Exit"),
    ]
    static let ual2Slots: [(Slot, String)] = [(.walkCarry, "Walk_Carry_Loop")]

    static func isDance(_ name: String) -> Bool { ["dance", "macarena", "lambada"].contains { name.contains($0) } }

    static func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    static func bake(_ model: LoadedModel, library: URL?, progress: (Float) -> Void = { _ in }) throws -> [(Slot, BakedClip)] {
        guard let lib = library else { return [] }
        var out: [(Slot, BakedClip)] = []
        let (skel, clips) = try SourceClip.loadGLB([UInt8](Data(contentsOf: lib)))
        for (slot, name) in librarySlots {
            guard let clip = clips.first(where: { $0.name == name }) else { continue }
            var o = Retarget.Options()
            switch slot {
            case .fall: o.shoulderAdduct = SIMD2(repeating: Math.radians(45))
            case .falling: o.shoulderAdduct = SIMD2(repeating: Math.radians(-20))
            case .land:
                o.upright = 0.4
                o.shoulderAdduct = SIMD2(repeating: Math.radians(30))
            default: break
            }
            out.append((slot, Retarget.bake(skel, clip, model.pmx, model.profile.aliases, o)))
        }
        let root = lib.deletingLastPathComponent().deletingLastPathComponent()
        progress(0.1)
        out += bandai(root, model)
        progress(0.3)
        func gestures() -> UInt8 { UInt8(out.filter { if case .gesture = $0.0 { true } else { false } }.count) }
        let ual2 = ual2Motions(root, model, firstGesture: gestures())
        out.removeAll { s in ual2.contains { $0.0 == s.0 } }
        out += ual2
        progress(0.4)
        out += bandaiLibrary(root, model, first: gestures())
        progress(0.7)
        out += cmuLibrary(root, model, first: gestures())
        return out
    }

    static func ual2Motions(_ root: URL, _ model: LoadedModel, firstGesture: UInt8) -> [(Slot, BakedClip)] {
        guard let data = try? Data(contentsOf: root.appending(path: "ual2/UAL2_Standard.glb")),
              let (skel, clips) = try? SourceClip.loadGLB([UInt8](data)) else { return [] }
        func bake(_ name: String) -> BakedClip? {
            clips.first { $0.name == name }.map { Retarget.bake(skel, $0, model.pmx, model.profile.aliases) }
        }
        var out: [(Slot, BakedClip)] = ual2Slots.compactMap { slot, name in bake(name).map { (slot, $0) } }
        if var yes = bake("Yes") {
            yes.name = "nod:normal"
            out.append((.gesture(firstGesture), yes))
        }
        return out
    }

    static func styleName(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "_", omittingEmptySubsequences: false)
        return parts.count >= 3 ? "\(parts[1]):\(parts[2])" : stem
    }

    static func bandai(_ root: URL, _ model: LoadedModel) -> [(Slot, BakedClip)] {
        let dir = root.appending(path: "bandai/dataset")
        func d1(_ f: String) -> URL { dir.appending(path: "Bandai-Namco-Research-Motiondataset-1/data/\(f)") }
        func d2(_ f: String) -> URL { dir.appending(path: "Bandai-Namco-Research-Motiondataset-2/data/\(f)") }
        func bake(_ s: SourceSkeleton, _ c: SourceClip, _ o: Retarget.Options = .init()) -> BakedClip {
            Retarget.bake(s, c, model.pmx, model.profile.aliases, o)
        }
        var out: [(Slot, BakedClip)] = []
        var walk = Retarget.Options()
        walk.armAdduct = Math.radians(15)
        walk.cycleFeet = true
        for (file, name, slot) in [("dataset-1_walk_happy_001.bvh", "walk", Slot.walk), ("dataset-1_walk_feminine_001.bvh", "walk-calm", .walkCalm)] {
            if let text = read(d1(file)), let (s, c) = try? BVH.loadWalkCycle(text, name: name) { out.append((slot, bake(s, c, walk))) }
        }
        if let text = read(d1("dataset-1_bye_feminine_001.bvh")), let (s, c) = try? BVH.loadGesture(text, name: "wave", trim: .handsUp, maxSeconds: 3) {
            var o = Retarget.Options()
            o.shoulderAdduct = SIMD2(Math.radians(25), 0)
            out.append((.wave, bake(s, c, o)))
        }
        if let text = read(d2("dataset-2_raise-up-both-hands_exhausted_001.bvh")),
           let (s, c) = try? BVH.loadGesture(text, name: "stretch", trim: .handsUp, maxSeconds: 5) {
            out.append((.stretch, bake(s, c)))
        }
        let gestures: [(URL, BVH.Trim, Float)] = [
            (d1("dataset-1_byebye_happy_001.bvh"), .handsUp, 3.5), (d1("dataset-1_bow_happy_001.bvh"), .bow, 3),
            (d1("dataset-1_call_normal_001.bvh"), .handsUp, 3), (d1("dataset-1_respond_normal_001.bvh"), .handsUp, 3),
            (d2("dataset-2_wave-both-hands_youthful_001.bvh"), .handsUp, 3.5),
            (d2("dataset-2_raise-up-both-hands_youthful_001.bvh"), .handsUp, 3),
            (d1("dataset-1_dance-short_normal_001.bvh"), .active, 6),
        ]
        var n: UInt8 = 0
        for (url, trim, max) in gestures {
            guard let text = read(url), let (s, c) = try? BVH.loadGesture(text, name: styleName(url), trim: trim, maxSeconds: max)
            else { continue }
            var baked = bake(s, c)
            if isDance(styleName(url)) { baked.stayInPlace(1.5) }
            out.append((.gesture(n), baked))
            n += 1
        }
        return out
    }

    static func bandaiLibrary(_ root: URL, _ model: LoadedModel, first: UInt8) -> [(Slot, BakedClip)] {
        let contents = ["bow", "bye", "byebye", "call", "dance-long", "dance-short", "guide", "respond", "raise-up-both-hands",
                        "raise-up-left-hand", "raise-up-right-hand", "wave-both-hands", "wave-left-hand", "wave-right-hand"]
        guard let text = read(root.appending(path: "bandai.toml")), let table = try? TOML.parse(text) else { return [] }
        var files = (table["files"]?.array ?? []).compactMap(\.string).map { root.appending(path: "bandai/\($0)") }.filter { url in
            url.pathExtension == "bvh" && styleName(url).split(separator: ":").first.map { contents.contains(String($0)) } == true
        }
        files.sort { $0.path < $1.path }
        var out: [(Slot, BakedClip)] = []
        for url in files.prefix(max(255 - Int(first), 0)) {
            let name = styleName(url)
            let content = name.split(separator: ":").first.map(String.init) ?? ""
            let (trim, max): (BVH.Trim, Float) = content == "bow" ? (.bow, 4) : content.hasPrefix("dance") ? (.active, 6) : (.handsUp, 4)
            guard let text = read(url), let (s, c) = try? BVH.loadGesture(text, name: name, trim: trim, maxSeconds: max) else { continue }
            var baked = Retarget.bake(s, c, model.pmx, model.profile.aliases)
            if isDance(name) { baked.stayInPlace(1.5) }
            out.append((.gesture(first + UInt8(out.count)), baked))
        }
        return out
    }

    static func cmuLibrary(_ root: URL, _ model: LoadedModel, first: UInt8) -> [(Slot, BakedClip)] {
        let dir = root.appending(path: "cmu")
        guard let text = read(root.appending(path: "cmu.toml")), let table = try? TOML.parse(text),
              let gestures = table["gestures"]?.table else { return [] }
        let order = (table["files"]?.array ?? []).compactMap(\.string).filter { gestures[$0] != nil }
        var out: [(Slot, BakedClip)] = []
        for file in order.prefix(max(255 - Int(first), 0)) {
            guard let name = gestures[file]?.string, let text = read(dir.appending(path: file)),
                  let (s, c) = try? BVH.loadActiveSection(text, name: name, maxSeconds: 5) else { continue }
            var baked = Retarget.bake(s, c, model.pmx, model.profile.aliases)
            if isDance(name) { baked.stayInPlace(1.5) }
            out.append((.gesture(first + UInt8(out.count)), baked))
        }
        return out
    }
}
