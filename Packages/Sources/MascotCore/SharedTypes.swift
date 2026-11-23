/// 拍の中の位置は 0〜1、0 が拍の頭。
public struct Beat: Sendable, Equatable {
    public var bpm: Float
    public var phase: Float
    public var energy: Float
    /// 0 が 1 拍目、分からなければ nil。
    public var beatInBar: Int?
    public var meter: Int
    public var section: Int
    public var intensity: Float
    /// 振りの頭の 1 拍目から数えた拍。踊っている間だけ。
    public var clip: Float?
    public init(bpm: Float, phase: Float, energy: Float, beatInBar: Int? = nil, meter: Int = 4,
                section: Int = 0, intensity: Float = 0.5) {
        (self.bpm, self.phase, self.energy) = (bpm, phase, energy)
        (self.beatInBar, self.meter, self.section, self.intensity) = (beatInBar, meter, section, intensity)
    }
}

/// 踊りのない所では入れない。
public struct SongPlaying: Sendable, Equatable {
    public var id: String
    public var clipTime: Float
    public var rate: Float
    public init(id: String, clipTime: Float, rate: Float) {
        (self.id, self.clipTime, self.rate) = (id, clipTime, rate)
    }
}

public struct MacEnvironment: Sendable {
    /// 0〜1、なければ nil。
    public var battery: Float?
    public var charging = false
    public var hot = false
    public var cpu: Float = 0
    /// 1 秒あたり。
    public var typing: Float = 0
    public var audioPlaying = false
    public var muted = false
    /// どこかのアプリがマイクを使っている。
    public var inCall = false
    public var nowPlaying: String?
    public var online = true
    public var dark = false
    public var app: FrontAppKind = .none
    /// 1 = 日曜。
    public var weekday = 2
    public var beat: Beat?
    public var song: SongPlaying?
    public var badges: [String: Int] = [:]
    public var musicMood: MusicMood?

    public init() {}

    public var typingHard: Bool { typing > 3 }
    public var music: Bool {
        nowPlaying != nil || app == .music || (!inCall && audioPlaying && ![.video, .game, .chat].contains(app))
    }
    public var lowBattery: Bool { (battery ?? 1) < 0.2 && !charging }
    public var heated: Bool { hot || cpu > 0.9 }
}

public enum AgentState: Equatable, Sendable {
    case none, working, reading, writing, running, waitingPermission, waitingInput, failed, done
    case thinking, delegating, compacting

    public var needsUser: Bool { self == .waitingPermission }
    public var busy: Bool { [.working, .reading, .writing, .running, .thinking, .delegating, .compacting].contains(self) }
}

/// `still` は立っている・座っているだけのとき（設定で下げられる）。
public enum FrameRate: Sendable { case idle, still, active, sleep }

public enum MusicMood: String, CaseIterable, Sendable {
    case cute, energetic, chill, cool, sad
}

public enum FrontAppKind: String, Sendable { case none, game, music, video, dev, chat, browser, office, design }

/// 鳴り始めた瞬間に 1 回。
public enum SoundEvent: String, CaseIterable, Sendable {
    case laughter, applause, boom, animal, crying, scream

    /// AI に渡す名前。
    public var label: String {
        switch self {
        case .laughter: "laughter"
        case .applause: "applause"
        case .boom: "a loud boom (fireworks, thunder, or similar)"
        case .animal: "an animal sound"
        case .crying: "crying"
        case .scream: "a scream"
        }
    }

    public var identifiers: [String] {
        switch self {
        case .laughter: ["laughter", "baby_laughter", "giggling", "belly_laugh", "chuckle_chortle"]
        case .applause: ["applause", "clapping", "cheering"]
        case .boom: ["boom", "gunshot_gunfire", "fireworks", "thunder"]
        case .animal: ["cat_meow", "cat_purr", "dog_bark", "dog_bow_wow", "bird_chirp_tweet"]
        case .crying: ["crying_sobbing", "baby_crying"]
        case .scream: ["screaming"]
        }
    }

    public static func began(previous: Float, now: Float) -> Bool { now > 0.6 && previous < 0.4 }
}
