import Foundation
import FoundationModels

@MainActor
public final class Composer {
    public static let moves = [
        "raise_left_arm", "lower_left_arm", "raise_right_arm", "lower_right_arm", "left_arm_forward", "left_arm_back",
        "right_arm_forward", "right_arm_back", "bend_left_elbow", "bend_right_elbow", "nod", "look_up", "look_left",
        "look_right", "tilt_head_left", "tilt_head_right", "lean_forward", "lean_back", "twist_left", "twist_right",
        "sway_hips_left", "sway_hips_right",
    ]

    @Generable
    public struct Move: Sendable {
        @Guide(description: "Body part and direction to move",
               .anyOf(["raise_left_arm", "lower_left_arm", "raise_right_arm", "lower_right_arm", "left_arm_forward",
                       "left_arm_back", "right_arm_forward", "right_arm_back", "bend_left_elbow", "bend_right_elbow", "nod",
                       "look_up", "look_left", "look_right", "tilt_head_left", "tilt_head_right", "lean_forward", "lean_back",
                       "twist_left", "twist_right", "sway_hips_left", "sway_hips_right"]))
        public var move: String
        @Guide(description: "Angle in degrees", .range(5...120))
        public var degrees: Double
    }

    @Generable
    public struct Keyframe: Sendable {
        @Guide(description: "Seconds from the previous pose to this pose", .range(0.2...1.5))
        public var seconds: Double
        @Guide(description: "Parts moved together in this pose (1 to 4)", .maximumCount(4))
        public var moves: [Move]
    }

    @Generable
    public struct Motion: Sendable {
        @Guide(description: "Sequence of poses (2 to 6). It returns to the starting pose automatically at the end", .maximumCount(6))
        public var keyframes: [Keyframe]
    }

    public init() {}

    public var available: Bool { OnDevice.available }

    public func compose(_ request: String) async -> String? {
        guard available else { return nil }
        let session = LanguageModelSession(model: .default, instructions: """
            You are the choreographer for a small character who lives on the desktop. You turn the requested movement into a sequence \
            of upper-body poses. Raising an arm to the side is raise_*_arm, reaching forward is *_arm_forward, bending an elbow is \
            bend_*_elbow, and nodding is nod. For a wave, raise the arm, bend the elbow, and repeat the pose shifting a little left and \
            right. Keep the angles natural.
            """)
        for _ in 0..<2 {
            guard let r = try? await session.respond(to: String(request.prefix(200)), generating: Motion.self,
                                                     options: GenerationOptions(maximumResponseTokens: 600)) else { continue }
            let keys: [[String: Any]] = r.content.keyframes.prefix(6).map { k in
                ["seconds": k.seconds,
                 "commands": k.moves.prefix(4).map { ["move": $0.move, "degrees": $0.degrees] }]
            }
            guard !keys.isEmpty, let data = try? JSONSerialization.data(withJSONObject: keys) else { continue }
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}
