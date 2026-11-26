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
import FoundationModels
import MascotCore
import os
import simd
import Listen
import Senses

extension AppDelegate {
    func agent(ledges: [OverlayController.Ledge]) -> Mascot.Agent {
        guard let s = sessions.focus(), let overlay else { return .init() }
        let window = locator.window(for: s, in: overlay.windows)
        if loggedTerminal != .some(window) {
            loggedTerminal = .some(window)
            log.notice("terminal window for \(s.terminal ?? "-", privacy: .private) \(s.cwd, privacy: .private): \(window.map(String.init) ?? "none", privacy: .public) (ledge: \(ledges.contains { $0.id == window }))")
        }
        let index = overlay.windows.firstIndex { $0.number == window }
        let front = index.map { overlay.windows[..<$0].map(\.frame) } ?? []
        let frame = index.flatMap { i -> CGRect? in
            let f = overlay.windows[i].frame
            return visibleFraction(of: f, under: front) > 1.0 / 3 ? f : nil
        }
        let ppu = overlay.pointsPerUnit
        let screen = overlay.currentScreen
        let left = screen?.frame.minX ?? 0
        let groundY = (NSScreen.screens.first?.frame.height ?? 0) - (screen?.visibleFrame.minY ?? 0)
        let feet = CGRect(x: -CGFloat.greatestFiniteMagnitude / 2, y: groundY - CGFloat(overlay.characterHeight),
                          width: .greatestFiniteMagnitude, height: CGFloat(overlay.characterHeight))
        let blocked = front.filter { $0.intersects(feet) }.map { Float($0.minX - left) / ppu...Float($0.maxX - left) / ppu }
        return .init(state: s.state, surfaceID: ledges.contains { $0.id == window } ? window : nil,
                     window: frame.map { Float($0.minX - left) / ppu...Float($0.maxX - left) / ppu }, blocked: blocked)
    }

    func bringTerminalToFront(_ s: Sessions.Session) {
        let window = overlay.flatMap { o in locator.window(for: s, in: o.windows).flatMap { n in o.windows.first { $0.number == n } } }
        let app = window.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
            ?? TerminalLocator.owner(for: s.terminal).flatMap { name in
                NSWorkspace.shared.runningApplications.first { $0.localizedName == name }
            }
        app?.activate()
    }

    func frame(dt: Float, pointer: OverlayController.Pointer, skin: UnsafeMutableRawBufferPointer,
                       positions: UnsafeMutableRawBufferPointer) -> OverlayController.FrameResult {
        let hour = Calendar.current.component(.hour, from: Date())
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        renderer?.night = switch rampMode {
        case "day": false
        case "night": true
        default: dark || hour >= 20 || hour < 6
        }
        let ledges = overlay?.ledges ?? []
        if ledges.map(\.id) != loggedLedges {
            loggedLedges = ledges.map(\.id)
            let list = ledges.map { "\($0.id)@x\(Int($0.minX))-\(Int($0.maxX)) top \(Int($0.top))" }.joined(separator: ", ")
            log.info("ledges: \(list, privacy: .public)")
        }
        var world = Mascot.World(
            surfaces: ledges.map {
                .init(id: $0.id, minX: $0.minX, maxX: $0.maxX, top: $0.top, bottom: $0.bottom,
                      climbLeft: $0.climbLeft, climbRight: $0.climbRight)
            },
            width: overlay?.stageWidth ?? 100,
            userIdleSeconds: CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: Self.anyInput),
            hour: Calendar.current.component(.hour, from: Date()),
            keepToCorner: fullScreenMode == "corner" && overlay?.fullScreenActive == true,
            exitLeft: overlay?.exits.left == true, exitRight: overlay?.exits.right == true
        )
        world.env = environment(dark: dark)
        if let overlay {
            let findThings = ai.findThings && chatter.canSee
            let wantsColor = (renderer?.wallpaperTint ?? 0) > 0
            if findThings || wantsColor {
                desktopThings.tick(screen: overlay.currentScreen, ppu: overlay.pointsPerUnit, findThings: findThings,
                                   allowed: { [canCapture] in canCapture })
            }
            desktopThings.apply(to: &world, windows: overlay.windows)
            freeSpace.apply(to: &world, enabled: ai.avoidBusyScreen && !overlay.hiddenForFullScreen && canCapture)
            if renderer?.wallpaperColor != desktopThings.color { renderer?.wallpaperColor = desktopThings.color }
        }
        world.env.beat = beatClock.beat()?.advanced(by: stepHere ? 0 : dt)
        world.env.song = songService.tick(hasAudio: beats.hasRecentAudio(seconds: 8), audio: { beats.recentAudio(seconds: 8) },
                                          now: BeatTracker.now(),
                                          ahead: Double(stepHere ? 0 : dt))
        if let song = world.env.song, mascot.songDances[song.id] == nil {
            songService.bake(id: song.id, core: core, generation: { [unowned self] in modelGeneration },
                             done: { [unowned self] id, slot in mascot.songDances[id] = slot; mouthSlots[slot] = nil })
        }
        let ownMouth = world.env.song.flatMap { mascot.songDances[$0.id] }.map { slot in
            if let known = mouthSlots[slot] { return known }
            let has = core.danceHasMouth(index: slot)
            mouthSlots[slot] = has
            return has
        } ?? false
        mascot.lips = voice.tick() ?? danceLips.update(dancing: mascot.isDancing, enabled: UserDefaults.standard.bool(forKey: SettingsKey.danceLipSync),
                                       ownMouth: ownMouth, packLips: songService.lips, micApps: micApps)
        for e in beats.takeSoundEvents() where mascot.hear(e) {
            lastHeard = (e, Date())
            log.info("heard \(e.rawValue, privacy: .public)")
        }
        let intent = mascot.update(
            dt: dt,
            pointer: .init(location: pointer.location, part: Mascot.Part(rawValue: pointer.part),
                           pressed: pointer.pressed, released: pointer.released),
            body: body, world: world, agent: agent(ledges: ledges)
        )
        chat(world: world, pointer: pointer.location)
        if intent.lookForSpace, let overlay {
            freeSpace.request(screen: overlay.currentScreen, characterHeight: CGFloat(overlay.characterHeight),
                              windows: overlay.windows, neverLook: ai.neverLook)
        }
        if intent.clicked, let app = mascot.announcingApp,
           let target = NSWorkspace.shared.runningApplications.first(where: {
               $0.localizedName == app || $0.bundleIdentifier == AppBadges.apps.first { $0.0 == app }?.1
           }) {
            target.activate()
        } else if intent.clicked, let s = sessions.focus(), [.waitingPermission, .failed, .done, .waitingInput].contains(s.state) {
            bringTerminalToFront(s)
        }
        if mascot.activityName != loggedActivity {
            loggedActivity = mascot.activityName
            log.notice("activity: \(self.loggedActivity, privacy: .public)")
        }
        let drag: Core.Input.Drag = switch intent.drag {
        case .none: .none
        case let .hold(p): .hold(p)
        case let .stand(p): .stand(p)
        case .release: .release
        }
        var input = Core.Input(look: intent.look, drag: drag, hop: intent.hop, expressions: intent.expressions,
                               motion: intent.motion,
                               facing: intent.facing, walkVelocity: intent.walkVelocity, sleeping: intent.sleeping)
        input.prop = intent.prop
        input.beat = intent.beat.map { SIMD3($0.bpm, $0.phase, $0.energy) }
        input.beatClip = intent.beat?.clip
        input.song = intent.song.map { ($0.clipTime, $0.rate) }
        input.point = intent.point
        input.surfaces = world.surfaces.map { SIMD3($0.minX, $0.maxX, $0.top) }
        if let to = intent.warp { core.teleport(x: to.x, y: to.y) }
        let out = stepHere ? core.step(dt: dt, input: input, skin: skin, positions: positions)
            : core.stepAhead(dt: dt, input: input, skin: skin, positions: positions)
        var root = out.root
        if intent.crossScreen != 0, let overlay, let next = overlay.neighborStage(intent.crossScreen) {
            let dir = intent.crossScreen
            let dx = dir > 0 ? -overlay.stageWidth : next.width
            core.crossScreen(dx: dx, width: next.width, ground: next.ground)
            mascot.shift(dx: dx)
            root = SIMD2(root.x + dx, next.ground)
            DispatchQueue.main.async { [weak overlay] in overlay?.moveToNeighbor(dir) }
            log.info("crossed screen \(dir, privacy: .public)")
        }
        body = .init(root: root, grounded: out.grounded, height: height, motionDone: out.motionDone,
                     walkSpeed: walkSpeed, seatHeight: seatHeight, calmWalkSpeed: calmWalkSpeed,
                     carryWalkSpeed: carryWalkSpeed, width: out.bones > 0 ? out.boundsMax.x - out.boundsMin.x : 0)
        body.onLedge = out.onLedge
        renderer?.groundShadow = groundShadowStrength > 0 && !intent.hidden ? out.floor.map { f in
            SIMD3(out.root.x, f, groundShadowStrength * max(0, 1 - (out.root.y - f) / max(height * 0.3, 1e-3)))
        } : nil
        let rate: OverlayController.FrameRate = switch intent.frameRate {
        case .active: .active
        case .sleep: out.frozen ? .sleep : .idle
        case .idle: out.grounded ? .idle : .active
        case .still: out.grounded ? .still : .active
        }
        if rate != lastRate {
            lastRate = rate
            log.debug("frame rate reason: \(String(describing: rate), privacy: .public) \(self.mascot.busyReason, privacy: .public)\(out.grounded ? "" : " airborne", privacy: .public)")
        }
        var result = OverlayController.FrameResult(
            root: out.root, frameRate: rate, bubble: intent.bubble, frozen: out.frozen && intent.sleeping,
            puffs: out.puffs + intent.puffs,
            bounds: out.bones > 0 ? (out.boundsMin, out.boundsMax) : nil)
        result.hidden = intent.hidden
        result.travelling = mascot.travelling
        return result
    }

    func listen(_ env: inout Mascot.Environment, running: Set<String>) {
        beatClock.listen(allowed: ai.listenMusic && canCapture && overlay?.hiddenForFullScreen != true && !env.muted,
                         audioPlaying: env.audioPlaying, micApps: micApps)
        if diagnosticsEnabled, Date().timeIntervalSince(lastSenseLog) > 10 {
            lastSenseLog = Date()
            let e = beats.current
            let env = env
            log.info("senses: audio \(env.audioPlaying) mic \(self.micApps.sorted().joined(separator: ","), privacy: .public) muted \(env.muted) screenCapture \(CGPreflightScreenCaptureAccess()) setting \(self.ai.listenMusic) listening \(self.beats.running) bar \(self.beats.bar.map { String(format: "meter %d %@ %.0f bpm conf %.2f section %d intensity %.2f", $0.grid.meter, $0.grid.source.rawValue, 60 / $0.grid.period, $0.grid.confidence, $0.section, $0.intensity) } ?? "none", privacy: .public) sound \(self.beats.sound.map { String(format: "music %.2f sing %.2f speech %.2f", $0.music, $0.singing, $0.speech) } ?? "none", privacy: .public) beat \(e.map { String(format: "%.0f bpm conf %.2f loud %.2f", $0.bpm, $0.confidence, $0.loudness) } ?? "none", privacy: .public) badges \(env.badges.description, privacy: .public) playing \(env.nowPlaying ?? "-", privacy: .private) app \(String(describing: env.app), privacy: .private) typing \(env.typing) battery \(env.battery ?? -1)")
        }
        env.badges = badges.current(running: running)
        notices.tick(ai)
        for (app, n) in badges.increased(env.badges) where !notices.recentlyRead(app) {
            mascot.notify(app: app)
            guard ai.notifications, !ai.isQuiet() else { continue }
            let count = n > 1 ? " (\(n) unread)" : ""
            speak("Your owner got a new notification in \(app)\(count). Call out so they look over here", fallback: String(localized: "You have a notification in \(app)!"))
            log.info("badge \(app, privacy: .public): \(n)")
        }
    }

    func environment(dark: Bool) -> Mascot.Environment {
        let now = Date()
        guard now.timeIntervalSince(sensed.at) > 2 else { return sensed.env }
        let snap = sensor.read(now: now)
        var env = Mascot.Environment()
        (env.battery, env.charging, env.hot, env.cpu) = (snap.battery, snap.charging, snap.hot, snap.cpu)
        (env.typing, env.audioPlaying, env.muted, env.online) = (snap.typing, snap.audioPlaying, snap.muted, snap.online)
        micApps = snap.micApps.subtracting(["com.apple.replayd"])
        env.inCall = !micApps.isEmpty
        env.dark = dark
        env.weekday = Calendar.current.component(.weekday, from: now)
        let front = NSWorkspace.shared.frontmostApplication
        let category = front?.bundleURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String }
        env.app = classifyApp(bundleID: front?.bundleIdentifier, category: category, name: front?.localizedName)
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        listen(&env, running: running)
        env.musicMood = beats.running ? moodListener.current(now: now) : nil
        updateModelsStatus()
        env.nowPlaying = songService.locked.map { $0.artist.isEmpty ? $0.title : "\($0.title)\" by \"\($0.artist)" }
            ?? (ai.windowTitles ? nowPlaying.current(running: running) : nil)
        let windows = overlay?.windows ?? []
        frontTitle = ai.windowTitles ? windows.first { $0.pid == front?.processIdentifier }?.title : nil
        discordTitle = ai.windowTitles ? windows.first { $0.owner == "Discord" }?.title : nil
        sensed = (now, env)
        return env
    }
}

extension AppDelegate {
    /// 画面収録の許可。毎フレーム尋ねると TCC への問い合わせが毎回走るので 2 秒ごとに見る
    var canCapture: Bool {
        if Date().timeIntervalSince(screenCheck.at) > 2 { screenCheck = (Date(), CGPreflightScreenCaptureAccess()) }
        return screenCheck.ok
    }
}
