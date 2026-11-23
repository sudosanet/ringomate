import MascotCore
import AVFoundation
import Foundation
@preconcurrency import ScreenCaptureKit

/// 1 つのアプリの音から口の形を出す。録音も保存もしない。
public final class AppAudioTap: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "app.ringomate.lips", qos: .userInitiated)
    private var stream: SCStream?
    private var starting = false
    private var focus = VocalFocus()
    private var lips = LipSync()
    private var pending: [Float] = []
    private var latest: (vowels: [Float], at: Double) = ([0, 0, 0, 0, 0], 0)
    public private(set) var app: String?

    override public init() {}

    /// 0.3 秒より古ければ閉じた口。
    public func vowels(now: Double = BeatTracker.now()) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return now - latest.at < 0.3 ? latest.vowels : [0, 0, 0, 0, 0]
    }

    /// ヘルパーのプロセスも含めて聞く。
    public func start(bundleID: String) {
        lock.lock()
        guard app != bundleID || (stream == nil && !starting) else { return lock.unlock() }
        let old = stream
        (stream, app, starting) = (nil, bundleID, true)
        lock.unlock()
        old?.stopCapture { _ in }
        let base = appBundleBase(bundleID)
        SCShareableContent.getWithCompletionHandler { [weak self] content, _ in
            guard let self else { return }
            let apps = content?.applications.filter { $0.bundleIdentifier.hasPrefix(base) } ?? []
            guard let display = content?.displays.first, !apps.isEmpty else {
                self.lock.lock()
                self.starting = false
                self.lock.unlock()
                return
            }
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = Int(VocalFocus.inputRate)
            config.channelCount = 2
            (config.width, config.height) = (2, 2)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            config.showsCursor = false
            let s = SCStream(filter: SCContentFilter(display: display, including: apps, exceptingWindows: []),
                             configuration: config, delegate: self)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.queue)
            } catch {
                self.lock.lock()
                self.starting = false
                self.lock.unlock()
                return
            }
            s.startCapture { [weak self] error in
                guard let self else { return }
                self.lock.lock()
                self.starting = false
                if error == nil, self.app == bundleID { self.stream = s } else { s.stopCapture { _ in } }
                self.lock.unlock()
            }
        }
    }

    public func stop() {
        lock.lock()
        let s = stream
        (stream, app) = (nil, nil)
        latest = ([0, 0, 0, 0, 0], 0)
        lock.unlock()
        s?.stopCapture { _ in }
        queue.async { [weak self] in
            self?.focus = VocalFocus()
            self?.lips = LipSync()
            self?.pending.removeAll()
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock()
        if self.stream === stream { self.stream = nil }
        lock.unlock()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let (l, r) = Self.stereo(buffer) else { return }
        pending += focus.push(left: l, right: r)
        let hop = Int(LipSync.rate / 60)
        var v: [Float]?
        while pending.count >= LipSync.window + hop {
            pending.removeFirst(hop)
            v = lips.vowels(pending[0..<LipSync.window])
        }
        if let v {
            lock.lock()
            latest = (v, BeatTracker.now())
            lock.unlock()
        }
    }

    static func stereo(_ buffer: CMSampleBuffer) -> ([Float], [Float])? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let pcm = AVAudioFormat(streamDescription: [asbd]),
              let out = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))),
              CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(CMSampleBufferGetNumSamples(buffer)),
                                                           into: out.mutableAudioBufferList) == noErr,
              let data = out.floatChannelData
        else { return nil }
        out.frameLength = AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))
        let n = Int(out.frameLength)
        if pcm.isInterleaved {
            let c = Int(pcm.channelCount)
            let p = data[0]
            let l = (0..<n).map { p[$0 * c] }
            return (l, c > 1 ? (0..<n).map { p[$0 * c + 1] } : l)
        }
        let l = Array(UnsafeBufferPointer(start: data[0], count: n))
        return (l, pcm.channelCount > 1 ? Array(UnsafeBufferPointer(start: data[1], count: n)) : l)
    }
}
