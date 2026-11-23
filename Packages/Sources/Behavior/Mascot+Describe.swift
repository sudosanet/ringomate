import MascotCore
import Foundation
import simd

extension Mascot {
    /// 機嫌は −1〜1、元気は 0〜1。
    public var summary: (activity: String, sleepy: Bool, mood: Float, energy: Float) {
        (activityName, intentSleepy, needs.mood, needs.energy)
    }

    public var canSpeak: Bool { sleepiness <= Self.sleepThreshold && state == .idle && speechLeft <= 0 }

    public var travelling: Bool {
        if case .dragging = state { return true }
        switch activity {
        case .walking, .climbing, .hopping, .warping, .dropping: return true
        default: return false
        }
    }

    public var announcingApp: String? {
        if case let .announcing(app, _) = activity { return app }
        return nil
    }

    /// AI の一言の場面に使う。
    public var activityDescription: String {
        switch activity {
        case .standing: phoneLeft > 0 ? "looking at a phone" : "standing and waiting"
        case .walking: "taking a stroll"
        case .climbing: "climbing up a window"
        case .hopping: "hopping from window to window"
        case .warping: "teleporting"
        case .sitting: "sitting on top of a window"
        case .dropping: "climbing down from a window"
        case .gesturing: "moving around"
        case .chair: "resting in a chair on the floor"
        case .hugging: "dozing off while hugging your knees"
        case .stretching: "stretching"
        case let .holding(prop, _): "holding a \(prop.label)"
        case .dancing: "dancing to the music"
        case let .announcing(app, _): "announcing a notification from \(app)"
        case .visiting: "pointing at something you found on the screen"
        }
    }

    public var activityName: String {
        switch activity {
        case .standing: "standing"
        case let .walking(x, then): "walking(to \(Int(x))\(then.map { ", then \($0)" } ?? ""))"
        case let .climbing(id, _, _, _): "climbing(\(id))"
        case let .hopping(id, _, _, _): "hopping(\(id))"
        case let .warping(to, id, _, _): "warping(to \(Int(to.x)),\(Int(to.y))\(id.map { ", then \($0)" } ?? ""))"
        case let .sitting(id, _, phase, _): "sitting(\(id), \(phase))"
        case .dropping: "dropping"
        case let .gesturing(index, _): "gesturing(\(index))"
        case let .chair(phase, _): "chair(\(phase))"
        case .stretching: "stretching"
        case .hugging: "hugging"
        case let .holding(prop, _): "holding(\(prop))"
        case let .dancing(move, _, _): "dancing(\(move))"
        case let .announcing(app, _): "announcing(\(app))"
        case let .visiting(id, _): "visiting(\(id))"
        }
    }
}
