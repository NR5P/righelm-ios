import AVFoundation
import os
import RigHelmCore

/// Holds incoming radio audio long enough to ride out Wi-Fi delivering
/// packets in clumps, and keeps latency bounded when they arrive faster
/// than they play.
final class JitterBuffer {
    private let lock = OSAllocatedUnfairLock()
    private var ring = [Float](repeating: 0, count: 48_000 * 2)
    private var readIndex = 0
    private var count = 0
    private var priming = true
    /// Start (and restart after running dry) once this much is waiting.
    private var target = 4_800
    /// More than this waiting: skip ahead to `target`.
    private var ceiling = 14_400

    func configure(rate: Int) {
        lock.withLockUnchecked {
            target = rate / 5 // 200 ms
            ceiling = rate * 3 / 5 // 600 ms
            readIndex = 0
            count = 0
            priming = true
        }
    }

    func write(_ samples: [Int16], gain: Float) {
        let scale = gain / 32768
        lock.withLockUnchecked {
            let cap = ring.count
            for s in samples {
                ring[(readIndex + count) % cap] = Float(s) * scale
                if count < cap { count += 1 } else { readIndex = (readIndex + 1) % cap }
            }
            if count > ceiling {
                let drop = count - target
                readIndex = (readIndex + drop) % cap
                count -= drop
            }
        }
    }

    func writeSilence(_ n: Int) {
        write([Int16](repeating: 0, count: n), gain: 0)
    }

    func read(into out: UnsafeMutablePointer<Float>, count n: Int) {
        lock.withLockUnchecked {
            if priming {
                guard count >= target else {
                    out.update(repeating: 0, count: n)
                    return
                }
                priming = false
            }
            let cap = ring.count
            let take = min(n, count)
            for i in 0..<take {
                out[i] = ring[(readIndex + i) % cap]
            }
            readIndex = (readIndex + take) % cap
            count -= take
            if take < n {
                (out + take).update(repeating: 0, count: n - take)
                priming = true
            }
        }
    }

    var milliseconds: Int { lock.withLockUnchecked { count } * 1000 / max(target * 5, 1) }
}

/// Plays the radio's audio and, when asked, captures the phone's
/// microphone as 20 ms frames at the stream's sample rate.
final class AudioIO {
    let buffer = JitterBuffer()
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var micPending: [Int16] = []
    private(set) var rate = RemoteProtocol.audioRate
    private(set) var running = false
    private(set) var micRunning = false

    /// Called on the audio thread with each microphone frame.
    var onMicFrame: (([Int16]) -> Void)?
    let micGain = Locked<Float>(1)
    let micLevelDb = Locked<Float>(-100)

    func start(rate: Int, mic: Bool) throws {
        stop()
        self.rate = rate
        let session = AVAudioSession.sharedInstance()
        if mic {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        } else {
            try session.setCategory(.playback, mode: .default)
        }
        try? session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)

        engine = AVAudioEngine()
        buffer.configure(rate: rate)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false) else { return }
        let buf = buffer
        let source = AVAudioSourceNode(format: format) { _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            for b in list {
                if let data = b.mData?.assumingMemoryBound(to: Float.self) {
                    buf.read(into: data, count: Int(frames))
                }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        if mic {
            try installMicTap(format: format)
        }
        engine.prepare()
        try engine.start()
        running = true
        micRunning = mic
    }

    func stop() {
        if micRunning {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.stop()
        running = false
        micRunning = false
        micPending.removeAll()
        micLevelDb.set(-100)
    }

    var volume: Float {
        get { engine.mainMixerNode.outputVolume }
        set { engine.mainMixerNode.outputVolume = newValue }
    }

    private func installMicTap(format out: AVAudioFormat) throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "RigHelm", code: 1, userInfo: [NSLocalizedDescriptionKey: "no microphone available"])
        }
        // Mono: the first channel is enough for a voice.
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: mono, to: out)
        else { return }
        converter = conv
        let frameLen = RemoteProtocol.frameLength(rate: rate)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] pcm, _ in
            guard let self, let conv = self.converter, let src = pcm.floatChannelData,
                  let monoBuf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: pcm.frameLength)
            else { return }
            monoBuf.frameLength = pcm.frameLength
            monoBuf.floatChannelData?[0].update(from: src[0], count: Int(pcm.frameLength))
            let cap = AVAudioFrameCount(Double(pcm.frameLength) * out.sampleRate / mono.sampleRate) + 64
            guard let converted = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: cap) else { return }
            var fed = false
            var error: NSError?
            conv.convert(to: converted, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return monoBuf
            }
            guard let ch = converted.floatChannelData?[0] else { return }
            let gain = self.micGain.get * 32767
            for i in 0..<Int(converted.frameLength) {
                self.micPending.append(Int16(max(-32768, min(32767, ch[i] * gain))))
            }
            while self.micPending.count >= frameLen {
                let frame = Array(self.micPending[0..<frameLen])
                self.micPending.removeFirst(frameLen)
                self.micLevelDb.set(levelDbfs(frame))
                self.onMicFrame?(frame)
            }
        }
    }
}
