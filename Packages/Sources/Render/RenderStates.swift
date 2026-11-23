import Metal

@MainActor
struct RenderStates {
    static let colorFormat = MTLPixelFormat.bgra8Unorm
    static let partFormat = MTLPixelFormat.r8Uint
    static let accumFormat = MTLPixelFormat.rgba16Float
    static let revealFormat = MTLPixelFormat.r8Unorm
    static let glowFormat = MTLPixelFormat.rgba16Float
    static let depthFormat = MTLPixelFormat.depth32Float_stencil8

    struct Shading {
        let toon: MTLRenderPipelineState
        let seeThrough: MTLRenderPipelineState
        let oit: MTLRenderPipelineState
    }
    let shading: [ShadingPath: Shading]
    let edge: MTLRenderPipelineState
    let ground: MTLRenderPipelineState
    let composite: MTLRenderPipelineState
    let shadow: MTLRenderPipelineState
    let shadowDepth: MTLDepthStencilState
    static let shadowSize = 2048
    let bloomDown: MTLComputePipelineState
    let bloomBlur: MTLComputePipelineState
    let bloomComposite: MTLRenderPipelineState
    let partResolve: MTLComputePipelineState
    let sampleCount: Int

    let opaqueDepth: MTLDepthStencilState
    let bangsDepth: MTLDepthStencilState
    let seeThroughDepth: MTLDepthStencilState
    let edgeDepth: MTLDepthStencilState
    let translucentDepth: MTLDepthStencilState
    let translucentBangsDepth: MTLDepthStencilState
    let compositeDepth: MTLDepthStencilState

    private enum Target { case color, oit, compositeOnly, depthOnly, bloom }

    init(device: MTLDevice, compiler: MTL4Compiler, library: MTLLibrary, sampleCount: Int = 1) throws {
        self.sampleCount = sampleCount
        func function(_ name: String) -> MTL4LibraryFunctionDescriptor {
            let f = MTL4LibraryFunctionDescriptor()
            f.name = name
            f.library = library
            return f
        }
        func specialized(_ name: String, _ path: ShadingPath?) -> MTL4FunctionDescriptor {
            guard let path else { return function(name) }
            let values = MTLFunctionConstantValues()
            var v = path.rawValue
            values.setConstantValue(&v, type: .int, index: 0)
            let f = MTL4SpecializedFunctionDescriptor()
            f.functionDescriptor = function(name)
            f.constantValues = values
            return f
        }
        func pipeline(_ vertex: String, _ fragment: String, _ target: Target, path: ShadingPath? = nil,
                      alphaToCoverage: Bool = false) throws -> MTLRenderPipelineState {
            let pd = MTL4RenderPipelineDescriptor()
            if [.color, .oit, .compositeOnly].contains(target) {
                pd.rasterSampleCount = sampleCount
                if alphaToCoverage && sampleCount > 1 { pd.alphaToCoverageState = .enabled }
            }
            pd.vertexFunctionDescriptor = function(vertex)
            pd.fragmentFunctionDescriptor = specialized(fragment, path)
            let formats: [MTLPixelFormat] = switch target {
            case .depthOnly: []
            case .bloom: [Self.colorFormat]
            default: [Self.colorFormat, Self.partFormat, Self.accumFormat, Self.revealFormat, Self.glowFormat]
            }
            for (i, f) in formats.enumerated() {
                pd.colorAttachments[i].pixelFormat = f
                pd.colorAttachments[i].writeMask = []
            }
            func premultiplied(_ i: Int) {
                let c = pd.colorAttachments[i]!
                c.writeMask = .all
                c.blendingState = .enabled
                c.sourceRGBBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            switch target {
            case .color:
                premultiplied(0)
                pd.colorAttachments[1].writeMask = .all
                premultiplied(4)
            case .oit:
                pd.colorAttachments[1].writeMask = .all
                let accum = pd.colorAttachments[2]!
                accum.writeMask = .all
                accum.blendingState = .enabled
                accum.sourceRGBBlendFactor = .one
                accum.destinationRGBBlendFactor = .one
                accum.sourceAlphaBlendFactor = .one
                accum.destinationAlphaBlendFactor = .one
                let reveal = pd.colorAttachments[3]!
                reveal.writeMask = .all
                reveal.blendingState = .enabled
                reveal.sourceRGBBlendFactor = .zero
                reveal.destinationRGBBlendFactor = .oneMinusSourceColor
                reveal.sourceAlphaBlendFactor = .zero
                reveal.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            case .compositeOnly:
                premultiplied(0)
            case .depthOnly:
                break
            case .bloom:
                pd.colorAttachments[0].writeMask = .all
            }
            return try compiler.makeRenderPipelineState(descriptor: pd)
        }
        var shading: [ShadingPath: Shading] = [:]
        for path in ShadingPath.allCases {
            shading[path] = Shading(toon: try pipeline("toon_vertex", "toon_fragment", .color, path: path, alphaToCoverage: true),
                                    seeThrough: try pipeline("toon_vertex", "see_fragment", .color, path: path),
                                    oit: try pipeline("toon_vertex", "oit_fragment", .oit, path: path))
        }
        self.shading = shading
        edge = try pipeline("edge_vertex", "edge_fragment", .color)
        ground = try pipeline("ground_vertex", "ground_fragment", .color)
        composite = try pipeline("composite_vertex", "composite_fragment", .compositeOnly)
        shadow = try pipeline("shadow_vertex", "shadow_fragment", .depthOnly)
        bloomComposite = try pipeline("composite_vertex", "bloom_composite", .bloom)
        func compute(_ name: String) throws -> MTLComputePipelineState {
            let cd = MTL4ComputePipelineDescriptor()
            cd.computeFunctionDescriptor = function(name)
            return try compiler.makeComputePipelineState(descriptor: cd)
        }
        bloomDown = try compute("bloom_down")
        bloomBlur = try compute("bloom_blur")
        partResolve = try compute("part_resolve")

        func depth(_ compare: MTLCompareFunction, write: Bool,
                   stencil: (MTLCompareFunction, MTLStencilOperation)? = nil) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            if let (test, pass) = stencil {
                let st = MTLStencilDescriptor()
                st.stencilCompareFunction = test
                st.depthStencilPassOperation = pass
                d.frontFaceStencil = st
                d.backFaceStencil = st
            }
            guard let s = device.makeDepthStencilState(descriptor: d) else { throw RenderError.allocation }
            return s
        }
        opaqueDepth = try depth(.lessEqual, write: true)
        bangsDepth = try depth(.lessEqual, write: true, stencil: (.always, .replace))
        seeThroughDepth = try depth(.always, write: false, stencil: (.equal, .keep))
        edgeDepth = try depth(.less, write: false)
        translucentDepth = try depth(.lessEqual, write: false)
        translucentBangsDepth = try depth(.lessEqual, write: false, stencil: (.always, .replace))
        compositeDepth = try depth(.always, write: false)
        shadowDepth = try depth(.lessEqual, write: true)
    }
}
