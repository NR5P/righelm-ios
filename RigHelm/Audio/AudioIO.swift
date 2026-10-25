import AVFoundation
import os
import RigHelmCore

/// Playout buffer for radio audio, which Wi-Fi often delivers in clumps:
/// several 20 ms packets at once, 100 ms or more apart. It waits until it
/// holds `target` before playing, and when it runs dry anyway it fades out
/// (no click), deepens itself, and fades back in. Latency it turns out not
/// to need is taken back slowly by skipping single samples. Same design as
/// the Mac app's remote player.
final class JitterBuffer {
    /// Skip one sample in this many while trimming (0.5 %: inaudible).
    private static let trimEvery = 200

    private let lock = OSAllocatedUnfairLock()
    private var ring = [Float](repeating: 0, count: 19_200)
    private var readIndex = 0
    private var count = 0
    private var playing = false
    /// Depth to build up before (re)starting.
    private var target = 2_400
    private var maxTarget = 9_600
    /// Lowest depth seen in the current window, samples played in it.
    private var low = Int.max
    private var played = 0
    private var window = 240_000
    /// Samples still to skip.
    private var trim = 0
    private var last: Float = 0
    private var gain: Float = 0
    private var gainStep: Float = 1 / 120
    /// Fade length around gaps, and samples of the next write still to fade in.
    private var fadeLength = 120
    private var fadeIn = 0

    func configure(rate: Int) {
        lock.withLockUnchecked {
            target = rate / 10 // 100 ms to start
            maxTarget = rate * 2 / 5 // may grow to 400 ms
            ring = [Float](repeating: 0, count: maxTarget * 2)
            window = rate * 10
            fadeLength = max(rate / 200, 1) // 5 ms
            gainStep = 1 / Float(fadeLength)
            readIndex = 0
            count = 0
            playing = false
            low = .max
            played = 0
            trim = 0
            last = 0
            gain = 0
            fadeIn = 0
        }
    }

    func write(_ samples: [Int16], gain: Float) {
        let scale = gain / 32768
        lock.withLockUnchecked {
            for s in samples {
                var v = Float(s) * scale
                if fadeIn > 0 {
                    v *= Float(fadeLength - fadeIn) / Float(fadeLength)
                    fadeIn -= 1
                }
                append(v)
            }
        }
    }

    /// Stand in for lost packets: silence that keeps the timing, with the
    /// audio either side faded so the gap doesn't click.
    func writeGap(_ n: Int) {
        lock.withLockUnchecked {
            let cap = ring.count
            let k = min(fadeLength, count)
            for i in 0..<k {
                ring[(readIndex + count - k + i) % cap] *= Float(k - i) / Float(k + 1)
            }
            for _ in 0..<n { append(0) }
            fadeIn = fadeLength
        }
    }

    func read(into out: UnsafeMutablePointer<Float>, count n: Int) {
        lock.withLockUnchecked {
            for i in 0..<n { out[i] = next() }
        }
    }

    // Both below run with the lock held.

    /// Queue one sample; past capacity the oldest is dropped.
    private func append(_ v: Float) {
        let cap = ring.count
        if count == cap {
            readIndex = (readIndex + 1) % cap
            count -= 1
        }
        ring[(readIndex + count) % cap] = v
        count += 1
    }

    /// The next sample to play.
    private func next() -> Float {
        if !playing && count >= target {
            playing = true
            low = .max
            played = 0
        }
        if playing {
            if count > 0 {
                var v = pop()
                played += 1
                if trim > 0 && played % Self.trimEvery == 0 && count > 0 {
                    v = pop()
                    trim -= 1
                }
                low = min(low, count)
                if played >= window {
                    // Keep half the target in hand at the lowest point.
                    trim = max(low - target / 2, 0)
                    low = .max
                    played = 0
                }
                gain = min(gain + gainStep, 1)
                last = v
                return v * gain
            }
            // Ran dry: rebuild a deeper buffer before playing again.
            playing = false
            trim = 0
            target = min(target + target / 2, maxTarget)
        }
        gain = max(gain - gainStep, 0)
        return last * gain
    }

    private func pop() -> Float {
        let v = ring[readIndex]
        readIndex = (readIndex + 1) % ring.count
        count -= 1
        return v
    }
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
