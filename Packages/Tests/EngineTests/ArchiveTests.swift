@testable import Engine
import Foundation
import Testing

@Test func basenameKeyAndNormalize() {
    #expect(basenameKey("tex\\Hair.PNG") == "hair")
    #expect(basenameKey(".png") == ".png")
    #expect(TextureResolver.normalize("a/./b/../c//d.png") == "a/c/d.png")
    #expect(crc32(Array("123456789".utf8)) == 0xCBF4_3926)
}

private func encoded(_ s: String, _ enc: CFStringEncodings) -> [UInt8] {
    let data = CFStringCreateExternalRepresentation(nil, s as CFString, CFStringEncoding(enc.rawValue), 0)! as Data
    return [UInt8](data)
}

