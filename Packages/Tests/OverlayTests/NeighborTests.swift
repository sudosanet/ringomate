import CoreGraphics
import Testing
@testable import Overlay

@MainActor
@Test func findsWalkableNeighborScreens() {
    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let right = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    let above = CGRect(x: 0, y: 982, width: 1920, height: 1080)
    let raised = CGRect(x: -1920, y: 600, width: 1920, height: 1080)
    let frames = [main, right, above, raised]
    #expect(OverlayController.neighbor(frames: frames, current: 0, dir: 1) == 1)
    #expect(OverlayController.neighbor(frames: frames, current: 1, dir: -1) == 0)
    #expect(OverlayController.neighbor(frames: frames, current: 0, dir: -1) == nil)
    #expect(OverlayController.neighbor(frames: frames, current: 2, dir: 1) == nil)
}

@Test func staysOnTheSameDisplayWhenScreensChange() {
    #expect(OverlayController.index(of: 7, in: [1, 5, 7]) == 2)
    #expect(OverlayController.index(of: 7, in: [1, 7]) == 1)
    #expect(OverlayController.index(of: 7, in: [1]) == 0)
    #expect(OverlayController.index(of: nil, in: [1, 7]) == 0)
}

@Test func ledgeIsOnlyTheVisiblePartOfTheTopEdge() {
    let back = CGRect(x: 0, y: 100, width: 800, height: 400)
    let front = CGRect(x: 300, y: 50, width: 600, height: 300)
    #expect(OverlayController.visibleTop(of: back, under: [front])! == (0, 300))
    #expect(OverlayController.visibleTop(of: back, under: [CGRect(x: 0, y: 200, width: 800, height: 100)])! == (0, 800))
    #expect(OverlayController.visibleTop(of: back, under: [CGRect(x: 500, y: 20, width: 400, height: 60)], clearance: 100)! == (0, 500))
    #expect(OverlayController.visibleTop(of: back, under: [CGRect(x: 500, y: 20, width: 400, height: 60)])! == (0, 800))
    #expect(OverlayController.visibleTop(of: back, under: [CGRect(x: -10, y: 0, width: 900, height: 300)]) == nil)
}
