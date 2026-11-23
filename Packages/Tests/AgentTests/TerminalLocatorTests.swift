import CoreGraphics
import MascotCore
import Testing
@testable import Agent

private func windows(_ n: Int) -> [DesktopWindow] {
    (0..<n).map { DesktopWindow(number: 100 + $0, pid: 1, owner: "Ghostty", frame: .zero) }
}

@Test func locatorPicksOnlyAnUnambiguousWindow() {
    #expect(TerminalLocator.parse("1,3\n") == .init(index: 1, count: 3))
    #expect(TerminalLocator.parse("-1") == nil)
    #expect(TerminalLocator.parse("3,3") == nil)
    #expect(TerminalLocator.pick(.init(index: 1, count: 3), candidates: windows(3)) == 101)
    #expect(TerminalLocator.pick(.init(index: 1, count: 4), candidates: windows(3)) == nil)
    #expect(TerminalLocator.pick(nil, candidates: windows(3)) == nil)
}
