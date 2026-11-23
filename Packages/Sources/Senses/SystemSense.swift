import MascotCore
import CoreAudio
import CoreGraphics
import Foundation
import IOKit.ps
import Network

/// 許可なしで読めるものだけで、端末の外へは出さない。キー入力は回数だけ。
public struct SystemSnapshot: Sendable, Equatable {
    public var battery: Float?
    public var charging = false
    public var hot = false
    /// 1 分の平均負荷 ÷ コア数。
    public var cpu: Float = 0
    public var typing: Float = 0
    public var audioPlaying = false
    public var muted = false
    /// 使われているかだけで音は聞かない。
    public var micApps: Set<String> = []
    public var online = true

    public init() {}
}

/// `read` はメインスレッドで呼ぶ。
public final class SystemSensor: @unchecked Sendable {
    private var lastKeys: UInt32?
    private var lastRead: Date?
    private var typing: Float = 0
    private let path = NWPathMonitor()
    private var online = true
    private let lock = NSLock()

    public init() {
        path.pathUpdateHandler = { [weak self] p in
            self?.lock.lock()
            self?.online = p.status == .satisfied
            self?.lock.unlock()
        }
        path.start(queue: DispatchQueue(label: "ringomate.network", qos: .utility))
    }

    deinit { path.cancel() }

    public func read(now: Date = Date()) -> SystemSnapshot {
        var s = SystemSnapshot()
        (s.battery, s.charging) = Self.power()
        s.hot = [.serious, .critical].contains(ProcessInfo.processInfo.thermalState)
        var load = [0.0]
        if getloadavg(&load, 1) == 1 {
            s.cpu = Float(load[0]) / Float(max(ProcessInfo.processInfo.activeProcessorCount, 1))
        }
        // キー入力は回数だけで、中身は読まない
        let keys = CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
        if let lastKeys, let lastRead {
            let dt = Float(now.timeIntervalSince(lastRead))
            if dt > 0 {
                let rate = Float(keys &- lastKeys) / dt
                typing += (rate - typing) * min(1, dt / 4)
            }
        }
        (lastKeys, lastRead) = (keys, now)
        s.typing = typing
        (s.audioPlaying, s.muted) = Self.audio()
        s.micApps = Self.inputApps()
        lock.lock()
        s.online = online
        lock.unlock()
        return s
    }

    static func power() -> (Float?, Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, false) }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
                || (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (Float(now) / Float(max), charging)
        }
        return (nil, false)
    }

    static func inputApps() -> Set<String> { apps(running: kAudioProcessPropertyIsRunningInput) }

    public static func outputApps() -> Set<String> { apps(running: kAudioProcessPropertyIsRunningOutput) }

    private static func apps(running selector: AudioObjectPropertySelector) -> Set<String> {
        func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
            AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        }
        var a = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &list) == noErr else { return [] }
        var out: Set<String> = []
        for p in list {
            var running: UInt32 = 0
            var n = UInt32(MemoryLayout<UInt32>.size)
            var r = address(selector)
            guard AudioObjectGetPropertyData(p, &r, 0, nil, &n, &running) == noErr, running != 0 else { continue }
            var id: Unmanaged<CFString>?
            n = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var b = address(kAudioProcessPropertyBundleID)
            if AudioObjectGetPropertyData(p, &b, 0, nil, &n, &id) == noErr, let id = id?.takeRetainedValue() as String?, !id.isEmpty {
                out.insert(id)
            }
        }
        return out
    }

    static func audio() -> (Bool, Bool) {
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return (false, false) }
        func flag(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> Bool {
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return false }
            return value != 0
        }
        return (flag(kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal),
                flag(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput))
    }
}


public func classifyApp(bundleID: String?, category: String?, name: String?) -> FrontAppKind {
    let id = (bundleID ?? "").lowercased(), cat = (category ?? "").lowercased(), n = (name ?? "").lowercased()
    func has(_ keys: [String]) -> Bool { keys.contains { id.contains($0) || n.contains($0) } }
    if cat.contains("games") || has(["steam", "minecraft", "epicgames", "roblox", "genshin", "battle.net"]) { return .game }
    if has(["com.apple.music", "spotify", "music", "soundcloud", "amazon.music"]) || cat.contains("music") { return .music }
    if has(["tv", "netflix", "vlc", "iina", "quicktime", "youtube", "primevideo"]) || cat.contains("entertainment") { return .video }
    if has(["xcode", "vscode", "com.microsoft.vscode", "jetbrains", "terminal", "iterm", "ghostty", "cursor", "zed", "warp"])
        || cat.contains("developer-tools") { return .dev }
    if has(["slack", "discord", "line", "messages", "teams", "zoom", "webex", "telegram", "whatsapp", "mail"])
        || cat.contains("social-networking") { return .chat }
    if has(["safari", "chrome", "firefox", "brave", "arc", "edge", "vivaldi"]) { return .browser }
    if has(["figma", "photoshop", "illustrator", "procreate", "clip studio", "blender", "affinity", "sketch"])
        || cat.contains("graphics-design") { return .design }
    if has(["word", "excel", "powerpoint", "pages", "numbers", "keynote", "notion", "obsidian"])
        || cat.contains("productivity") { return .office }
    return .none
}

/// 起動しているときだけ AppleScript で読む（勝手に起動しない）。
public final class NowPlaying: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var last = Date.distantPast
    private var busy = false
    private let queue = DispatchQueue(label: "ringomate.nowplaying", qos: .utility)

    public init() {}

    public func current(running: Set<String>) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let apps = [("com.apple.Music", "Music"), ("com.spotify.client", "Spotify")].filter { running.contains($0.0) }
        if apps.isEmpty {
            value = nil
            return nil
        }
        if !busy, Date().timeIntervalSince(last) > 15 {
            (busy, last) = (true, Date())
            queue.async { [weak self] in
                var found: String?
                for (_, app) in apps where found == nil {
                    found = Self.ask(app)
                }
                guard let self else { return }
                self.lock.lock()
                (self.value, self.busy) = (found, false)
                self.lock.unlock()
            }
        }
        return value
    }

    private static func ask(_ app: String) -> String? {
        let script = """
        tell application "\(app)"
            if player state is playing then return (name of current track) & " / " & (artist of current track)
        end tell
        return ""
        """
        guard let text = runTool("/usr/bin/osascript", ["-e", script])?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return text.isEmpty ? nil : String(text.prefix(80))
    }
}
