import CoreGraphics
import Testing
@testable import MascotCore

@Test func visibleFractionCountsUncoveredArea() {
    let w = CGRect(x: 0, y: 0, width: 100, height: 100)
    #expect(visibleFraction(of: w, under: []) == 1)
    #expect(visibleFraction(of: w, under: [CGRect(x: 50, y: 0, width: 100, height: 100)]) == 0.5)
    #expect(visibleFraction(of: w, under: [CGRect(x: 50, y: 0, width: 100, height: 100), CGRect(x: 60, y: 0, width: 100, height: 100)]) == 0.5)
    #expect(visibleFraction(of: w, under: [CGRect(x: -10, y: -10, width: 200, height: 200)]) == 0)
}
