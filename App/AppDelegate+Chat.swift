import Agent
import AppKit
import Behavior
import CoreBridge
import Engine
import CoreGraphics
import Overlay
import Render
import Settings
import AI
import Senses
import FoundationModels
import MascotCore
import os
import simd

extension AppDelegate {
    func tools(talking: Bool) -> [any Tool] {
        aiTools.begin()
        let working = sessions.focus().map { [.working, .reading, .writing, .running, .thinking, .delegating, .compacting].contains($0.state) } ?? false
        return aiTools.pick(working: working, music: lastWorld.env.beat != nil, talking: talking)
    }

    func chat(world: Mascot.World, pointer: SIMD2<Float>) {
        (lastWorld, lastPointer) = (world, pointer)
        let focus = sessions.focus()
        if ai.permissionChat, focus?.state == .waitingPermission, focus?.state != chatTriggers.lastState {
            mascot.permissionLine = nil
            let tool = focus?.toolName.map { " (\($0))" } ?? ""
            let scene = scene(focus)
            Task { [weak self] in
                guard let self, let line = await chatter.line(
                    for: "The AI assistant is asking your owner for permission\(tool). Ask your owner to check it", always: scene.always)
                else { return }
                if sessions.focus()?.state == .waitingPermission { mascot.permissionLine = line }
            }
        }
        guard ai.maySpeak(), mascot.canSpeak else {
            chatTriggers.observe(state: focus?.state)
            return
        }
        let front = ai.appName ? NSWorkspace.shared.frontmostApplication?.localizedName : nil
        guard let (reason, urgent, focused) = chatTriggers.next(state: focus?.state, idleSeconds: world.userIdleSeconds,
                                                                frontApp: front == "RingoMate" ? nil : front,
                                                                song: world.env.nowPlaying, sound: world.env.musicMoodWord,
                                                                songNotes: songNotes(world: world)) else { return }
        let scene = focused ? (always: mascot.songFacts(world: world), extra: []) : scene(focus)
        let look = urgent || focused ? nil : frontWindowToLook()
        Task { [weak self] in
            // 前面のウィンドウを 1 枚だけ見る（保存しない）。
            let image: CGImage? = if let look { await captureWindow(number: look) } else { nil }
            guard let self, let line = await chatter.line(for: reason, always: scene.always, extra: scene.extra, image: image)
            else { return }
            voice.say(line, seconds: SpeechLanguage.readingSeconds(line), scene: .chatter)
        }
    }

    /// 曲について今言えること（数字は言葉にする。数字を渡すと読み上げる）。
    func songNotes(world: Mascot.World) -> [String] {
        guard world.env.nowPlaying != nil else { return [] }
        var notes: [String] = []
        if let bpm = world.env.beat?.bpm {
            if bpm >= 140 { notes.append("the song has a fast tempo") } else if bpm <= 95 { notes.append("the song has a slow tempo") }
        }
        if let bar = beats.bar, bar.section > 0, bar.barsSince < 4, bar.intensity > 0.75 {
            notes.append("the chorus, the most exciting part of the song, just started")
        }
        if let p = songService.progress {
            if p.time < 30 { notes.append("the song just started") } else if p.length > 60, p.length - p.time < 30 { notes.append("the song is almost over") }
        }
        if mascot.isDancing { notes.append("you are dancing to this song") }
        return notes
    }

    func frontWindowToLook() -> CGWindowID? {
        guard ai.lookAtScreen, chatter.canSee, canCapture, Date().timeIntervalSince(lastLook) > ai.lookInterval,
              let app = NSWorkspace.shared.frontmostApplication,
              mayLook(atApp: app.bundleIdentifier, extra: ai.neverLook),
              let window = overlay?.windows.first(where: { $0.pid == app.processIdentifier }) else { return nil }
        lastLook = Date()
        return CGWindowID(window.number)
    }

    func scene(_ focus: Sessions.Session?) -> (always: [String], extra: [String]) {
        let front = ai.appName ? NSWorkspace.shared.frontmostApplication?.localizedName : nil
        var (always, extra) = mascot.situationFacts(world: lastWorld, pointer: lastPointer, body: body,
                                                    agent: focus.map { "\($0.state)" } ?? "none", frontApp: front,
                                                    frontTitle: frontTitle, discordTitle: discordTitle)
        if let f = focus {
            var agent: [String] = []
            let project = URL(filePath: f.cwd).lastPathComponent
            if !project.isEmpty { agent.append("the project being worked on is \"\(project)\"") }
            if let doing = f.doing { agent.append("the AI assistant is \(doing) right now") }
            agent += f.actions.prefix(2).map { "a moment ago the AI assistant \($0)" }
            if f.state.busy { agent.append("the AI assistant's work has no result yet") }
            if f.state.busy || [.done, .failed, .waitingPermission].contains(f.state) { always += agent } else { extra += agent }
        }
        extra.append("you are \(mascot.activityDescription)")
        if let (e, at) = lastHeard, Date().timeIntervalSince(at) < 60 { always.append("you just heard \(e.label) from the Mac") }
        extra += lastWorld.things.prefix(2).map { "there is a \($0.name) on the screen" }
        if ai.style.memory, !conversation.summary.isEmpty { extra.append("what you have talked about with your owner: \(conversation.summary.prefix(80))") }
        return (always, extra)
    }

    func speak(_ reason: String, fallback: String) {
        Task { [weak self] in
            guard let self else { return }
            let scene = scene(sessions.focus())
            let line = await chatter.line(for: reason, always: scene.always, extra: scene.extra)
            voice.say(line ?? fallback, seconds: 3, scene: .notification)
        }
    }

    func talk(_ text: String) async -> String {
        guard overlay?.isVisible != false else { return String(localized: "RingoMate is hidden") }
        let hour = Calendar.current.component(.hour, from: Date())
        let (faceOn, strength) = (ai.faceFromReply, ai.faceStrength)
        let face: @MainActor ([String: Float]) -> Void = { [mascot] w in
            guard faceOn else { return }
            let w = w.mapValues { min($0 * strength, 1) }
            var weights: [Mascot.Expression: Float] = [:]
            for e in Mascot.Expression.allCases { if let v = w["\(e)"] { weights[e] = v } }
            mascot.express(weights: weights, seconds: 6)
        }
        conversation.tools = { [weak self] in self?.tools(talking: true) ?? [] }
        // 会話にも、独り言と同じ必ず渡す状況（曲・作業の様子など）を渡す
        let facts = scene(sessions.focus()).always
        let context = (["It is \(hour):00", mascot.summary.activity] + facts).joined(separator: "; ")
        guard let r = await conversation.reply(to: text, context: context, onFace: face) else {
            let fallback = String(localized: "Mm-hmm, I'm listening.")
            voice.say(fallback, scene: .reply)
            return fallback
        }
        voice.say(r.text, seconds: SpeechLanguage.readingSeconds(r.text), scene: .reply)
        face(r.expressionWeights)
        return r.text
    }

    @objc func talkFromMenu() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Talk")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Say"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
        let text = field.stringValue
        Task { _ = await talk(text) }
    }
}
