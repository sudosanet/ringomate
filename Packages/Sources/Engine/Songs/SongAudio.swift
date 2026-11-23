import AVFoundation

public enum SongAudio {
    public static let rate = 24_000

    struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func load(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw Failure(description: "\(url.path): could not decode: \(error)") }
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw Failure(description: "\(url.path): could not decode: no audio")
        }
        do { try file.read(into: buf) } catch { throw Failure(description: "\(url.path): could not decode: \(error)") }
        let channels = Int(format.channelCount), n = Int(buf.frameLength)
        guard let data = buf.floatChannelData else { throw Failure(description: "\(url.path): could not decode: not float") }
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var s: Float = 0
            for c in 0..<channels { s += data[c][i] }
            mono[i] = s / Float(channels)
        }
        return try resample(mono, from: Int(format.sampleRate), to: rate)
    }

    public static func resample(_ samples: [Float], from: Int, to: Int) throws -> [Float] {
        if from == to || samples.isEmpty { return samples }
        guard let src = AVAudioFormat(standardFormatWithSampleRate: Double(from), channels: 1),
              let dst = AVAudioFormat(standardFormatWithSampleRate: Double(to), channels: 1),
              let conv = AVAudioConverter(from: src, to: dst),
              let input = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw Failure(description: "resample: \(from) → \(to)") }
        conv.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let expected = Int((Double(samples.count) * Double(to) / Double(from)).rounded(.up))
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(expected + 1024)) else {
            throw Failure(description: "resample: buffer")
        }
        nonisolated(unsafe) var given = false
        var error: NSError?
        let status = conv.convert(to: out, error: &error) { _, state in
            if given {
                state.pointee = .endOfStream
                return nil
            }
            given = true
            state.pointee = .haveData
            return input
        }
        if status == .error { throw Failure(description: "resample: \(error.map { "\($0)" } ?? "failed")") }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
}

enum DanceLength {
    static func seconds(_ url: URL) throws -> Double {
        let bytes = try BVH.gunzipIfNeeded([UInt8](Data(contentsOf: url)))
        var name = url.path.lowercased()
        if name.hasSuffix(".gz") { name.removeLast(3) }
        if name.hasSuffix(".vmd") {
            // 見出し 30 + モデル名 20、ボーンのキーの数、キーは 111 バイト（名前 15・コマ番号 u32・…）
            var r = ByteReader(bytes, pos: 50)
            let n = Int(try r.u32())
            var last: UInt32 = 0
            for _ in 0..<n {
                try r.skip(15)
                last = max(last, try r.u32())
                try r.skip(92)
            }
            return Double(last) / 30
        }
        if name.hasSuffix(".bvh") { return Double(try BVH.loadClip(String(decoding: bytes, as: UTF8.self), name: "length").1.duration) }
        if name.hasSuffix(".glb") {
            let m = try BVH.readMotionGLB(bytes)
            return Double(max(m.poses.count - 1, 0)) / Double(m.fps)
        }
        throw SongPack.Failure(description: "unknown motion file: \(url.path)")
    }
}
