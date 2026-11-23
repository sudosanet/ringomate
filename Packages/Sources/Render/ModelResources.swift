import CoreGraphics
import ImageIO
import Metal
import simd

struct MaterialUniform {
    var diffuse: SIMD4<Float>
    var ambient: SIMD4<Float>
    var specular: SIMD4<Float>
    var textures: SIMD4<Int32>
    var edgeColor: SIMD4<Float>
    var edgeParams: SIMD4<Float>
    var mtoon: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
    var look: SIMD4<Float> = .zero
}

enum ShadingPath: Int32, CaseIterable {
    case pmx = 0, mtoon = 1
}

/// 作ったものはすべて `residency` に入れる（Metal 4 は登録漏れを診断しない）。
@MainActor
final class ModelResources {
    let materialInputs: [MaterialInput]
    let shadingPath: ShadingPath
    let ramp: Ramp
    let seeThroughAlpha: Float
    let positions: MTLBuffer
    let skin: MTLBuffer
    let normals: MTLBuffer
    let smoothNormals: MTLBuffer
    let edgeScale: MTLBuffer
    let sdef: MTLBuffer
    let hasSdef: Bool
    let uvs: MTLBuffer
    let boneIndices: MTLBuffer
    let boneWeights: MTLBuffer
    let indices: MTLBuffer
    let materials: MTLBuffer
    let parts: MTLBuffer
    let textures: [MTLTexture?]
    let alphas: [TextureCache.Alpha]
    let residency: MTLResidencySet
    let height: Float
    let boundsCenter: SIMD3<Float>
    let boundsRadius: Float
    private(set) var failedTextures: [Int] = []

    init(device: MTLDevice, mesh: MeshInput, textureQuality: Int = 0) throws {
        materialInputs = mesh.materials
        ramp = mesh.ramp
        seeThroughAlpha = mesh.seeThroughAlpha
        func buffer<T>(_ array: [T], minCount: Int = 1) throws -> MTLBuffer {
            let length = max(array.count, minCount) * MemoryLayout<T>.stride
            guard let b = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw RenderError.allocation
            }
            array.withUnsafeBytes { if let p = $0.baseAddress { b.contents().copyMemory(from: p, byteCount: $0.count) } }
            return b
        }
        positions = try buffer(mesh.positions)
        skin = try buffer([simd_float4x4](repeating: matrix_identity_float4x4, count: max(mesh.boneCount, 1)))
        normals = try buffer(mesh.normals)
        smoothNormals = try buffer(mesh.smoothNormals.count == mesh.normals.count ? mesh.smoothNormals : mesh.normals)
        edgeScale = try buffer(mesh.edgeScale.count == mesh.vertexCount ? mesh.edgeScale : [Float](repeating: 1, count: mesh.vertexCount))
        hasSdef = mesh.sdef.count == mesh.vertexCount * 12
        sdef = try buffer(hasSdef ? mesh.sdef : [Float](repeating: 0, count: 12))
        uvs = try buffer(mesh.uvs)
        boneIndices = try buffer(mesh.skinIndices)
        boneWeights = try buffer(mesh.skinWeights)
        indices = try buffer(mesh.indices)
        parts = try buffer(mesh.parts.count == mesh.vertexCount ? mesh.parts : [UInt8](repeating: 2, count: mesh.vertexCount))

        var failed: [Int] = []
        var alphas: [TextureCache.Alpha] = []
        let sharp = Set(mesh.materials.filter { $0.face || $0.seeThrough }.compactMap(\.diffuseTexture))
        textures = mesh.textures.enumerated().map { i, source in
            let compress = textureQuality == 0 || (textureQuality == 1 && !sharp.contains(i))
            guard let source, let (t, alpha) = Self.makeTexture(device: device, source: source, compress: compress) else {
                if source != nil { failed.append(i) }
                alphas.append(.opaque)
                return nil
            }
            alphas.append(alpha)
            return t
        }
        self.alphas = alphas
        failedTextures = failed

        shadingPath = mesh.materials.contains { $0.mtoon.count == 16 } ? .mtoon : .pmx
        materials = try buffer(mesh.materials.map { [textures] m -> MaterialUniform in
            func has(_ i: Int?) -> Int32 { i.flatMap { textures.indices.contains($0) ? textures[$0] : nil } == nil ? 0 : 1 }
            var u = MaterialUniform(
                diffuse: m.diffuse,
                ambient: SIMD4(m.ambient, 0),
                specular: SIMD4(m.specular, m.specularPower),
                textures: SIMD4(has(m.diffuseTexture), has(m.sphereTexture),
                                has(m.toonTexture), m.sphereMode.rawValue),
                edgeColor: m.edgeColor,
                edgeParams: SIMD4(m.edge ? m.edgeSize : 0, m.face ? 1 : 0, m.mtoon.count == 16 ? 1 : 0, m.faceFeature ? 1 : 0)
            )
            u.look = SIMD4(m.noRim ? 1 : 0, m.warmShade ? 1 : 0, m.liftShade ? 1 : 0, 0)
            if m.mtoon.count == 16 {
                let v = m.mtoon
                u.mtoon = (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                           SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15]))
            }
            return u
        })

        let desc = MTLResidencySetDescriptor()
        desc.label = "model"
        residency = try device.makeResidencySet(descriptor: desc)
        for b in [positions, skin, normals, smoothNormals, edgeScale, sdef, uvs, boneIndices, boneWeights, indices, materials, parts] {
            residency.addAllocation(b)
        }
        for t in textures.compactMap({ $0 }) {
            residency.addAllocation(t)
        }
        residency.commit()

        height = stride(from: 1, to: mesh.positions.count, by: 3).map { mesh.positions[$0] }.max() ?? 20
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for i in stride(from: 0, to: mesh.positions.count, by: 3) {
            let v = SIMD3(mesh.positions[i], mesh.positions[i + 1], mesh.positions[i + 2])
            lo = simd_min(lo, v)
            hi = simd_max(hi, v)
        }
        boundsCenter = mesh.positions.isEmpty ? .zero : (lo + hi) / 2
        boundsRadius = mesh.positions.isEmpty ? 20 : max(simd_length(hi - lo) / 2 * 1.15, 1)
    }

    func texture(_ index: Int?) -> MTLTexture? {
        index.flatMap { textures.indices.contains($0) ? textures[$0] : nil }
    }

    static let maxTextureSize = 2048

    /// どちらも乗算済みのアルファで持つ。
    private static func makeTexture(device: MTLDevice, source: TextureSource, compress: Bool) -> (MTLTexture, TextureCache.Alpha)? {
        let key = TextureCache.key(source.key, maxSize: maxTextureSize)
        if compress, let cached = TextureCache.load(key), let t = astcTexture(device: device, cached) { return (t, cached.alpha) }
        guard let data = source.load(), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        if compress, let levels = TextureCache.encode(image, maxSize: maxTextureSize), let t = astcTexture(device: device, levels) {
            TextureCache.store(levels, key: key)
            return (t, levels.alpha)
        }
        return rgbaTexture(device: device, image: image).map { ($0, TextureCache.classify(image)) }
    }

    var hasGlow: Bool { materialInputs.contains { $0.sphereMode == .add && $0.sphereTexture != nil } }

    func translucent(_ m: MaterialInput) -> Bool {
        m.diffuse.w < 0.99 || m.diffuseTexture.map { alphas.indices.contains($0) && alphas[$0] == .translucent } == true
    }

    private static func astcTexture(device: MTLDevice, _ levels: TextureCache.Levels) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .astc_4x4_ldr, width: levels.width, height: levels.height, mipmapped: true)
        desc.mipmapLevelCount = levels.payloads.count
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        var (w, h) = (levels.width, levels.height)
        for (i, p) in levels.payloads.enumerated() {
            p.withUnsafeBytes { raw in
                tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: i, withBytes: raw.baseAddress!,
                            bytesPerRow: ((w + 3) / 4) * 16)
            }
            (w, h) = (max(w / 2, 1), max(h / 2, 1))
        }
        return tex
    }

    private static func rgbaTexture(device: MTLDevice, image: CGImage) -> MTLTexture? {
        var (w, h) = (image.width, image.height)
        while max(w, h) > maxTextureSize { (w, h) = (max(w / 2, 1), max(h / 2, 1)) }
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let drawn = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: true)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return tex
    }
}

enum RenderError: Error {
    case allocation
}
