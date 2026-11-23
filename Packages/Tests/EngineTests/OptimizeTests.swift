@testable import Engine
import Foundation
import Testing

@Test func weldsSeamsWithinThresholdOnly() {
    let a = Math.radians(20)
    var n: [Float] = [0, 1, 0, sin(a), cos(a), 0, 1, 0, 0]
    #expect(Optimize.weld(positions: Array(repeating: 0, count: 9), normals: &n, indices: [0, 1, 2], materials: [(3, false)], maxDegrees: 40) == 2)
    var m = n
    #expect(Optimize.weld(positions: Array(repeating: 0, count: 9), normals: &m, indices: [0, 1, 2], materials: [(3, true)], maxDegrees: 40) == 0)
    #expect(abs(n[0] - n[3]) < 1e-6 && abs(n[1] - n[4]) < 1e-6 && Array(n[6..<9]) == [1, 0, 0])
    let s = Optimize.smoothNormals(positions: [0, 0, 0, 0, 0, 0, 1, 0, 0], normals: [1, 0, 0, 0, 1, 0, 0, 0, 1])
    #expect(abs(s[0] - 0.70710677) < 1e-5 && Array(s[0..<3]) == Array(s[3..<6]) && Array(s[6..<9]) == [0, 0, 1])
}

