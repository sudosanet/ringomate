import CoreGraphics
import Foundation
import Metal
import os
import QuartzCore
import simd

extension Renderer {
    public func draw(
        _ layer: CAMetalLayer,
        placement: Placement?,
        update: (_ skin: UnsafeMutableRawBufferPointer, _ positions: UnsafeMutableRawBufferPointer) -> Void = { _, _ in }
    ) {
        // ponytail: 単一アロケータ・単一バッファを前フレームの完了待ちで使い回す（メインスレッドでブロック）。
        guard waitIdle() else { return }
        let model = placement == nil ? nil : self.model
        if let model {
            update(UnsafeMutableRawBufferPointer(start: model.skin.contents(), count: model.skin.length),
                   UnsafeMutableRawBufferPointer(start: model.positions.contents(), count: model.positions.length))
        }
        guard let drawable = layer.nextDrawable() else { return }
        submit(target: drawable.texture, model: model, placement: placement, size: layer.bounds.size, beforeCommit: {
            queue.waitForDrawable(drawable)
        }, afterCommit: {
            queue.signalDrawable(drawable)
        })
        // presentsWithTransaction のフレームは、トランザクションの確定までに絵ができているよう GPU を待つ
        if layer.presentsWithTransaction { waitIdle() }
        drawable.present()
    }

    func submit(
        target: MTLTexture, model: ModelResources?, placement: Placement?, size: CGSize,
        beforeCommit: () -> Void = {}, afterCommit: () -> Void = {}
    ) {
        let pass = MTL4RenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let msaa = model != nil && states.sampleCount > 1
        if model != nil {
            let (depth, ids) = attachments(width: target.width, height: target.height)
            if msaa {
                pass.colorAttachments[0].texture = msaaColor
                pass.colorAttachments[0].resolveTexture = target
                pass.colorAttachments[0].storeAction = .multisampleResolve
            }
            pass.colorAttachments[1].texture = msaa ? msaaPart : ids
            pass.colorAttachments[1].loadAction = .clear
            pass.colorAttachments[1].storeAction = .store
            pass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[2].texture = accum
            pass.colorAttachments[2].loadAction = .clear
            pass.colorAttachments[2].storeAction = .dontCare
            pass.colorAttachments[2].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[3].texture = reveal
            pass.colorAttachments[3].loadAction = .clear
            pass.colorAttachments[3].storeAction = .dontCare
            pass.colorAttachments[3].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
            let keepGlow = model?.hasGlow == true && bloomEnabled
            pass.colorAttachments[4].texture = msaa ? msaaGlow : glow
            pass.colorAttachments[4].loadAction = .clear
            if msaa {
                pass.colorAttachments[4].resolveTexture = glow
                pass.colorAttachments[4].storeAction = keepGlow ? .multisampleResolve : .dontCare
            } else {
                pass.colorAttachments[4].storeAction = keepGlow ? .store : .dontCare
            }
            pass.colorAttachments[4].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.stencilAttachment.texture = depth
            pass.stencilAttachment.loadAction = .clear
            pass.stencilAttachment.storeAction = .dontCare
            pass.stencilAttachment.clearStencil = 0
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1
        }

        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)
        if let model, placement != nil, shadowEnabled { encodeShadow(model) }
        if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
            // 影のパスが書いたシャドウマップを、このパスのフラグメントで読む前に待つ（Metal 4 は明示的なバリア）
            enc.barrier(afterQueueStages: [.vertex, .fragment], beforeStages: .fragment, visibilityOptions: .device)
            if let model, let placement {
                encode(model, placement: placement, size: size,
                       pixelScale: Float(target.width) / Float(max(size.width, 1)), into: enc)
            }
            enc.endEncoding()
        }
        if msaa { encodePartResolve() }
        if let model, placement != nil, model.hasGlow, bloomEnabled { encodeBloom(target: target) }
        commandBuffer.endCommandBuffer()

        beforeCommit()
        queue.commit([commandBuffer])
        afterCommit()
        frame += 1
        queue.signalEvent(frameDone, value: frame)
    }

    func encode(_ m: ModelResources, placement: Placement, size: CGSize, pixelScale: Float,
                        into enc: MTL4RenderCommandEncoder) {
        let viewProj = Self.viewProj(placement, size: size)
        var uniform = FrameUniform(
            viewProj: viewProj,
            lightDir: SIMD4(simd_normalize(SIMD3<Float>(-0.5, -1, 0.5)), faceShading),
            lightColor: SIMD4(repeating: 154.0 / 255.0),
            viewport: SIMD4(Float(size.width) * pixelScale, Float(size.height) * pixelScale, pixelScale * 2 * outlineScale, m.hasSdef ? 1 : 0),
            ramp: SIMD4(night ? m.ramp.night : m.ramp.day, m.ramp.softness),
            extra: SIMD4(m.seeThroughAlpha, rimStrength, shadowEnabled ? 1 : 0,
                         Float(Date().timeIntervalSince(startDate).truncatingRemainder(dividingBy: 3600))),
            lightViewProj: lightViewProj(m),
            look: SIMD4(specularStrength, edgeTint, wallpaperColor == nil ? 0 : wallpaperTint, 0),
            tint: SIMD4(tintColor, 0),
            ground: groundShadow.map { SIMD4($0.x, $0.y, m.height * 0.2, $0.z) } ?? .zero
        )
        let shading = states.shading[m.shadingPath] ?? states.shading[.pmx]!
        frameUniforms.contents().copyMemory(from: &uniform, byteCount: MemoryLayout<FrameUniform>.stride)

        enc.setFrontFacing(.clockwise)
        enc.setStencilReferenceValue(1)
        let t = argumentTable
        t.setAddress(frameUniforms.gpuAddress, index: 0)
        t.setAddress(m.positions.gpuAddress, index: 1)
        t.setAddress(m.normals.gpuAddress, index: 2)
        t.setAddress(m.uvs.gpuAddress, index: 3)
        t.setAddress(m.boneIndices.gpuAddress, index: 4)
        t.setAddress(m.boneWeights.gpuAddress, index: 5)
        t.setAddress(m.skin.gpuAddress, index: 6)
        t.setAddress(m.parts.gpuAddress, index: 8)
        t.setAddress(m.smoothNormals.gpuAddress, index: 9)
        t.setAddress(m.edgeScale.gpuAddress, index: 10)
        t.setAddress(m.sdef.gpuAddress, index: 11)
        t.setSamplerState(sampler.gpuResourceID, index: 0)
        t.setSamplerState(shadowSampler.gpuResourceID, index: 1)
        if let shadowMap { t.setTexture(shadowMap.gpuResourceID, index: 3) }
        enc.setArgumentTable(t, stages: [.vertex, .fragment])

        func draw(_ i: Int, _ mat: MaterialInput, textured: Bool = true, cull: MTLCullMode? = nil) {
            t.setAddress(m.materials.gpuAddress + UInt64(i * MemoryLayout<MaterialUniform>.stride), index: 7)
            if textured {
                t.setTexture((m.texture(mat.diffuseTexture) ?? whiteTexture).gpuResourceID, index: 0)
                t.setTexture((m.texture(mat.sphereTexture) ?? whiteTexture).gpuResourceID, index: 1)
                t.setTexture((m.texture(mat.toonTexture) ?? whiteTexture).gpuResourceID, index: 2)
            }
            enc.setCullMode(cull ?? (mat.doubleSided ? .none : .back))
            enc.drawIndexedPrimitives(
                primitiveType: .triangle, indexCount: mat.indexCount, indexType: .uint32,
                indexBuffer: m.indices.gpuAddress + UInt64(mat.indexStart * 4), indexBufferLength: mat.indexCount * 4
            )
        }
        let visible = m.materialInputs.enumerated().filter { $0.element.indexCount > 0 && $0.element.diffuse.w > 0 }
        let translucent = visible.filter { m.translucent($0.element) }
        let solid = visible.filter { !m.translucent($0.element) }

        // 足元の影は本体より先に、深度を見ずに描く
        if uniform.ground.w > 0 {
            enc.setRenderPipelineState(states.ground)
            enc.setDepthStencilState(states.compositeDepth)
            enc.setCullMode(.none)
            enc.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.setRenderPipelineState(shading.toon)
        for (i, mat) in solid {
            enc.setDepthStencilState(mat.bangs ? states.bangsDepth : states.opaqueDepth)
            draw(i, mat)
        }
        enc.setRenderPipelineState(states.edge)
        enc.setDepthStencilState(states.edgeDepth)
        for (i, mat) in visible where mat.edge && mat.edgeSize > 0 { draw(i, mat, textured: edgeTint > 0, cull: .front) }
        if !translucent.isEmpty {
            enc.setRenderPipelineState(oitEnabled ? shading.oit : shading.toon)
            for (i, mat) in translucent {
                enc.setDepthStencilState(mat.bangs ? states.translucentBangsDepth : states.translucentDepth)
                draw(i, mat)
            }
            if oitEnabled {
                enc.setRenderPipelineState(states.composite)
                enc.setDepthStencilState(states.compositeDepth)
                enc.setCullMode(.none)
                enc.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
            }
        }
        if m.seeThroughAlpha > 0 {
            enc.setRenderPipelineState(shading.seeThrough)
            enc.setDepthStencilState(states.seeThroughDepth)
            for (i, mat) in visible where mat.seeThrough { draw(i, mat) }
        }
    }
}
