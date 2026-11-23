import Foundation
import simd

/// D3DX と同じ計算の順を写す。CCD で丸めの差が積もるので式の順を変えず、正規化もしない。
enum MMDMath {
    /// D3DX の引数の順: `b * a` を返す。
    static func multiply(_ a: simd_quatf, _ b: simd_quatf) -> simd_quatf {
        let (ax, ay, az, aw) = (a.imag.x, a.imag.y, a.imag.z, a.real)
        let (bx, by, bz, bw) = (b.imag.x, b.imag.y, b.imag.z, b.real)
        return simd_quatf(ix: ((by * az + bx * aw) - bz * ay) + bw * ax,
                          iy: ((by * aw - bx * az) + bz * ax) + bw * ay,
                          iz: ((-by * ax + bx * ay) + bz * aw) + bw * az,
                          r: ((-by * ay - bx * ax) - bz * az) + bw * aw)
    }

    static func rotationMatrix(_ q: simd_quatf) -> simd_float4x4 {
        let (x, y, z, w) = (q.imag.x, q.imag.y, q.imag.z, q.real)
        let xx = x * (x + x), yy = y * (y + y), zz = z * (z + z)
        let xy = x * (y + y), xz = x * (z + z), yz = y * (z + z)
        let wx = w * (x + x), wy = w * (y + y), wz = w * (z + z)
        return simd_float4x4(SIMD4((1 - yy) - zz, xy + wz, xz - wy, 0), SIMD4(xy - wz, (1 - xx) - zz, yz + wx, 0),
                             SIMD4(xz + wy, yz - wx, (1 - xx) - yy, 0), SIMD4(0, 0, 0, 1))
    }

    /// f64 で計算して丸める（Windows の atan2f と同じ丸め）。
    static func atan2(_ y: Float, _ x: Float) -> Float { Float(Foundation.atan2(Double(y), Double(x))) }

    static func axisRotation(_ axis: Int, _ angle: Float) -> simd_float4x4 {
        let s = Float(sin(Double(angle))), c = Float(cos(Double(angle)))
        switch axis {
        case 0: return simd_float4x4(SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1))
        case 1: return simd_float4x4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))
        default: return simd_float4x4(SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
        }
    }

    static func quaternion(_ matrix: simd_float4x4) -> simd_quatf {
        let m = [matrix.columns.0.xyz, matrix.columns.1.xyz, matrix.columns.2.xyz]
        var q: [Float] = [0, 0, 0, 0]
        let trace = m[0][0] + m[1][1] + m[2][2]
        if trace >= 0 {
            let s = (trace + 1).squareRoot()
            q[3] = s * 0.5
            let scale = 0.5 / s
            q[0] = (m[1][2] - m[2][1]) * scale
            q[1] = (m[2][0] - m[0][2]) * scale
            q[2] = (m[0][1] - m[1][0]) * scale
        } else {
            var i = 0
            if m[1][1] > m[0][0] { i = 1 }
            if m[2][2] > m[i][i] { i = 2 }
            let j = (i + 1) % 3, k = (j + 1) % 3
            let s = (m[i][i] - m[j][j] - m[k][k] + 1).squareRoot()
            q[i] = s * 0.5
            let scale = 0.5 / s
            q[3] = (m[j][k] - m[k][j]) * scale
            q[j] = (m[i][j] + m[j][i]) * scale
            q[k] = (m[i][k] + m[k][i]) * scale
        }
        return simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3])
    }

    static func scaleRotation(_ rotation: simd_quatf, _ ratio: Float) -> simd_quatf {
        let q = quaternion(rotationMatrix(rotation))
        let w = min(max(q.real, -1), 1)
        var angle = acos(w)
        if w < 0 { angle -= Float(bitPattern: 0x4048_f5c3) }
        let length = (q.imag.x * q.imag.x + q.imag.y * q.imag.y + q.imag.z * q.imag.z).squareRoot()
        if angle == 0 || length < .ulpOfOne { return Math.identity }
        let scaled = angle * ratio
        let scale = sin(scaled) / length
        return simd_quatf(ix: q.imag.x * scale, iy: q.imag.y * scale, iz: q.imag.z * scale, r: cos(scaled))
    }
}
