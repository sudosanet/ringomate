@testable import Engine
import Foundation
import Testing

@Test func humanoidNames() {
    #expect(VRM.mmdName("leftUpperLeg", .v1) == "左足")
    #expect(VRM.mmdName("hips", .v1) == "下半身")
    #expect(VRM.mmdName("leftThumbProximal", .v0) == "左親指０")
    #expect(VRM.mmdName("leftThumbProximal", .v1) == "左親指１")
    #expect(VRM.mmdName("rightIndexDistal", .v1) == "右人指３")
}
