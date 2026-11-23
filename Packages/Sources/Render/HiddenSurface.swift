import Foundation
import Metal
import simd

let hiddenSurfaceShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VisOut { float4 position [[position]]; };

vertex VisOut vis_vertex(uint vid [[vertex_id]],
                         constant float4x4& viewProj [[buffer(11)]],
                         const device packed_float3* positions [[buffer(1)]],
                         const device uint4* boneIndices [[buffer(4)]],
                         const device float4* boneWeights [[buffer(5)]],
                         const device float4x4* skin [[buffer(6)]]) {
    uint4 i = boneIndices[vid];
    float4 w = boneWeights[vid];
    float4x4 m = skin[i.x] * w.x + skin[i.y] * w.y + skin[i.z] * w.z + skin[i.w] * w.w;
    VisOut out;
    out.position = viewProj * (m * float4(float3(positions[vid]), 1.0));
    return out;
}

fragment void vis_depth_fragment() {}

[[early_fragment_tests]]
fragment void vis_mark_fragment(uint prim [[primitive_id]],
                                constant uint& base [[buffer(12)]],
                                device uint* visible [[buffer(13)]]) {
    visible[base + prim] = 1;
}
"""

enum HiddenSurface {
    static let version = 4
    static let resolution = 384
    static let azimuths = 12
    static let elevations: [Float] = [-0.5, 0, 0.45, 0.9]

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "app.ringomate/visibility")
    }

    @MainActor
    static func hiddenTriangles(renderer: Renderer, model m: ModelResources, mesh: MeshInput,
                                poses: [[Float]], key: String) -> Set<Int> {
        guard mesh.materials.contains(where: { $0.hiddenRemoval || $0.skinCandidate }) else { return [] }
        let targets = mesh.materials.indices.filter { mesh.materials[$0].hiddenRemoval || mesh.materials[$0].skinCandidate }
        let file = directory.appending(path: "\(key)-v\(version)-m\(targets.map(String.init).joined(separator: "_"))")
        if let d = try? Data(contentsOf: file) {
            return Set(d.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }.map(Int.init))
        }
        guard !poses.isEmpty, let visible = renderer.visibility(model: m, mesh: mesh, poses: poses, views: views(mesh)) else { return [] }
        let hidden = removable(mesh: mesh, visible: visible, translucent: m.translucent)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ids = hidden.sorted().map(UInt32.init)
        try? ids.withUnsafeBytes { Data($0) }.write(to: file, options: .atomic)
        return hidden
    }

    static func removable(mesh: MeshInput, visible: [UInt32], translucent: (MaterialInput) -> Bool) -> Set<Int> {
        let idx = mesh.indices
        var seenVertex = [Bool](repeating: false, count: mesh.vertexCount)
        for t in 0..<idx.count / 3 where visible[t] != 0 {
            for k in 0..<3 { seenVertex[Int(idx[t * 3 + k])] = true }
        }
        var hidden = Set<Int>()
        for mat in mesh.materials where (mat.hiddenRemoval || mat.skinCandidate) && !translucent(mat) {
            let range = mat.indexStart / 3..<(mat.indexStart + mat.indexCount) / 3
            for t in range where visible[t] == 0 {
                if !(0..<3).contains(where: { seenVertex[Int(idx[t * 3 + $0])] }) { hidden.insert(t) }
            }
        }
        return hidden
    }

    static func views(_ mesh: MeshInput) -> [simd_float4x4] {
        let p = mesh.positions
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in stride(from: 0, to: p.count, by: 3) {
            let v = SIMD3(p[i], p[i + 1], p[i + 2])
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        let center = (lo + hi) / 2
        let r = simd_length(hi - lo) / 2 * 1.25
        var out: [simd_float4x4] = []
        for e in elevations {
            for a in 0..<azimuths {
                let yaw = Float(a) / Float(azimuths) * 2 * .pi
                let rot = simd_float4x4(simd_quatf(angle: e, axis: [1, 0, 0]) * simd_quatf(angle: yaw, axis: [0, 1, 0]))
                let scale = simd_float4x4(diagonal: [1 / r, 1 / r, 0.5 / r, 1])
                var translate = matrix_identity_float4x4
                translate.columns.3 = SIMD4(-center, 1)
                var toNDC = matrix_identity_float4x4
                toNDC.columns.3.z = 0.5
                out.append(toNDC * scale * rot * translate)
            }
        }
        return out
    }
}

@MainActor
extension Renderer {
    func visibility(model m: ModelResources, mesh: MeshInput, poses: [[Float]], views: [simd_float4x4]) -> [UInt32]? {
        let triangles = mesh.indices.count / 3
        let bones = max(mesh.boneCount, 1)
        guard let compiler = try? device.makeCompiler(descriptor: MTL4CompilerDescriptor()),
              let library = try? compiler.makeLibrary(descriptor: {
                  let d = MTL4LibraryDescriptor()
                  d.source = hiddenSurfaceShaderSource
                  d.name = "hidden"
                  return d
              }()) else { return nil }
        func pipeline(_ fragment: String) -> MTLRenderPipelineState? {
            let pd = MTL4RenderPipelineDescriptor()
            for (f, name) in [(\MTL4RenderPipelineDescriptor.vertexFunctionDescriptor, "vis_vertex"),
                              (\MTL4RenderPipelineDescriptor.fragmentFunctionDescriptor, fragment)] {
                let fd = MTL4LibraryFunctionDescriptor()
                fd.name = name
                fd.library = library
                pd[keyPath: f] = fd
            }
            return try? compiler.makeRenderPipelineState(descriptor: pd)
        }
        func depthState(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }
        let flatPoses = poses.flatMap { $0.count == bones * 16 ? $0 : [Float](repeating: 0, count: bones * 16) }
        let bases = mesh.materials.map { UInt32($0.indexStart / 3) }
        guard let depthPipe = pipeline("vis_depth_fragment"), let markPipe = pipeline("vis_mark_fragment"),
              let depthWrite = depthState(.lessEqual, write: true), let depthEqual = depthState(.equal, write: false),
              let poseBuffer = device.makeBuffer(bytes: flatPoses, length: flatPoses.count * 4, options: .storageModeShared),
              let viewBuffer = device.makeBuffer(bytes: views, length: views.count * 64, options: .storageModeShared),
              let baseBuffer = device.makeBuffer(bytes: bases, length: max(bases.count, 1) * 4, options: .storageModeShared),
              let visible = device.makeBuffer(length: max(triangles, 1) * 4, options: .storageModeShared),
              let table = try? device.makeArgumentTable(descriptor: {
                  let d = MTL4ArgumentTableDescriptor()
                  d.maxBufferBindCount = 14
                  return d
              }()),
              let set = try? device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        else { return nil }
        memset(visible.contents(), 0, visible.length)
        let dd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: HiddenSurface.resolution,
                                                          height: HiddenSurface.resolution, mipmapped: false)
        dd.usage = .renderTarget
        dd.storageMode = .memoryless
        guard let depth = device.makeTexture(descriptor: dd) else { return nil }
        for b in [poseBuffer, viewBuffer, baseBuffer, visible] { set.addAllocation(b) }
        set.addAllocation(depth)
        set.commit()
        // メインアクター上で同期的に使うだけなので、Swift 6 の領域ベースの解析から外す。
        nonisolated(unsafe) let depthTarget = depth

        let draws = mesh.materials.enumerated().filter { $0.element.indexCount > 0 }
        let occluders = draws.filter { !m.translucent($0.element) }
        let done = submitOffscreen(residency: set) { cb in
            for p in 0..<poses.count {
                for v in 0..<views.count {
                    let pass = MTL4RenderPassDescriptor()
                    pass.depthAttachment.texture = depthTarget
                    pass.depthAttachment.loadAction = .clear
                    pass.depthAttachment.storeAction = .dontCare
                    pass.depthAttachment.clearDepth = 1
                    pass.renderTargetWidth = HiddenSurface.resolution
                    pass.renderTargetHeight = HiddenSurface.resolution
                    guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { continue }
                    enc.setFrontFacing(.clockwise)
                    table.setAddress(m.positions.gpuAddress, index: 1)
                    table.setAddress(m.boneIndices.gpuAddress, index: 4)
                    table.setAddress(m.boneWeights.gpuAddress, index: 5)
                    table.setAddress(poseBuffer.gpuAddress + UInt64(p * bones * 64), index: 6)
                    table.setAddress(viewBuffer.gpuAddress + UInt64(v * 64), index: 11)
                    table.setAddress(visible.gpuAddress, index: 13)
                    enc.setArgumentTable(table, stages: [.vertex, .fragment])
                    for (pipe, state, list) in [(depthPipe, depthWrite, occluders), (markPipe, depthEqual, draws)] {
                        enc.setRenderPipelineState(pipe)
                        enc.setDepthStencilState(state)
                        for (i, mat) in list {
                            table.setAddress(baseBuffer.gpuAddress + UInt64(i * 4), index: 12)
                            enc.setCullMode(mat.doubleSided ? .none : .back)
                            enc.drawIndexedPrimitives(
                                primitiveType: .triangle, indexCount: mat.indexCount, indexType: .uint32,
                                indexBuffer: m.indices.gpuAddress + UInt64(mat.indexStart * 4),
                                indexBufferLength: mat.indexCount * 4)
                        }
                    }
                    enc.endEncoding()
                }
            }
        }
        guard done else { return nil }
        let p = visible.contents().bindMemory(to: UInt32.self, capacity: triangles)
        return Array(UnsafeBufferPointer(start: p, count: triangles))
    }
}
