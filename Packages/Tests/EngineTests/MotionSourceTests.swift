@testable import Engine
import Foundation
import Testing
import simd

private let repo = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../..").standardized

private func bandai(_ name: String) -> String? {
    try? String(contentsOf: repo.appending(path: "assets/bandai/dataset/Bandai-Namco-Research-Motiondataset-1/data/\(name)"), encoding: .utf8)
}

@Test func loadsBundledUAL() throws {
    guard let data = try? Data(contentsOf: repo.appending(path: "assets/ual/UAL1_Standard.glb")) else { return }
    let (skel, clips) = try SourceClip.loadGLB([UInt8](data))
    #expect(skel.names[0] == "root" && skel.parents[0] == nil && skel.parents[1] == 0)
    let walk = try #require(clips.first { $0.name == "Walk_Loop" })
    #expect(walk.duration > 0.3 && walk.sample(skel, 0.1).count == skel.names.count)
}

