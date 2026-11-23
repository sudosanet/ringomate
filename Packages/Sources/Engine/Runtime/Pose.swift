import simd

struct Pose: Sendable {
    var localOffsets: [SIMD3<Float>]
    var localRotations: [simd_quatf]
    var localScales: [SIMD3<Float>]
    var appendOffsets: [SIMD3<Float>]
    var appendRotations: [simd_quatf]
    var ikRotations: [simd_quatf]
    var morphWeights: [Float]
    var ikEnabled: [Bool]
    internal(set) var world: [simd_float4x4]
    internal(set) var skinning: [simd_float4x4]


    init(bones: Int, morphs: Int, iks: Int) {
        localOffsets = Array(repeating: .zero, count: bones)
        localRotations = Array(repeating: Math.identity, count: bones)
        localScales = Array(repeating: SIMD3(repeating: 1), count: bones)
        appendOffsets = Array(repeating: .zero, count: bones)
        appendRotations = Array(repeating: Math.identity, count: bones)
        ikRotations = Array(repeating: Math.identity, count: bones)
        morphWeights = Array(repeating: 0, count: morphs)
        ikEnabled = Array(repeating: true, count: iks)
        world = Array(repeating: matrix_identity_float4x4, count: bones)
        skinning = Array(repeating: matrix_identity_float4x4, count: bones)
    }

    mutating func resetLocal() {
        for i in localOffsets.indices {
            localOffsets[i] = .zero
            localRotations[i] = Math.identity
            localScales[i] = SIMD3(repeating: 1)
            appendOffsets[i] = .zero
            appendRotations[i] = Math.identity
            ikRotations[i] = Math.identity
        }
        for i in morphWeights.indices { morphWeights[i] = 0 }
        for i in ikEnabled.indices { ikEnabled[i] = true }
    }

    mutating func resetAppend(_ b: Int) {
        appendOffsets[b] = .zero
        appendRotations[b] = Math.identity
    }
}
