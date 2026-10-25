import AVFoundation
import Observation
import RigHelmCore
import UIKit

/// Everything the app knows and does: finding stations, the CAT and audio
/// sessions to one, the phone mic, and transmit safety. Used on the main
/// thread only.
@Observable
final class RigController {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    // MARK: Stations

    var discovered: [ServerBeacon] = []
    var saved: [SavedServer] = SavedServers.load()
    /// The station being controlled (nil: show the station list).
    private(set) var target: SavedServer?
    private(set) var phase: Phase = .idle
    private(set) var serverName = ""
    /// Why the last connection ended, shown on the station list.
    var lastError: String?

    // MARK: Radio

    private(set) var state = RadioState()
    private(set) var audioStats = AudioLinkStats()
    private(set) var notes: [String] = []

    // MARK: Settings

    var receiveAudio: Bool = UserDefaults.standard.object(forKey: "receiveAudio") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(receiveAudio, forKey: "receiveAudio")
            listening.set(receiveAudio)
            restartAudio()
        }
    }

    var volume: Float = UserDefaults.standard.object(forKey: "volume") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(volume, forKey: "volume")
            audio.volume = volume
        }
    }

    var micGain: Float = UserDefaults.standard.object(forKey: "micGain") as? Float ?? 1 {
        didSet {
            UserDefaults.standard.set(micGain, forKey: "micGain")
            audio.micGain.set(micGain)
        }
    }

    /// Off until the operator turns it on in Settings. While off, nothing
    /// that transmits leaves the phone. Not saved: every launch and every
    /// new connection starts locked.
    var transmitAllowed = false {
        didSet {
            txAllowedFlag.set(transmitAllowed)
            if !transmitAllowed { unkey() }
        }
    }

    /// Longest transmission before the phone lets go by itself.
    var txTimeoutSeconds: Int = UserDefaults.standard.object(forKey: "txTimeout") as? Int ?? 180 {
        didSet { UserDefaults.standard.set(txTimeoutSeconds, forKey: "txTimeout") }
    }

    var keepAwake: Bool = UserDefaults.standard.bool(forKey: "keepAwake") {
        didSet {
            UserDefaults.standard.set(keepAwake, forKey: "keepAwake")
            UIApplication.shared.isIdleTimerDisabled = keepAwake && target != nil
        }
    }

    var reconnectOnLaunch: Bool = UserDefaults.standard.object(forKey: "reconnectOnLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reconnectOnLaunch, forKey: "reconnectOnLaunch") }
    }

    var tuneStep: Int = UserDefaults.standard.object(forKey: "tuneStep") as? Int ?? 100 {
        didSet { UserDefaults.standard.set(tuneStep, forKey: "tuneStep") }
    }

    // MARK: Transmit

    /// Talk through the phone: the radio's MIC SEL menus are set to USB and
    /// the phone's microphone is sent while this phone transmits.
    private(set) var phoneMic = false
    private(set) var micLevelDb: Float = -100
    /// Microphone audio is going to the radio right now.
    private(set) var sendingMic = false
    private(set) var latched = false
    private(set) var txStartedAt: Date?
    /// A transmit button was pressed while transmit is locked.
    var showLockedHint = false
    var micPermissionDenied = false

    // MARK: Internals

    private var cat: CatClient?
    private var link: AudioLink?
    private let audio = AudioIO()
    private let discovery = Discovery()
    private let txAllowedFlag = Locked(false)
    private let listening = Locked(true)
    private let micGate = Locked(false)
    private var ticker: Timer?
    /// The tuned frequency shown while the knob turns, ahead of the radio.
    private var pendingFreq: (hz: Int, vfoB: Bool, until: Date)?
    private var lastFreqSend = Date.distantPast
    private var freqSendScheduled = false
    /// MIC SEL values from before switching to the phone mic, by menu.
    private var savedMicSel: [Int: Int] = [:]

    init() {
        txAllowedFlag.set(transmitAllowed)
        listening.set(receiveAudio)
        audio.micGain.set(micGain)
        discovery.onUpdate = { [weak self] list in self?.discoveryUpdated(list) }
        discovery.start()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { self?.restartAudio() }
        }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            self?.restartAudio()
        }
        if reconnectOnLaunch, let last = UserDefaults.standard.string(forKey: "lastServer"),
           let server = saved.first(where: { $0.id == last }) {
            connect(server, password: Keychain.password(for: server.id) ?? "")
        }
    }

    // MARK: - Stations

    private func discoveryUpdated(_ list: [ServerBeacon]) {
        discovered = list
        // Keep saved names and addresses current.
        var changed = false
        for b in list {
            if let i = saved.firstIndex(where: { $0.host == b.host && $0.port == b.port }), saved[i].name != b.name {
                saved[i].name = b.name
                changed = true
            }
        }
        if changed { SavedServers.save(saved) }
    }

    func refreshDiscovery() {
        discovery.probeNow()
    }

    func savedPassword(for server: SavedServer) -> String? {
        Keychain.password(for: server.id)
    }

    func forget(_ server: SavedServer) {
        saved.removeAll { $0.id == server.id }
        SavedServers.save(saved)
        Keychain.setPassword("", for: server.id)
    }

    /// The beacon of the connected station, if it is being heard.
    var targetBeacon: ServerBeacon? {
        guard let t = target else { return nil }
        return discovered.first { $0.host == t.host && $0.port == t.port }
    }

    // MARK: - Connection

    func connect(_ server: SavedServer, password: String) {
        disconnect()
        Keychain.setPassword(password, for: server.id)
        saved.removeAll { $0.id == server.id }
        saved.insert(server, at: 0)
        SavedServers.save(saved)
        UserDefaults.standard.set(server.id, forKey: "lastServer")
        transmitAllowed = false
        target = server
        phase = .connecting
        serverName = server.name
        lastError = nil
        state = RadioState()
        note("connecting to \(server.name) at \(server.host)")

        let cat = CatClient(host: server.host, port: server.port, password: password)
        let allowed = txAllowedFlag
        cat.isTransmitAllowed = { allowed.get }
        cat.onStatus = { [weak self] s in self?.catStatus(s) }
        cat.onState = { [weak self] s in self?.stateChanged(s) }
        cat.onNote = { [weak self] n in self?.note(n) }
        self.cat = cat
        cat.start()
        startLink(password: password)
        UIApplication.shared.isIdleTimerDisabled = keepAwake
    }

    /// Lets go of the transmitter, puts the radio's mic back, and closes.
    func disconnect() {
        guard target != nil else { return }
        unkey()
        if phoneMic { setPhoneMic(false) }
        cat?.stop()
        cat = nil
        link?.stop()
        link = nil
        audio.stop()
        target = nil
        phase = .idle
        state = RadioState()
        audioStats = AudioLinkStats()
        micGate.set(false)
        sendingMic = false
        UIApplication.shared.isIdleTimerDisabled = false
        UserDefaults.standard.removeObject(forKey: "lastServer")
    }

    private func catStatus(_ s: CatClient.Status) {
        switch s {
        case .connecting:
            if phase != .connected { phase = .connecting }
        case .connected(let name):
            phase = .connected
            serverName = name
            if let t = target, let i = saved.firstIndex(where: { $0.id == t.id }), saved[i].name != name {
                saved[i].name = name
                SavedServers.save(saved)
            }
        case .failed(let why):
            note(why)
            // A wrong password won't get better by retrying, and the
            // station locks out an address after five.
            if why.contains("password") || why.contains("not a RigHelm") {
                disconnect()
                lastError = why
            } else {
                phase = .failed(why)
            }
        case .stopped:
            break
        }
    }

    private func stateChanged(_ s: RadioState) {
        state = s
        if let p = pendingFreq, Date() > p.until { pendingFreq = nil }
        updateMicGate()
    }

    private func startLink(password: String) {
        guard let server = target else { return }
        let link = AudioLink(host: server.host, port: server.port, password: password)
        let buffer = audio.buffer
        let listening = self.listening
        link.onAudio = { samples, lost in
            if (1...5).contains(lost) { buffer.writeGap(lost * samples.count) }
            buffer.write(samples, gain: listening.get ? 1 : 0)
        }
        link.onStats = { [weak self] s in
            guard let self else { return }
            let rateChanged = s.connected && s.rate != self.audio.rate
            self.audioStats = s
            if rateChanged || (s.connected && !self.audio.running) { self.restartAudio() }
        }
        let gate = micGate
        audio.onMicFrame = { [weak link] frame in
            if gate.get { link?.sendMic(frame) }
        }
        self.link = link
        link.start()
    }

    /// (Re)start the phone's audio for the current settings.
    func restartAudio() {
        guard target != nil else { return }
        // Neither listening nor talking: no audio session at all.
        guard receiveAudio || phoneMic else {
            link?.stop()
            link = nil
            audio.stop()
            return
        }
        if link == nil, let t = target {
            startLink(password: Keychain.password(for: t.id) ?? "")
            return
        }
        do {
            try audio.start(rate: audioStats.rate, mic: phoneMic)
            audio.volume = volume
        } catch {
            note("audio: \(error.localizedDescription)")
        }
    }

    // MARK: - Commands

    func send(_ command: String) {
        cat?.send(command)
    }

    var isConnected: Bool { phase == .connected }

    // MARK: Tuning

    /// The receive frequency to show: the knob's while it turns.
    var displayRxFreq: Int {
        if let p = pendingFreq, p.vfoB == state.rxOnB { return p.hz }
        return state.rxFreq
    }

    func tune(steps: Int) {
        guard steps != 0, state.rxFreq > 0 else { return }
        let base = displayRxFreq
        // Snap to the step grid first, as a radio's dial does.
        var hz = (base / tuneStep) * tuneStep + steps * tuneStep
        if steps < 0 && base % tuneStep != 0 { hz += tuneStep }
        setRxFrequency(hz)
    }

    func setRxFrequency(_ hz: Int) {
        let hz = min(max(hz, Frequency.min), Frequency.max)
        pendingFreq = (hz, state.rxOnB, Date().addingTimeInterval(0.8))
        // At most every 60 ms while turning; the last value always goes.
        if Date().timeIntervalSince(lastFreqSend) > 0.06 {
            flushFrequency()
        } else if !freqSendScheduled {
            freqSendScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                self?.freqSendScheduled = false
                self?.flushFrequency()
            }
        }
    }

    private func flushFrequency() {
        guard let p = pendingFreq else { return }
        lastFreqSend = Date()
        pendingFreq?.until = Date().addingTimeInterval(0.8)
        send(Frequency.setCommand(vfoB: p.vfoB, hz: p.hz))
    }

    func setMode(_ m: Mode) {
        send(m.setCommand)
    }

    func toggleSplit() {
        let txB = state.split ? state.rxOnB : !state.rxOnB
        send(txB ? "FT3;" : "FT2;")
    }

    // MARK: Transmit

    var canTransmit: Bool { transmitAllowed && isConnected }

    /// Why transmit can't happen right now, for the operator.
    var transmitBlockReason: String? {
        if !transmitAllowed { return "Turn on “Allow transmit from this phone” in Settings." }
        if !isConnected { return "Not connected to the station." }
        if targetBeacon?.auth == false { return "This station has no password, so it is receive-only." }
        return nil
    }

    func pttDown() {
        // With MOX latched, the button lets go.
        if latched {
            unkey()
            return
        }
        guard canTransmit else {
            showLockedHint = true
            return
        }
        if !state.transmitting {
            send("TX1;")
            txStartedAt = Date()
            updateMicGate()
        }
    }

    func pttUp() {
        if !latched { unkey() }
    }

    /// MOX: stay keyed after letting go of the button.
    func toggleLatch() {
        if latched || state.transmitting && cat?.keyedByUs == true {
            unkey()
        } else {
            guard canTransmit else {
                showLockedHint = true
                return
            }
            latched = true
            pttDown()
        }
    }

    func unkey() {
        let keyed = cat?.keyedByUs == true || latched || txStartedAt != nil
        latched = false
        txStartedAt = nil
        micGate.set(false)
        sendingMic = false
        if keyed { cat?.send("TX0;") }
    }

    /// Start the antenna tuner (it transmits a carrier).
    func startTune() {
        guard canTransmit else {
            showLockedHint = true
            return
        }
        send("AC002;")
    }

    func setPhoneMic(_ on: Bool) {
        if on {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                break
            case .undetermined:
                AVAudioApplication.requestRecordPermission { [weak self] ok in
                    DispatchQueue.main.async {
                        if ok { self?.setPhoneMic(true) } else { self?.micPermissionDenied = true }
                    }
                }
                return
            default:
                micPermissionDenied = true
                return
            }
        }
        guard on != phoneMic else { return }
        unkey()
        phoneMic = on
        applyMicSel()
        restartAudio()
    }

    /// Point the radio's AM, FM and SSB MIC SEL menus at USB (phone mic) or
    /// back to what they were (as RigHelm's COMPUTER MIC switch does).
    private func applyMicSel() {
        for menu in [53, 85, 103] {
            let now = state.micSel(menu)
            let want: Int
            if phoneMic {
                if let v = now, v != 2 { savedMicSel[menu] = v }
                want = 2
            } else {
                want = savedMicSel[menu].flatMap { $0 == 2 ? nil : $0 } ?? 0
            }
            if now != want {
                send(String(format: "EX%03d%d;", menu, want))
            }
        }
        if !phoneMic { savedMicSel.removeAll() }
    }

    private func updateMicGate() {
        // Open as soon as this phone keys, not when the radio's TX state comes
        // back, so the first words aren't cut off. The server checks again.
        let keying = state.transmitting || txStartedAt != nil
        let on = phoneMic && transmitAllowed && cat?.keyedByUs == true && keying && state.txMode?.isVoice == true
        micGate.set(on)
        if sendingMic != on { sendingMic = on }
    }

    // MARK: - Housekeeping

    private func tick() {
        let level = audio.micLevelDb.get
        if abs(level - micLevelDb) > 0.5 { micLevelDb = level }
        updateMicGate()
        if let t = txStartedAt, Date().timeIntervalSince(t) > Double(txTimeoutSeconds) {
            unkey()
            note("transmit time-out: let go after \(txTimeoutSeconds / 60) min")
        }
        // Keyed elsewhere (or the radio let go): forget our own TX timer.
        if txStartedAt != nil, !state.transmitting, let t = txStartedAt, Date().timeIntervalSince(t) > 3, cat?.keyedByUs != true {
            txStartedAt = nil
            latched = false
        }
    }

    /// The app is going to the background: never leave the radio keyed by
    /// a phone in a pocket.
    func enteredBackground() {
        unkey()
        if target == nil { discovery.stop() }
    }

    func enteredForeground() {
        discovery.start()
        discovery.probeNow()
        if target != nil && !audio.running { restartAudio() }
    }

    func note(_ text: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        notes.append("\(stamp)  \(text)")
        if notes.count > 200 { notes.removeFirst(notes.count - 200) }
    }
}
