import Accelerate

public typealias Chroma12 = [Float]

enum SongFeatures {
    static let onsetFPS = 100.0
    static let onsetNFFT = 2048, onsetHop = 240
    static let chromaFPS = 10.0
    static let chromaNFFT = 4096, chromaHop = 2400

    static func hann(_ n: Int) -> [Float] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(n - 1)) }
    }

    static func spectra(_ samples: [Float], _ nfft: Int, _ hop: Int) -> (values: [Float], frames: Int) {
        if samples.count < nfft { return ([], 0) }
        let fft = RealFFT(nfft)
        let window = hann(nfft)
        let frames = (samples.count - nfft) / hop + 1, bins = nfft / 2 + 1
        var out = [Float](repeating: 0, count: frames * bins)
        var input = [Float](repeating: 0, count: nfft)
        samples.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { o in
                for f in 0..<frames {
                    vDSP_vmul(s.baseAddress! + f * hop, 1, window, 1, &input, 1, vDSP_Length(nfft))
                    fft.magnitudes(input, into: o.baseAddress! + f * bins)
                }
            }
        }
        return (out, frames)
    }

    public static func onset(_ samples: [Float]) -> [Float] {
        var (spec, frames) = spectra(samples, onsetNFFT, onsetHop)
        if frames == 0 { return [] }
        let bins = onsetNFFT / 2 + 1
        var hundred: Float = 100
        vDSP_vsmul(spec, 1, &hundred, &spec, 1, vDSP_Length(spec.count))
        var n = Int32(spec.count)
        vvlog1pf(&spec, spec, &n)
        var flux = [Float](repeating: 0, count: frames)
        if frames > 1 {
            let m = (frames - 1) * bins
            var d = [Float](repeating: 0, count: m)
            var zero: Float = 0
            spec.withUnsafeBufferPointer { s in
                vDSP_vsub(s.baseAddress!, 1, s.baseAddress! + bins, 1, &d, 1, vDSP_Length(m))
            }
            vDSP_vthres(d, 1, &zero, &d, 1, vDSP_Length(m))
            d.withUnsafeBufferPointer { p in
                for f in 1..<frames { vDSP_sve(p.baseAddress! + (f - 1) * bins, 1, &flux[f], vDSP_Length(bins)) }
            }
        }
        var acc: Float = 0
        return flux.indices.map { i in
            acc += flux[i]
            if i >= 50 { acc -= flux[i - 50] }
            return max(flux[i] - acc / 50, 0)
        }
    }

    static func chroma(_ samples: [Float], rate: Int) -> [Chroma12] {
        func freq(_ k: Int) -> Float { Float(k) * Float(rate) / Float(chromaNFFT) }
        let bins: [(Int, Int)] = (1..<chromaNFFT / 2).filter { freq($0) >= 55 && freq($0) < 2000 }.map { k in
            let note = Int((12 * log2(freq(k) / 440)).rounded()) + 69
            return (k, ((note % 12) + 12) % 12)
        }
        let (spec, frames) = spectra(samples, chromaNFFT, chromaHop)
        let width = chromaNFFT / 2 + 1
        return (0..<frames).map { f in
            var c = [Float](repeating: 0, count: 12)
            for (k, pc) in bins { c[pc] += log1p(100 * spec[f * width + k]) }
            var sum: Float = 0
            for v in c { sum += v }
            let mean = sum / 12
            for i in 0..<12 { c[i] -= mean }
            var sq: Float = 0
            for v in c { sq += v * v }
            let norm = sq.squareRoot() + 1e-9
            for i in 0..<12 { c[i] /= norm }
            return c
        }
    }

    static func ncc(_ a: [Float], _ b: [Float], _ lag: Int) -> Float {
        let (i0, j0) = lag >= 0 ? (0, lag) : (-lag, 0)
        let n = min(max(a.count - i0, 0), max(b.count - j0, 0))
        if n < 16 { return 0 }
        return a.withUnsafeBufferPointer { x in
            b.withUnsafeBufferPointer { y in
                var (mx, my): (Float, Float) = (0, 0)
                for i in 0..<n { mx += x[i0 + i]; my += y[j0 + i] }
                (mx, my) = (mx / Float(n), my / Float(n))
                var (sxy, sxx, syy): (Float, Float, Float) = (0, 0, 0)
                for i in 0..<n {
                    let (u, v) = (x[i0 + i] - mx, y[j0 + i] - my)
                    sxy += u * v
                    sxx += u * u
                    syy += v * v
                }
                if sxx <= 1e-12 || syy <= 1e-12 { return 0 }
                return sxy / (sxx * syy).squareRoot()
            }
        }
    }
}

final class RealFFT {
    let n: Int
    let log2n: vDSP_Length
    let setup: FFTSetup
    var re: [Float], im: [Float]

    init(_ n: Int) {
        self.n = n
        log2n = vDSP_Length(n.trailingZeroBitCount)
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        re = [Float](repeating: 0, count: n / 2)
        im = re
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func magnitudes(_ x: [Float], into out: UnsafeMutablePointer<Float>) {
        let h = n / 2
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                x.withUnsafeBytes { vDSP_ctoz($0.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(h)) }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // zrip は 2 倍の値を返し、DC と n/2 を 0 番目の実部・虚部にまとめる
                let (dc, nyquist) = (r[0], i[0])
                r[0] = 0
                i[0] = 0
                vDSP_zvabs(&split, 1, out, 1, vDSP_Length(h))
                var half: Float = 0.5
                vDSP_vsmul(out, 1, &half, out, 1, vDSP_Length(h))
                out[0] = abs(dc) / 2
                out[h] = abs(nyquist) / 2
            }
        }
    }
}
