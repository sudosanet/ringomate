import CoreGraphics
import Foundation
import Metal
import os
import QuartzCore
import simd

extension Renderer {
    func lightViewProj(_ m: ModelResources) -> simd_float4x4 {
        let root = m.skin.contents().bindMemory(to: simd_float4x4.self, capacity: 1).pointee.columns.3
        let center = SIMD3(root.x, root.y, root.z) + m.boundsCenter
        let r = m.boundsRadius
        let f = simd_normalize(SIMD3<Float>(-0.5, -1, 0.5))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), f))
        let up = simd_cross(f, right)
        let view = simd_float4x4(rows: [SIMD4(right, -simd_dot(right, center)), SIMD4(up, -simd_dot(up, center)),
                                        SIMD4(f, -simd_dot(f, center)), SIMD4(0, 0, 0, 1)])
        let proj = simd_float4x4(rows: [SIMD4(1 / r, 0, 0, 0), SIMD4(0, 1 / r, 0, 0),
                                        SIMD4(0, 0, 0.5 / r, 0.5), SIMD4(0, 0, 0, 1)])
        return proj * view
    }

    func encodePartResolve() {
        guard let src = msaaPart, let dst = partIDs, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        enc.barrier(afterQueueStages: .fragment, beforeStages: .dispatch, visibilityOptions: .device)
        let t = computeTable
        t.setTexture(src.gpuResourceID, index: 0)
        t.setTexture(dst.gpuResourceID, index: 1)
        enc.setArgumentTable(t)
        enc.setComputePipelineState(states.partResolve)
        enc.dispatchThreads(threadsPerGrid: MTLSize(width: dst.width, height: dst.height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        enc.endEncoding()
    }

    func encodeBloom(target: MTLTexture) {
        guard let glow, let a = bloomA, let b = bloomB, let enc = commandBuffer.makeComputeCommandEncoder() else { return }
        let p = bloomParams.contents()
        p.storeBytes(of: SIMD2<Int32>(1, 0), toByteOffset: 0, as: SIMD2<Int32>.self)
        p.storeBytes(of: SIMD2<Int32>(0, 1), toByteOffset: 8, as: SIMD2<Int32>.self)
        p.storeBytes(of: bloomStrength, toByteOffset: 16, as: Float.self)
        let grid = MTLSize(width: a.width, height: a.height, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        // 本体のパスが自発光を書き終えるのを待つ
        enc.barrier(afterQueueStages: .fragment, beforeStages: .dispatch, visibilityOptions: .device)
        let t = computeTable
        enc.setArgumentTable(t)
        func pass(_ pipe: MTLComputePipelineState, _ src: MTLTexture, _ dst: MTLTexture, dir: Int?) {
            t.setTexture(src.gpuResourceID, index: 0)
            t.setTexture(dst.gpuResourceID, index: 1)
            if let dir { t.setAddress(bloomParams.gpuAddress + UInt64(dir * 8), index: 0) }
            enc.setComputePipelineState(pipe)
            enc.dispatchThreads(threadsPerGrid: grid, threadsPerThreadgroup: group)
            enc.barrier(afterEncoderStages: .dispatch, beforeEncoderStages: .dispatch, visibilityOptions: .device)
        }
        pass(states.bloomDown, glow, a, dir: nil)
        pass(states.bloomBlur, a, b, dir: 0)
        pass(states.bloomBlur, b, a, dir: 1)
        enc.endEncoding()

        let rp = MTL4RenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .load
        rp.colorAttachments[0].storeAction = .store
        guard let r = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        r.barrier(afterQueueStages: .dispatch, beforeStages: .fragment, visibilityOptions: .device)
        let rt = argumentTable
        rt.setTexture(a.gpuResourceID, index: 0)
        rt.setAddress(bloomParams.gpuAddress + 16, index: 0)
        r.setArgumentTable(rt, stages: [.vertex, .fragment])
        r.setRenderPipelineState(states.bloomComposite)
        r.setCullMode(.none)
        r.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        r.endEncoding()
    }

    func encodeShadow(_ m: ModelResources) {
        guard let shadowMap else { return }
        let pass = MTL4RenderPassDescriptor()
        pass.depthAttachment.texture = shadowMap
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .store
        pass.depthAttachment.clearDepth = 1
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var uniform = FrameUniform(viewProj: matrix_identity_float4x4, lightDir: .zero, lightColor: .zero,
                                   viewport: SIMD4(0, 0, 0, m.hasSdef ? 1 : 0),
                                   ramp: .zero, extra: .zero, lightViewProj: lightViewProj(m))
        (frameUniforms.contents() + Self.shadowUniformOffset).copyMemory(from: &uniform, byteCount: MemoryLayout<FrameUniform>.stride)
        enc.setRenderPipelineState(states.shadow)
        enc.setDepthStencilState(states.shadowDepth)
        enc.setCullMode(.none)
        enc.setDepthBias(1, slopeScale: 2, clamp: 0.01)
        let t = argumentTable
        t.setAddress(frameUniforms.gpuAddress + UInt64(Self.shadowUniformOffset), index: 0)
        t.setAddress(m.positions.gpuAddress, index: 1)
        t.setAddress(m.boneIndices.gpuAddress, index: 4)
        t.setAddress(m.boneWeights.gpuAddress, index: 5)
        t.setAddress(m.skin.gpuAddress, index: 6)
        t.setAddress(m.sdef.gpuAddress, index: 11)
        enc.setArgumentTable(t, stages: [.vertex, .fragment])
        for mat in m.materialInputs where mat.indexCount > 0 && mat.diffuse.w > 0 && !m.translucent(mat) && !mat.face {
            enc.drawIndexedPrimitives(primitiveType: .triangle, indexCount: mat.indexCount, indexType: .uint32,
                                      indexBuffer: m.indices.gpuAddress + UInt64(mat.indexStart * 4),
                                      indexBufferLength: mat.indexCount * 4)
        }
        enc.endEncoding()
    }

    func attachments(width: Int, height: Int) -> (MTLTexture?, MTLTexture?) {
        let samples = states.sampleCount
        if let d = depth, let p = partIDs, d.width == width, d.height == height, d.sampleCount == samples { return (d, p) }
        let all = { [self.depth, self.partIDs, self.accum, self.reveal, self.glow, self.bloomA, self.bloomB,
                     self.msaaColor, self.msaaGlow, self.msaaPart].compactMap { $0 } }
        for old in all() { residency.removeAllocation(old) }
        func make(_ format: MTLPixelFormat, _ storage: MTLStorageMode, _ usage: MTLTextureUsage = .renderTarget,
                  scale: Int = 1, samples: Int = 1) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: max(width / scale, 1),
                                                             height: max(height / scale, 1), mipmapped: false)
            if samples > 1 {
                d.textureType = .type2DMultisample
                d.sampleCount = samples
            }
            d.usage = usage
            d.storageMode = storage
            return device.makeTexture(descriptor: d)
        }
        depth = make(RenderStates.depthFormat, samples > 1 ? .memoryless : .private, samples: samples)
        accum = make(RenderStates.accumFormat, .memoryless, samples: samples)
        reveal = make(RenderStates.revealFormat, .memoryless, samples: samples)
        partIDs = make(RenderStates.partFormat, .shared, samples > 1 ? [.renderTarget, .shaderWrite] : .renderTarget)
        glow = make(RenderStates.glowFormat, .private, [.renderTarget, .shaderRead])
        bloomA = make(RenderStates.glowFormat, .private, [.shaderRead, .shaderWrite], scale: 2)
        bloomB = make(RenderStates.glowFormat, .private, [.shaderRead, .shaderWrite], scale: 2)
        msaaColor = samples > 1 ? make(RenderStates.colorFormat, .memoryless, samples: samples) : nil
        msaaGlow = samples > 1 ? make(RenderStates.glowFormat, .memoryless, samples: samples) : nil
        msaaPart = samples > 1 ? make(RenderStates.partFormat, .private, [.renderTarget, .shaderRead], samples: samples) : nil
        for t in all() { residency.addAllocation(t) }
        residency.commit()
        return (depth, partIDs)
    }

    public func part(atPixel x: Int, _ y: Int) -> UInt8 {
        guard waitIdle(), let ids = partIDs, x >= 0, y >= 0, x < ids.width, y < ids.height else { return 0 }
        var value: UInt8 = 0
        ids.getBytes(&value, bytesPerRow: ids.width, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return value
    }
}
