import CoreGraphics
import Foundation
import Metal
import os
import QuartzCore
import simd

struct FrameUniform {
    var viewProj: simd_float4x4
    var lightDir: SIMD4<Float>
    var lightColor: SIMD4<Float>
    var viewport: SIMD4<Float>
    var ramp: SIMD4<Float>
    var extra: SIMD4<Float>
    var lightViewProj: simd_float4x4
    var look: SIMD4<Float> = .zero
    var tint: SIMD4<Float> = SIMD4(1, 1, 1, 0)
    var ground: SIMD4<Float> = .zero
}

/// 使うリソースはすべてレジデンシーセットでキューに登録する。
@MainActor
public final class Renderer {
    public let device: MTLDevice
    let queue: MTL4CommandQueue
    let allocator: MTL4CommandAllocator
    let commandBuffer: MTL4CommandBuffer
    let frameDone: MTLSharedEvent
    var frame: UInt64 = 0

    var states: RenderStates
    let compiler: MTL4Compiler
    let library: MTLLibrary
    public var antialiasing = 4 {
        didSet {
            guard antialiasing != oldValue else { return }
            guard waitIdle() else { antialiasing = oldValue; return }
            do {
                states = try RenderStates(device: device, compiler: compiler, library: library, sampleCount: antialiasing)
            } catch {
                antialiasing = states.sampleCount
            }
        }
    }
    public var oitEnabled = true
    let sampler: MTLSamplerState
    let shadowSampler: MTLSamplerState
    var shadowMap: MTLTexture?
    public var shadowEnabled = true
    public var rimStrength: Float = 0.25
    public var bloomStrength: Float = 0.8
    var bloomEnabled: Bool { bloomStrength > 0 }
    public var outlineScale: Float = 1
    public var faceShading: Float = 0.35
    public var textureQuality = 0
    public var specularStrength: Float = 1
    public var edgeTint: Float = 0.6
    public var wallpaperTint: Float = 0
    public var wallpaperColor: SIMD3<Float>? {
        didSet { tintColor = wallpaperColor.map(Self.normalizedTint) ?? SIMD3(repeating: 1) }
    }
    var tintColor = SIMD3<Float>(repeating: 1)
    public var groundShadow: SIMD3<Float>?
    var glow: MTLTexture?
    var bloomA: MTLTexture?
    var bloomB: MTLTexture?
    let computeTable: MTL4ArgumentTable
    let bloomParams: MTLBuffer
    let argumentTable: MTL4ArgumentTable
    /// 本描画と影のパスの FrameUniform を同じバッファの別の場所に置く（同じコマンドバッファで両方読む）
    let frameUniforms: MTLBuffer
    static let shadowUniformOffset = (MemoryLayout<FrameUniform>.stride + 255) & ~255
    let whiteTexture: MTLTexture
    let residency: MTLResidencySet
    var depth: MTLTexture?
    var accum: MTLTexture?
    var reveal: MTLTexture?
    var partIDs: MTLTexture?
    var msaaColor: MTLTexture?
    var msaaGlow: MTLTexture?
    var msaaPart: MTLTexture?
    var model: ModelResources?

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeMTL4CommandQueue(),
              let allocator = device.makeCommandAllocator(),
              let commandBuffer = device.makeCommandBuffer(),
              let frameDone = device.makeSharedEvent()
        else { throw RenderError.allocation }
        self.device = device
        self.queue = queue
        self.allocator = allocator
        self.commandBuffer = commandBuffer
        self.frameDone = frameDone

        let compiler = try device.makeCompiler(descriptor: MTL4CompilerDescriptor())
        let libDesc = MTL4LibraryDescriptor()
        libDesc.source = toonShaderSource
        libDesc.name = "toon"
        let library = try compiler.makeLibrary(descriptor: libDesc)
        self.compiler = compiler
        self.library = library
        states = try RenderStates(device: device, compiler: compiler, library: library, sampleCount: antialiasing)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.mipFilter = .linear
        sd.maxAnisotropy = 4
        sd.sAddressMode = .repeat
        sd.tAddressMode = .repeat
        sd.supportArgumentBuffers = true
        guard let sampler = device.makeSamplerState(descriptor: sd) else { throw RenderError.allocation }
        self.sampler = sampler
        let cd = MTLSamplerDescriptor()
        cd.minFilter = .linear
        cd.magFilter = .linear
        cd.compareFunction = .lessEqual
        cd.sAddressMode = .clampToEdge
        cd.tAddressMode = .clampToEdge
        cd.supportArgumentBuffers = true
        guard let shadowSampler = device.makeSamplerState(descriptor: cd) else { throw RenderError.allocation }
        self.shadowSampler = shadowSampler

        let at = MTL4ArgumentTableDescriptor()
        at.maxBufferBindCount = 12
        at.maxTextureBindCount = 4
        at.maxSamplerStateBindCount = 2
        argumentTable = try device.makeArgumentTable(descriptor: at)
        let ct = MTL4ArgumentTableDescriptor()
        ct.maxBufferBindCount = 1
        ct.maxTextureBindCount = 2
        computeTable = try device.makeArgumentTable(descriptor: ct)
        guard let bloomParams = device.makeBuffer(length: 64, options: .storageModeShared) else { throw RenderError.allocation }
        self.bloomParams = bloomParams

        guard let frameUniforms = device.makeBuffer(length: Self.shadowUniformOffset * 2, options: .storageModeShared)
        else { throw RenderError.allocation }
        self.frameUniforms = frameUniforms
        let wd = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        wd.storageMode = .shared
        guard let white = device.makeTexture(descriptor: wd) else { throw RenderError.allocation }
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
        whiteTexture = white

        residency = try device.makeResidencySet(descriptor: MTLResidencySetDescriptor())
        residency.addAllocation(frameUniforms)
        residency.addAllocation(white)
        residency.addAllocation(bloomParams)
        let sm = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: RenderStates.shadowSize,
                                                          height: RenderStates.shadowSize, mipmapped: false)
        sm.usage = [.renderTarget, .shaderRead]
        sm.storageMode = .private
        shadowMap = device.makeTexture(descriptor: sm)
        if let shadowMap { residency.addAllocation(shadowMap) }
        residency.commit()
        queue.addResidencySet(residency)
        TextureCache.purgeOldVersions()
    }

    /// ドローアブルはレイヤーのレジデンシーセットで常駐させる。
    public func attach(_ layer: CAMetalLayer) {
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = false
        queue.addResidencySet(layer.residencySet)
    }

    public func detach(_ layer: CAMetalLayer) {
        queue.removeResidencySet(layer.residencySet)
    }

    public var translucentMaterials: [Int] {
        guard let m = model else { return [] }
        return m.materialInputs.indices.filter { m.materialInputs[$0].indexCount > 0 && m.translucent(m.materialInputs[$0]) }
    }

    @discardableResult
    public func load(_ mesh: MeshInput) throws -> [Int] {
        guard waitIdle() else { throw Busy() }
        let m = try ModelResources(device: device, mesh: mesh, textureQuality: textureQuality)
        if let old = model { queue.removeResidencySet(old.residency) }
        queue.addResidencySet(m.residency)
        generateMipmaps(m.textures.compactMap { $0 })
        hiddenTrianglesByMaterial = [:]
        if let key = mesh.modelKey {
            let hidden = HiddenSurface.hiddenTriangles(renderer: self, model: m, mesh: mesh, poses: mesh.poses, key: key)
            let idx = m.indices.contents().bindMemory(to: UInt32.self, capacity: mesh.indices.count)
            for t in hidden { for k in 0..<3 { idx[t * 3 + k] = 0 } }
            for (i, mat) in mesh.materials.enumerated() {
                let n = hidden.filter { $0 * 3 >= mat.indexStart && $0 * 3 < mat.indexStart + mat.indexCount }.count
                if n > 0 { hiddenTrianglesByMaterial[i] = n }
            }
        }
        model = m
        return m.failedTextures
    }

    /// モデルと画面の大きさのアタッチメントを外す。次の `draw` はモデルなしで描き、アタッチメントは `load` のあとに作りなおす
    public func unload() {
        guard waitIdle() else { return }
        if let old = model { queue.removeResidencySet(old.residency) }
        model = nil
        hiddenTrianglesByMaterial = [:]
        for t in [depth, partIDs, accum, reveal, glow, bloomA, bloomB, msaaColor, msaaGlow, msaaPart].compactMap({ $0 }) {
            residency.removeAllocation(t)
        }
        (depth, partIDs, accum, reveal, glow, bloomA, bloomB) = (nil, nil, nil, nil, nil, nil, nil)
        (msaaColor, msaaGlow, msaaPart) = (nil, nil, nil)
        residency.commit()
    }

    func generateMipmaps(_ textures: [MTLTexture]) {
        let rgba = textures.filter { $0.mipmapLevelCount > 1 && $0.pixelFormat == .rgba8Unorm }
        guard !rgba.isEmpty else { return }
        submitOffscreen { cb in
            guard let enc = cb.makeComputeCommandEncoder() else { return }
            for t in rgba { enc.generateMipmaps(texture: t) }
            enc.endEncoding()
        }
    }

    @discardableResult
    func submitOffscreen(residency extra: MTLResidencySet? = nil, _ encode: (MTL4CommandBuffer) -> Void) -> Bool {
        guard waitIdle() else { return false }
        if let extra { queue.addResidencySet(extra) }
        allocator.reset()
        commandBuffer.beginCommandBuffer(allocator: allocator)
        encode(commandBuffer)
        commandBuffer.endCommandBuffer()
        queue.commit([commandBuffer])
        frame += 1
        queue.signalEvent(frameDone, value: frame)
        // ponytail: 終わらなければ extra はキューに残したまま（使用中に外さない）
        guard waitIdle() else { return false }
        if let extra { queue.removeResidencySet(extra) }
        return true
    }


    /// 隠れて消した三角形の数（材質ごと、検証の道具が読む）
    public private(set) var hiddenTrianglesByMaterial: [Int: Int] = [:]

    let startDate = Date()

    public var night = false

    public var modelHeight: Float? { model?.height }

    /// false なら GPU がまだ使っている。アロケータの reset・バッファの書き込み・レジデンシーの付け外しをしてはいけない
    @discardableResult
    func waitIdle() -> Bool {
        if frameDone.wait(untilSignaledValue: frame, timeoutMS: 1000) { return true }
        Logger(subsystem: "app.ringomate", category: "render").error("GPU has not finished frame \(self.frame) after 1 s")
        return false
    }

    public struct Busy: Error {}

}
