import AVFoundation
import os
import RigHelmCore

/// Playout buffer for radio audio, which Wi-Fi often delivers in clumps:
/// several 20 ms packets at once, 100 ms or more apart. It waits until it
/// holds `target` before playing, and when it runs dry anyway it fades out
/// (no click), deepens itself, and fades back in.
///
/// The station's sound card and the phone never run at quite the same rate
/// (a ThinkPad station measured 0.4 to 0.9 % slow). Without allowing for
/// it a slow station drains any buffer, however deep, and drops out every
/// half minute. So playback speed is the measured rate difference (samples
/// received against samples played over the last half minute or so: long
/// enough for clumps to average out, short enough to follow a station whose
/// USB audio loses more at some times than others) plus a gentle pull
/// toward `target`, never more than 3 % off.
final class JitterBuffer {
    /// Most the playback speed may move from 1.
    private static let maxSkew = 0.03

    private let lock = OSAllocatedUnfairLock()
    private var ring = [Float](repeating: 0, count: 19_200)
    private var readIndex = 0
    private var count = 0
    private var playing = false
    /// Depth to build up before (re)starting, and to hold while playing.
    private var target = 2_400
    private var minTarget = 2_400
    private var maxTarget = 9_600
    private var rate = 0
    /// Depth smoothed over about 2 s, so a clump doesn't swing the speed.
    private var smoothed = 0.0
    private var smoothing = 1.0 / 48_000
    /// Measured rate difference between the station and the phone, and
    /// the counts behind it: samples arriving and samples played, both only
    /// while playing (prebuffering would count as a fast station), both
    /// fading by 3 % a second. The difference is kept across restarts.
    private var drift = 0.0
    private var received = 0.0
    private var ticks = 0.0
    private var sinceFade = 0
    /// Playback speed now, and the position between the next two samples.
    private var speed = 1.0
    private var frac = 0.0
    /// Samples played since the last dropout, to give back depth that a
    /// long clean spell shows isn't needed.
    private var sinceDry = 0
    private var last: Float = 0
    private var gain: Float = 0
    private var gainStep: Float = 1 / 240
    /// Fade length around gaps, and samples of the next write still to fade in.
    private var fadeLength = 240
    private var fadeIn = 0
    /// Times playback ran dry since the stream started.
    private var dryCount = 0

    var dropouts: Int { lock.withLockUnchecked { dryCount } }

    func configure(rate: Int) {
        lock.withLockUnchecked {
            // An audio restart (route change, interruption) keeps the depth
            // and drift already learned: starting over means the same
            // dropouts again until it relearns.
            if rate != self.rate {
                self.rate = rate
                target = rate / 10 // 100 ms to start
                drift = 0
                dryCount = 0
            }
            // Start from the last difference, worth 10 s of evidence.
            ticks = Double(rate * 10)
            received = ticks * (1 + drift)
            sinceFade = 0
            minTarget = rate / 10
            maxTarget = rate * 2 / 5 // may grow to 400 ms
            ring = [Float](repeating: 0, count: maxTarget * 2)
            smoothing = 1 / (2 * Double(rate))
            fadeLength = max(rate / 100, 1) // 10 ms
            gainStep = 1 / Float(fadeLength)
            readIndex = 0
            count = 0
            playing = false
            smoothed = Double(target)
            speed = 1
            frac = 0
            sinceDry = 0
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
                #if DEBUG
                DebugTap.shared?.arrived(v)
                #endif
                append(v)
            }
        }
    }

    /// Stand in for lost packets: silence that keeps the timing, with the
    /// audio either side faded so the gap doesn't click. With `n` 0 the
    /// two sides are just faded together, for losses too long to fill.
    func writeGap(_ n: Int) {
        lock.withLockUnchecked {
            let cap = ring.count
            let k = min(fadeLength, count)
            for i in 0..<k {
                ring[(readIndex + count - k + i) % cap] *= Float(k - i) / Float(k + 1)
            }
            for _ in 0..<n {
                #if DEBUG
                DebugTap.shared?.arrived(0)
                #endif
                append(0)
            }
            fadeIn = fadeLength
        }
    }

    func read(into out: UnsafeMutablePointer<Float>, count n: Int) {
        lock.withLockUnchecked {
            for i in 0..<n { out[i] = next() }
        }
    }

    // All below run with the lock held.

    /// Queue one sample; past capacity the oldest is dropped.
    private func append(_ v: Float) {
        if playing { received += 1 }
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
            frac = 0
        }
        if playing {
            // Two samples to interpolate between.
            if count >= 2 {
                let a = ring[readIndex], b = ring[(readIndex + 1) % ring.count]
                let v = a + (b - a) * Float(frac)
                steer()
                frac += speed
                while frac >= 1 && count >= 2 {
                    readIndex = (readIndex + 1) % ring.count
                    count -= 1
                    frac -= 1
                }
                gain = min(gain + gainStep, 1)
                last = v
                return v * gain
            }
            // Ran dry: rebuild a deeper buffer before playing again.
            playing = false
            dryCount += 1
            sinceDry = 0
            target = min(target + target / 2, maxTarget)
        }
        gain = max(gain - gainStep, 0)
        return last * gain
    }

    /// Set the playback speed: the clocks' measured difference, plus up to
    /// 1 % more to bring the depth back to `target`.
    private func steer() {
        ticks += 1
        sinceFade += 1
        if sinceFade >= rate {
            sinceFade = 0
            received *= 0.97
            ticks *= 0.97
        }
        smoothed += (Double(count) - smoothed) * smoothing
        drift = max(min((received - ticks) / ticks, Self.maxSkew), -Self.maxSkew)
        // Depth error in units of 100 ms, so it behaves the same at any target.
        let err = (smoothed - Double(target)) / Double(rate / 10)
        let pull = max(min(err * 0.005, 0.01), -0.01)
        speed = 1 + max(min(drift + pull, Self.maxSkew), -Self.maxSkew)
        // Five minutes without a dropout: try 10 % less latency. Sooner
        // trims it below what the next Wi-Fi gap needs.
        sinceDry += 1
        if sinceDry >= rate * 300 {
            sinceDry = 0
            target = max(target - target / 10, minTarget)
        }
    }
}

/// A CW sidetone mixed into playback while the phone key is down: over a
/// network the radio's own sidetone comes back too late to send by.
final class Sidetone {
    private struct State {
        var enabled = false
        var down = false
        var hz: Float = 700
        var volume: Float = 0.3
        var phase: Float = 0
        var amp: Float = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setEnabled(_ on: Bool) {
        state.withLock { $0.enabled = on }
    }

    /// From the keyer thread.
    func key(_ down: Bool) {
        state.withLock { $0.down = down }
    }

    /// On the audio thread: add the tone to `out`.
    func mix(into out: UnsafeMutablePointer<Float>, count n: Int, rate: Float) {
        state.withLock { s in
            let target: Float = s.enabled && s.down ? 1 : 0
            guard target > 0 || s.amp > 0 else { return }
            let step = 2 * Float.pi * s.hz / rate
            let ramp = 1 / (rate * 0.004) // 4 ms rise and fall: no clicks
            for i in 0..<n {
                s.amp = s.amp < target ? min(s.amp + ramp, target) : max(s.amp - ramp, target)
                s.phase += step
                if s.phase > 2 * Float.pi { s.phase -= 2 * Float.pi }
                out[i] += sin(s.phase) * s.amp * s.volume
            }
        }
    }
}

#if DEBUG
/// Debug only, with RIGHELM_TAP=1 in the environment: keeps the last minute
/// of audio as it arrived from the network and as it was played, and writes
/// both to Documents (arrived.wav, played.wav) every 15 s, to compare.
final class DebugTap {
    static let shared: DebugTap? = ProcessInfo.processInfo.environment["RIGHELM_TAP"] == "1" ? DebugTap() : nil

    private struct Ring {
        var data = [Float](repeating: 0, count: 24_000 * 60)
        var at = 0
        var filled = false
        mutating func add(_ v: Float) {
            data[at] = v
            at += 1
            if at == data.count { at = 0; filled = true }
        }
        var ordered: [Float] { filled ? Array(data[at...] + data[..<at]) : Array(data[..<at]) }
    }

    private let lock = OSAllocatedUnfairLock()
    private var arrived = Ring()
    private var played = Ring()
    private var rate = 24_000
    private var timer: DispatchSourceTimer?

    private init() {
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 15, repeating: 15)
        t.setEventHandler { [weak self] in self?.dump() }
        t.resume()
        timer = t
    }

    func setRate(_ r: Int) { lock.withLockUnchecked { rate = r } }

    func arrived(_ v: Float) { lock.withLockUnchecked { arrived.add(v) } }

    func played(_ p: UnsafePointer<Float>, count n: Int) {
        lock.withLockUnchecked { for i in 0..<n { played.add(p[i]) } }
    }

    private func dump() {
        let (a, p, r) = lock.withLockUnchecked { (arrived.ordered, played.ordered, rate) }
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        Self.writeWav(a, rate: r, to: dir.appendingPathComponent("arrived.wav"))
        Self.writeWav(p, rate: r, to: dir.appendingPathComponent("played.wav"))
        print("[tap] wrote \(a.count) arrived, \(p.count) played samples to \(dir.path)")
    }

    private static func writeWav(_ x: [Float], rate: Int, to url: URL) {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + x.count * 2))
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(x.count * 2))
        for v in x { u16(UInt16(bitPattern: Int16(max(-32768, min(32767, v * 32768))))) }
        try? d.write(to: url)
    }
}
#endif

/// Plays the radio's audio and, when asked, captures the phone's
/// microphone as 20 ms frames at the stream's sample rate.
final class AudioIO {
    let buffer = JitterBuffer()
    let sidetone = Sidetone()
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
        #if DEBUG
        DebugTap.shared?.setRate(rate)
        #endif
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(rate), channels: 1, interleaved: false) else { return }
        let buf = buffer
        let tone = sidetone
        let toneRate = Float(rate)
        let source = AVAudioSourceNode(format: format) { _, _, frames, abl in
            let list = UnsafeMutableAudioBufferListPointer(abl)
            for b in list {
                if let data = b.mData?.assumingMemoryBound(to: Float.self) {
                    buf.read(into: data, count: Int(frames))
                    tone.mix(into: data, count: Int(frames), rate: toneRate)
                    #if DEBUG
                    DebugTap.shared?.played(data, count: Int(frames))
                    #endif
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
