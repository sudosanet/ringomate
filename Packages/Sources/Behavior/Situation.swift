import MascotCore
import simd

extension Mascot {
    /// `always` はいつも言うこと、`extra` はしばらく変わらない背景。
    public func situationFacts(world: World, pointer: SIMD2<Float>, body: Body, agent: String, frontApp: String?,
                               frontTitle: String?, discordTitle: String?) -> (always: [String], extra: [String]) {
        var parts = basics(world: world)
        switch agent {
        case "done": parts.append("the task your owner asked for is done")
        case "failed": parts.append("your owner's task failed")
        case "thinking": parts.append("your owner's AI assistant is thinking")
        case "waitingPermission": parts.append("waiting for your owner's approval")
        case "working", "reading", "writing", "running": parts.append("your owner's AI assistant is working")
        default: break
        }
        if simd_length(pointer - (body.root + [0, body.height * 0.7])) < body.height * 1.5 { parts.append("your owner's cursor is right next to you") }
        if world.userIdleSeconds > 300 { parts.append("your owner has been away from the desk for a while") }
        if world.keepToCorner { parts.append("your owner is watching something in full screen, so you are staying quiet in the corner") }
        let env = world.env.describe(frontTitle: frontTitle, discordTitle: discordTitle)
        var extra = env.ambient
        if let frontApp { extra.append("your owner is using \"\(frontApp)\"") }
        return (parts + env.notable, extra)
    }

    /// 曲の話のときだけ渡す。状況を全部渡すと小さいモデルは曲の話をしない。
    /// 気分（眠いなど）は渡さない（自分の話になる）。曲の雰囲気はきっかけの文に入れる。
    public func songFacts(world: World) -> [String] {
        Array(basics(world: world).prefix(1)) + ["you are \(activityDescription)"]
    }

    private func basics(world: World) -> [String] {
        let hour = world.hour
        let s = summary
        return [hour < 5 ? "late at night" : hour < 11 ? "morning" : hour < 17 ? "daytime" : hour < 22 ? "evening" : "late at night",
                s.sleepy ? "you are sleepy" : s.energy < 0.35 ? "you are tired" : s.mood > 0.4 ? "you are in a great mood" : s.mood < -0.2 ? "you feel down" : "you feel okay"]
    }
}

extension MacEnvironment {
    var musicMoodFact: String? { musicMoodWord.map { "the music sounds \($0)" } }

    public var musicMoodWord: String? {
        guard let m = musicMood else { return nil }
        return switch m {
        case .cute: "cute"
        case .energetic: "energetic"
        case .chill: "chill"
        case .cool: "cool"
        case .sad: "bittersweet"
        }
    }

    /// ウィンドウのタイトルは画面収録の許可があるときだけ渡す。
    public func describe(frontTitle: String? = nil, discordTitle: String? = nil) -> (notable: [String], ambient: [String]) {
        var notable: [String] = []
        var parts: [String] = []
        let days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        parts.append(days[(weekday - 1 + 7) % 7])
        if let b = battery {
            let text = "the Mac's battery is at \(Int(b * 100))%\(charging ? " and charging" : "")"
            if lowBattery { notable.append(text) } else { parts.append(text) }
        }
        if heated { notable.append("the Mac is running hot") }
        if typingHard { notable.append("your owner is typing very fast") }
        // 曲は話の種になるので、ランダムに選ぶ側（ambient）でなく必ず渡す側に置く
        if let song = nowPlaying { notable.append("your owner is listening to \"\(song)\"") }
        else if audioPlaying { parts.append("sound is playing on the Mac") }
        if let m = musicMoodFact { notable.append(m) }
        if muted { parts.append("the sound is muted") }
        if !online { notable.append("not connected to the internet") }
        if dark { parts.append("the screen is in Dark Mode") }
        if let t = frontTitle { parts.append("the front window is \"\(t.prefix(60))\"") }
        if let d = discordTitle { parts.append("\"\(d.prefix(60))\" is open in Discord") }
        return (notable, parts)
    }
}
