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

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let log = Logger(subsystem: "app.ringomate", category: "app")
    let core = Core()
    let launchEnv = ProcessInfo.processInfo.environment
    let mascot = Mascot()
    var renderer: Renderer?
    var overlay: OverlayController?
    var statusItem: NSStatusItem?
    var diagnostics: [String] = []
    var height: Float = 20
    var walkSpeed: Float = 0
    var calmWalkSpeed: Float = 0
    var carryWalkSpeed: Float = 0
    var seatHeight: Float = 0
    var body = Mascot.Body(root: .zero, grounded: true, height: 20)
    var sessions = Sessions()
    let locator = TerminalLocator()
    var hookServer: HookServer?
    lazy var voice: VoiceService = {
        let v = VoiceService(mascot: mascot, status: VoiceStatus())
        v.micApps = { [unowned self] in micApps }
        return v
    }()
    lazy var remote: Remote = {
        let r = Remote(mascot: mascot)
        r.say = { [unowned self] in voice.say($0, scene: .agent) }
        r.playComposed = { [unowned self] json in
            let summary = try core.playComposed(json)
            log.info("composed motion: \(summary, privacy: .private)")
            return summary
        }
        return r
    }()
    var loggedLedges: [Int] = []
    var loggedTerminal: Int?? = .none
    var loggedActivity = ""
    /// kCGAnyInputEventType（~0）。CGEventType に名前付きの case がない。
    static let anyInput = CGEventType(rawValue: UInt32.max) ?? .null
    static let lastModelKey = SettingsKey.lastModelPath
    var profileWatcher: DispatchSourceFileSystemObject?
    var profileReload: DispatchWorkItem?
    var watchedProfileDir: String?
    var stepHere = false
    let chatter = Chatter()
    let desktopThings = DesktopThings()
    let freeSpace = FreeSpaceWatcher()
    lazy var aiTools = AITools(mascot: mascot) { [weak self] sentence in
        await self?.remote.compose(sentence).1 ?? false
    }
    var chatTriggers = ChatTriggers()
    var ai = AISettings()
    var lastLook = Date.distantPast
    var lastWorld = Mascot.World()
    var lastRate = OverlayController.FrameRate.idle
    let sensor = SystemSensor()
    let beats = BeatTracker()
    let badges = AppBadges()
    lazy var notices: NotificationReader = {
        let r = NotificationReader()
        r.announce = { [weak self] app, line in
            guard let self else { return }
            mascot.notify(app: app)
            voice.say(line, seconds: SpeechLanguage.readingSeconds(line), scene: .notification)
        }
        return r
    }()
    var lastSenseLog = Date.distantPast
    lazy var beatClock = BeatClock(tracker: beats)
    let songService = SongService()
    var updateScheduler: NSBackgroundActivityScheduler?
    lazy var moodListener = MusicMoodListener(tracker: beats)
    var micApps: Set<String> = []
    let danceLips = DanceLips()
    var mouthSlots: [Int: Bool] = [:]
    var modelsStatus = ""
    let nowPlaying = NowPlaying()
    var sensed = (at: Date.distantPast, env: Mascot.Environment())
    var frontTitle: String?
    var discordTitle: String?
    var lastPointer = SIMD2<Float>(0, 0)
    var lastHeard: (SoundEvent, Date)?
    lazy var settingsWindow = SettingsWindow(actions: SettingsActions(
        loadModel: { [weak self] in self?.load($0) },
        reload: { [weak self] in self?.resetCharacter() },
        diagnostics: { [weak self] in (self?.diagnostics ?? []) + ["models: \(self?.modelsStatus ?? "")"] },
        details: { path in
            guard let i = try? await Task.detached(priority: .utility, operation: { try Core.info(model: path) }).value else { return nil }
            return ModelDetails(
                title: i.title, titleEn: i.titleEn, comment: i.comment, format: i.format,
                terms: i.terms.map { ($0.name, $0.text) },
                counts: [(String(localized: "Vertices"), i.vertices), (String(localized: "Materials"), i.materials), (String(localized: "Bones"), i.bones),
                         (String(localized: "Morphs"), i.morphs), (String(localized: "Rigid bodies"), i.rigidBodies), (String(localized: "Joints"), i.joints),
                         (String(localized: "Textures"), i.textures)].map { ($0.0, Int($0.1)) },
                profile: i.profile, decisions: i.decisions.map { ($0.item, $0.value, $0.source, $0.reason) })
        },
        makeThumbnail: { [weak self] in self?.thumbnails.request($0) },
        rules: {
            let r = Core.rules()
            return (r.rules.map { ($0.name, $0.kind, $0.user, $0.family) }, r.errors)
        },
        status: loadStatus
    ).withAI(self).withVoice(voice))
    var rampMode = "auto"
    var groundShadowStrength: Float = 0.35
    static let visibleItemTag = 900
    static let updateItemTag = 901
    lazy var conversation = Conversation(memoryURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "ringomate/memory.json"))
    var loading = false
    var queuedLoad: (path: String, remembering: Bool)?
    let boneAssist = BoneAssist()
    lazy var thumbnails = ThumbnailMaker(library: Bundle.main.path(forResource: "UAL1_Standard", ofType: "glb", inDirectory: "ual"),
                                                 status: loadStatus)
    let loadStatus = LoadStatus()
    var modelGeneration = 0

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SettingsKey.registerDefaults()
        ai = .read()
        songService.start()
        _ = voice
        chatter.tools = { [weak self] in self?.tools(talking: false) ?? [] }
        // 前面のウィンドウを見る・Mac の音を聞く・壁紙の物を見つけるには画面収録の許可が要る。
        if ai.needsScreenCapture, !CGPreflightScreenCaptureAccess(), !UserDefaults.standard.bool(forKey: "askedScreenCapture") {
            UserDefaults.standard.set(true, forKey: "askedScreenCapture")
            CGRequestScreenCaptureAccess()
        }
        let renderer: Renderer
        do {
            renderer = try Renderer()
        } catch {
            log.fault("Metal 4 renderer unavailable: \(error, privacy: .public)")
            NSApp.terminate(nil)
            return
        }
        self.renderer = renderer
        let overlay = OverlayController(
            renderer: renderer,
            onFrame: { [unowned self] dt, pointer, skin, positions in
                frame(dt: dt, pointer: pointer, skin: skin, positions: positions)
            },
            onStage: { [unowned self] width, ground in core.setStage(width: width, ground: ground) }
        )
        overlay.start()
        self.overlay = overlay
        applySettings()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySettings() }
        }
        log.info("overlays \(overlay.panelCount)")

        let last = UserDefaults.standard.string(forKey: Self.lastModelKey).flatMap { FileManager.default.fileExists(atPath: $0) ? $0 : nil }
        let path = launchEnv["MASCOT_MODEL"] ?? last ?? ModelLibrary.bundled.first
        if let path { load(path) }
        buildMenu()

        #if DEBUG
        installDebugHooks()
        #endif

        let server = HookServer(onEvent: { [unowned self] event in
            log.info("hook \(event.name, privacy: .public) \(event.toolName ?? "", privacy: .public) term=\(event.terminal ?? "-", privacy: .private)")
            sessions.apply(event)
        }, onRequest: { [unowned self] request, reply in
            log.info("request \(String(describing: request), privacy: .private)")
            remote.overlay = overlay
            remote.answer(request, reply: reply)
        })
        do { try server.start() } catch { log.error("hook server: \(error, privacy: .private)") }
        hookServer = server
        watchProfiles()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hookServer?.stop()
        voice.quit()
    }

}
