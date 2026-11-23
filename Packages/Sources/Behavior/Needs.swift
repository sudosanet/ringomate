import Foundation

struct Needs: Equatable {
    var energy: Float = 0.8
    var boredom: Float = 0
    var attention: Float = 0.2
    var mood: Float = 0.3
    var sleepiness: Float = 0

    static let baselineMood: Float = 0.3

    enum Event { case petted, giggled, waved, dropped, touched }

    mutating func update(dt: Float, activity: Activity, world: Mascot.World, touched: Bool) {
        let night = world.hour >= 23 || world.hour < 6
        let dozing = sleepiness > Mascot.sleepThreshold
        switch activity {
        case .walking, .climbing, .hopping, .warping: energy -= dt / 150
        case .gesturing: energy -= dt / 250
        case _ where dozing: energy += dt / 60
        case let .sitting(_, _, phase, _) where phase == .idle: energy += dt / (night ? 200 : 100)
        case .chair(.idle, _): energy += dt / 100
        case .hugging: energy += dt / 140
        default: energy -= dt / 1200
        }
        if touched {
            boredom = 0
            sleepiness = 0
        } else {
            if case .standing = activity { boredom += dt / 40 }
            let active = world.userIdleSeconds < 30
            attention += dt / (active ? 150 : 400)
            let away = Float(min(max((world.userIdleSeconds - 120) / 600, 0), 1))
            let tired = max(0, (0.4 - energy) * 2.5)
            let goal = min(1, away + (away > 0 && night ? 0.3 : 0) + tired)
            sleepiness += (goal - sleepiness) * (1 - exp(-dt / 5))
        }
        let env = world.env
        if env.lowBattery { energy -= dt / 300 }
        if env.charging { energy += dt / 600 }
        if env.heated { mood -= dt / 400 }
        if env.music { mood += dt / 300 }
        if !env.online { mood -= dt / 600 }
        let base = Self.baselineMood + (env.weekday == 6 ? 0.15 : 0) - (env.weekday == 2 && world.hour < 12 ? 0.1 : 0)
        mood += (base - mood) * (1 - exp(-dt / 120))
        clamp()
    }

    mutating func record(_ event: Event) {
        switch event {
        case .petted: mood += 0.3; attention -= 0.5
        case .giggled: mood += 0.2; attention -= 0.3
        case .waved: attention -= 0.4
        case .dropped: mood -= 0.25
        case .touched: attention -= 0.2
        }
        clamp()
    }

    private mutating func clamp() {
        energy = min(max(energy, 0), 1)
        boredom = min(max(boredom, 0), 1)
        attention = min(max(attention, 0), 1)
        mood = min(max(mood, -1), 1)
        sleepiness = min(max(sleepiness, 0), 1)
    }

    var cheerful: Bool { mood > 0.35 && energy > 0.45 }
}
