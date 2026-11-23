import simd

/// 四元数は (x, y, z, w)、行列は列優先。
enum Math {
    static let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    static let tau = 2 * Float.pi

    @inline(__always) static func mul(_ a: simd_quatf, _ b: simd_quatf) -> simd_quatf { a * b }
    @inline(__always) static func mul(_ a: simd_float4x4, _ b: simd_float4x4) -> simd_float4x4 { a * b }
    @inline(__always) static func mulTranslation(_ a: simd_float4x4, _ t: SIMD3<Float>) -> simd_float4x4 { a * translation(t) }
    @inline(__always) static func translationMul(_ t: SIMD3<Float>, _ b: simd_float4x4) -> simd_float4x4 { translation(t) * b }
    @inline(__always) static func rotate(_ q: simd_quatf, _ v: SIMD3<Float>) -> SIMD3<Float> { q.act(v) }
    @inline(__always) static func inverse(_ q: simd_quatf) -> simd_quatf { q.inverse }
    @inline(__always) static func inverse(_ m: simd_float4x4) -> simd_float4x4 { m.inverse }
    static func axisAngle(_ axis: SIMD3<Float>, _ angle: Float) -> simd_quatf { simd_quatf(angle: angle, axis: axis) }
    static func rotX(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(1, 0, 0)) }
    static func rotY(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 1, 0)) }
    static func rotZ(_ a: Float) -> simd_quatf { simd_quatf(angle: a, axis: SIMD3(0, 0, 1)) }
    static func rotationArc(_ from: SIMD3<Float>, _ to: SIMD3<Float>) -> simd_quatf { simd_quatf(from: from, to: to) }
    static func slerp(_ a: simd_quatf, _ b: simd_quatf, _ s: Float) -> simd_quatf { simd_slerp(a, b, s) }
    static func lerp(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ s: Float) -> SIMD3<Float> { simd_mix(a, b, SIMD3(repeating: s)) }
    static func angleBetween(_ a: simd_quatf, _ b: simd_quatf) -> Float { 2 * acos(min(abs(simd_dot(a.vector, b.vector)), 1)) }

    static func matrix(_ q: simd_quatf, _ t: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    static func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(t, 1)
        return m
    }

    static func point(_ m: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> { (m * SIMD4(p, 1)).xyz }
    static func transformVector(_ m: simd_float4x4, _ v: SIMD3<Float>) -> SIMD3<Float> { (m * SIMD4(v, 0)).xyz }
    static func mat3(_ m: simd_float4x4) -> simd_float3x3 { simd_float3x3(m.columns.0.xyz, m.columns.1.xyz, m.columns.2.xyz) }

    static func rotationAxes(_ x: SIMD3<Float>, _ y: SIMD3<Float>, _ z: SIMD3<Float>) -> simd_quatf { simd_quatf(simd_float3x3(x, y, z)) }
    static func rotationOf(_ m: simd_float4x4) -> simd_quatf { scaleRotationTranslation(m).1 }

    static func scaleRotationTranslation(_ m: simd_float4x4) -> (SIMD3<Float>, simd_quatf, SIMD3<Float>) {
        let sx = simd_length(m.columns.0.xyz) * (simd_determinant(mat3(m)) < 0 ? -1 : 1)
        let sy = simd_length(m.columns.1.xyz), sz = simd_length(m.columns.2.xyz)
        let r = simd_float3x3(m.columns.0.xyz / sx, m.columns.1.xyz / sy, m.columns.2.xyz / sz)
        return (SIMD3(sx, sy, sz), simd_normalize(simd_quatf(r)), m.columns.3.xyz)
    }

    static func transform(_ m: simd_float4x4) -> (SIMD3<Float>, simd_quatf) {
        let (_, q, t) = scaleRotationTranslation(m)
        return (t, q)
    }

    static func transformMatrix(_ t: (SIMD3<Float>, simd_quatf)) -> simd_float4x4 { matrix(t.1, t.0) }

    /// R = Ry·Rx·Rz。
    static func quatEulerYXZ(_ y: Float, _ x: Float, _ z: Float) -> simd_quatf { rotY(y) * rotX(x) * rotZ(z) }

    /// R = Ry·Rx·Rz の角度を (x, y, z) で。
    static func eulerYXZ(_ q: simd_quatf) -> SIMD3<Float> {
        let m = simd_float3x3(q)  // m[列][行]
        return SIMD3(asin(max(-1, min(1, -m[2][1]))), atan2(m[2][0], m[2][2]), atan2(m[0][1], m[1][1]))
    }


    static func normalize(_ v: SIMD3<Float>, or fallback: SIMD3<Float>) -> SIMD3<Float> { tryNormalize(v) ?? fallback }
    static func normalizeOrZero(_ v: SIMD3<Float>) -> SIMD3<Float> { normalize(v, or: .zero) }
    static func tryNormalize(_ v: SIMD3<Float>) -> SIMD3<Float>? {
        let r = 1 / simd_length(v)
        return r.isFinite && r > 0 ? v * r : nil
    }

    static func clampLengthMax(_ v: SIMD3<Float>, _ m: Float) -> SIMD3<Float> {
        let l = simd_length(v)
        return l > m ? v * (m / l) : v
    }

    static func radians(_ d: Float) -> Float { d * .pi / 180 }

    /// NaN はそのまま返す。
    static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { x < lo ? lo : (x > hi ? hi : x) }
    /// +0 は 1、−0 は −1。
    static func signum(_ x: Float) -> Float { x.isNaN ? x : (x.sign == .minus ? -1 : 1) }
    static func fract(_ x: Float) -> Float { x - x.rounded(.towardZero) }
    static func remEuclid(_ x: Float, _ m: Float) -> Float {
        let r = x.truncatingRemainder(dividingBy: m)
        return r < 0 ? r + abs(m) : r
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
