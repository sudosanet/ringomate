@testable import Engine
import Foundation
import Testing

private let assets = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../assets").standardized

@Test func countsMouthKeysInVMD() {
    func vmd(mouth: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 50) + [0, 0, 0, 0]
        let n = UInt32(mouth + 10)
        b += [UInt8(n & 0xff), UInt8(n >> 8 & 0xff), 0, 0]
        func key(_ name: [UInt8], _ frame: Int) -> [UInt8] {
            let f = UInt32(frame), w = Float(1).bitPattern
            return name + [UInt8](repeating: 0, count: 15 - name.count) + (0..<4).map { UInt8(f >> (8 * $0) & 0xff) }
                + (0..<4).map { UInt8(w >> (8 * $0) & 0xff) }
        }
        for i in 0..<mouth { b += key([0x82, 0xA0], i * 300 / max(mouth, 1)) }
        for i in 0..<10 { b += key(Array("まばたき".utf8.prefix(12)), i * 30) }
        return b
    }
    #expect(!VMDClip.mouthKeys(vmd(mouth: 0), start: 54))
    #expect(!VMDClip.mouthKeys(vmd(mouth: 2), start: 54))
    #expect(VMDClip.mouthKeys(vmd(mouth: 20), start: 54))
}
