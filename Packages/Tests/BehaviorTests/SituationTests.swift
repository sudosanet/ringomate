import MascotCore
import Testing
@testable import Behavior

@Test func songIsAlwaysPassed() {
    var env = MacEnvironment()
    env.nowPlaying = "愛包ダンスホール"
    env.musicMood = .cute
    let d = env.describe()
    #expect(d.notable.contains { $0.contains("愛包ダンスホール") })
    #expect(d.notable.contains { $0.contains("cute") })
    #expect(!d.ambient.contains { $0.contains("listening to") })
}
