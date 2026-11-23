@testable import Engine
import Foundation
import Testing

@Test func pmxReadsConvertedModel() throws {
    let data = try Assets.pmxBytes()
    let m = try PMXModel(pmx: data)
    #expect(m.bones.count > 100 && m.materials.count > 5 && m.geometry.positions.count == m.metadata.counts.vertices * 3)
    #expect(throws: FormatError.self) { try PMXModel(pmx: Array(data.prefix(1000))) }
}
