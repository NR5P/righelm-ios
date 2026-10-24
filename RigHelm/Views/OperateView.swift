import RigHelmCore
import SwiftUI

/// The main page: frequency, meters, tuning, band and mode, and transmit.
struct OperateView: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HeaderBar()
                ConnectionBanner()
                FrequencyCard()
                MeterCard()
                TuningCard()
                BandModeCard()
                VFOCard()
                TransmitCard()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Keeps scrolled content from showing behind the status bar.
            Color.clear.frame(height: 0).background(Theme.background)
        }
        .safeAreaInset(edge: .bottom) {
            PTTBar()
        }
    }
}

// MARK: - Header

struct HeaderBar: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        HStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("RigHelm")
                    .font(.system(size: 17, weight: .bold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(rig.isConnected ? Theme.green : Theme.amber)
                        .frame(width: 7, height: 7)
                    Text(rig.serverName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if rig.state.transmitting {
                Text("TX")
                    .font(.system(size: 13, weight: .heavy))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Theme.red, in: Capsule())
            }
            if rig.audioStats.connected && rig.receiveAudio {
                Image(systemName: rig.audioStats.rxLevelDb > -70 ? "speaker.wave.2.fill" : "speaker.fill")
                    .foregroundStyle(Theme.cyan)
            }
            Menu {
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { rig.disconnect() }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }
}

struct ConnectionBanner: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        switch rig.phase {
        case .connecting:
            banner(Text("Connecting to \(rig.serverName)…"), color: Theme.amber, spinner: true)
        case .failed(let why):
            banner(Text("Reconnecting: \(why)"), color: Theme.red, spinner: true)
        default:
            if rig.state.powerOn == false {
                banner(Text("The radio is switched off"), color: Theme.amber, spinner: false)
            } else if let b = rig.targetBeacon, b.radio != "connected" {
                banner(Text("The station's radio is \(b.radio == "not-answering" ? "not answering" : "not connected")"), color: Theme.amber, spinner: false)
            }
        }
    }

    private func banner(_ text: Text, color: Color, spinner: Bool) -> some View {
        HStack(spacing: 10) {
            if spinner { ProgressView().tint(color) }
            text.font(.footnote.weight(.medium)).foregroundStyle(color)
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Frequency

struct FrequencyCard: View {
    @Environment(RigController.self) private var rig
    @State private var dragSteps = 0
    @State private var entering = false

    var body: some View {
        let s = rig.state
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    tag(s.rxOnB ? "VFO B" : "VFO A", Theme.amber)
                    if let m = s.rxMode { tag(m.label, Theme.cyan) }
                    if let w = s.widthHz { tag(w >= 1000 ? String(format: "%.1f kHz", Double(w) / 1000) : "\(w) Hz", Theme.dim) }
                    if let b = Band.of(rig.displayRxFreq) { tag("\(b.label) m", Theme.dim) }
                    Spacer()
                    if s.busy { tag("BUSY", Theme.green) }
                    if s.lock & 1 == 1 { Image(systemName: "lock.fill").foregroundStyle(Theme.red).font(.caption) }
                }
                FrequencyText(hz: rig.displayRxFreq, size: 46, color: s.transmitting && !s.split ? Theme.red : Theme.amber)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 6)
                        .onChanged { g in
                            let steps = Int(g.translation.width / 14)
                            if steps != dragSteps {
                                rig.tune(steps: steps - dragSteps)
                                dragSteps = steps
                                Haptics.tick()
                            }
                        }
                        .onEnded { _ in dragSteps = 0 })
                    .onTapGesture { entering = true }
                Divider().overlay(Color.white.opacity(0.08))
                HStack(spacing: 8) {
                    Text(s.rxOnB ? "A" : "B")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.dim)
                    FrequencyText(hz: s.rxOnB ? s.freqA : s.freqB, size: 20, color: Theme.cyan.opacity(0.85))
                    Text((s.rxOnB ? s.modeA : s.modeB)?.label ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if s.split { tag("SPLIT", Theme.amber) }
                    if s.rxClar || s.txClar {
                        tag(String(format: "CLAR %+d", s.infoA.clarOffset), Theme.amber)
                    }
                }
            }
        }
        .sheet(isPresented: $entering) {
            FrequencyEntry(current: rig.displayRxFreq) { rig.setRxFrequency($0) }
        }
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5)))
    }
}

/// "14.074.000" with the Hz digits smaller, like a radio's display.
struct FrequencyText: View {
    let hz: Int
    let size: CGFloat
    let color: Color

    var body: some View {
        let text = hz > 0 ? Frequency.format(hz) : "—.———.———"
        let split = text.index(text.endIndex, offsetBy: -3, limitedBy: text.startIndex) ?? text.startIndex
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(text[..<split])
                .font(.system(size: size, weight: .medium, design: .monospaced))
            Text(text[split...])
                .font(.system(size: size * 0.72, weight: .medium, design: .monospaced))
                .opacity(0.8)
        }
        .foregroundStyle(color)
        .monospacedDigit()
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .shadow(color: color.opacity(0.35), radius: 8)
    }
}

/// Type a frequency in kHz (or MHz with a decimal point).
struct FrequencyEntry: View {
    let current: Int
    let set: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("kHz", text: $text)
                        .keyboardType(.decimalPad)
                        .font(.system(size: 28, design: .monospaced))
                        .focused($focused)
                } footer: {
                    Text("In kHz (14074) or MHz (14.074).")
                }
            }
            .navigationTitle("Frequency")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        if let hz = parse(text) { set(hz) }
                        dismiss()
                    }
                    .disabled(parse(text) == nil)
                }
            }
            .onAppear {
                text = String(format: "%.3f", Double(current) / 1000)
                focused = true
            }
        }
        .presentationDetents([.height(240)])
    }

    private func parse(_ s: String) -> Int? {
        guard let v = Double(s.replacingOccurrences(of: ",", with: ".")), v > 0 else { return nil }
        // Under 100 is MHz (14.074), otherwise kHz (14074).
        let hz = v < 100 ? Int((v * 1_000_000).rounded()) : Int((v * 1000).rounded())
        return (Frequency.min...Frequency.max).contains(hz) ? hz : nil
    }
}

// MARK: - Meters

struct MeterCard: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        let s = rig.state
        Card(padding: 10) {
            VStack(spacing: 7) {
                if s.transmitting {
                    let po = MeterCal.interpolate(MeterCal.po, s.meter(.po) ?? 0)
                    MeterBar(label: "PO", fraction: po / 100, text: String(format: "%.0f W", po), color: Theme.amber,
                             ticks: [(0.25, "25"), (0.5, "50"), (0.75, "75")])
                    let swr = MeterCal.interpolate(MeterCal.swr, s.meter(.swr) ?? 0)
                    MeterBar(label: "SWR", fraction: Double(s.meter(.swr) ?? 0) / 255, text: String(format: "%.1f", swr), color: Theme.cyan, redFrom: 89.0 / 255)
                    let alc = Double(s.meter(.alc) ?? 0) / 255
                    MeterBar(label: "ALC", fraction: alc, text: String(format: "%.0f%%", alc * 100), color: Theme.cyan, redFrom: 0.5)
                } else {
                    MeterBar(label: "S", fraction: Double(s.sMeter) / 255, text: MeterCal.sText(s.sMeter), color: Theme.green, redFrom: 130.0 / 255,
                             ticks: [(27.0 / 255, "3"), (55.0 / 255, "5"), (80.0 / 255, "7"), (130.0 / 255, "9"), (172.0 / 255, "+20"), (220.0 / 255, "+40")],
                             height: 18)
                    if rig.receiveAudio {
                        let lvl = rig.audioStats.connected ? Double(rig.audioStats.rxLevelDb) : -100
                        MeterBar(label: "AUDIO", fraction: (lvl + 70) / 70, text: rig.audioStats.connected ? String(format: "%.0f dB", lvl) : "—", color: Theme.cyan.opacity(0.7), height: 6)
                    }
                }
                if s.highSWR {
                    Text("HI-SWR").font(.caption.bold()).foregroundStyle(Theme.red)
                }
            }
        }
    }
}

// MARK: - Tuning

struct TuningCard: View {
    @Environment(RigController.self) private var rig
    static let steps = [10, 100, 500, 1000, 5000, 10_000, 100_000]

    var body: some View {
        @Bindable var rig = rig
        Card {
            VStack(spacing: 12) {
                HStack(spacing: 18) {
                    stepButton(-1)
                    HelmKnob { rig.tune(steps: $0) }
                        .frame(width: 168, height: 168)
                    stepButton(1)
                }
                .frame(maxWidth: .infinity)
                Picker("Step", selection: $rig.tuneStep) {
                    ForEach(Self.steps, id: \.self) { s in
                        Text(s >= 1000 ? "\(s / 1000)k" : "\(s)").tag(s)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private func stepButton(_ dir: Int) -> some View {
        Button {
            rig.tune(steps: dir)
            Haptics.tick()
        } label: {
            Image(systemName: dir < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 22, weight: .bold))
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.07), in: Circle())
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
    }
}

/// The tuning knob, drawn like the RigHelm logo's helm wheel. Turning it
/// one notch (12°) moves the dial one step.
struct HelmKnob: View {
    let onSteps: (Int) -> Void
    @State private var angle: Double = 0
    @State private var lastTouch: Double?
    @State private var residue: Double = 0
    private let notch = 12.0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                // Spokes and rim.
                ForEach(0..<4) { i in
                    Capsule()
                        .fill(Theme.wood)
                        .frame(width: size * 0.045, height: size * 0.98)
                        .rotationEffect(.degrees(Double(i) * 45))
                }
                Circle()
                    .stroke(Theme.wood, lineWidth: size * 0.06)
                    .frame(width: size * 0.66, height: size * 0.66)
                // The knob in the middle.
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.38), Color(white: 0.16), Color(white: 0.07)],
                                         center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.3))
                    .frame(width: size * 0.36, height: size * 0.36)
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                ForEach(0..<30) { i in
                    Rectangle()
                        .fill(Color.black.opacity(0.85))
                        .frame(width: 1.5, height: size * 0.025)
                        .offset(y: -size * 0.165)
                        .rotationEffect(.degrees(Double(i) * 12))
                }
                Capsule()
                    .fill(Theme.amber)
                    .frame(width: size * 0.024, height: size * 0.1)
                    .offset(y: -size * 0.09)
            }
            .rotationEffect(.degrees(angle))
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let a = atan2(g.location.y - c.y, g.location.x - c.x) * 180 / .pi
                    if let last = lastTouch {
                        var d = a - last
                        if d > 180 { d -= 360 }
                        if d < -180 { d += 360 }
                        angle += d
                        residue += d
                        let steps = Int(residue / notch)
                        if steps != 0 {
                            residue -= Double(steps) * notch
                            onSteps(steps)
                            Haptics.tick()
                        }
                    }
                    lastTouch = a
                }
                .onEnded { _ in
                    lastTouch = nil
                    residue = 0
                })
        }
        .accessibilityLabel("Tuning knob")
        .accessibilityAdjustableAction { dir in
            onSteps(dir == .increment ? 1 : -1)
        }
    }
}

enum Haptics {
    private static let gen = UISelectionFeedbackGenerator()
    static func tick() { gen.selectionChanged() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
}

// MARK: - Band and mode

struct BandModeCard: View {
    @Environment(RigController.self) private var rig
    private let modes: [Mode] = [.lsb, .usb, .cw, .cwR, .am, .fm, .dataLsb, .dataUsb]

    var body: some View {
        let s = rig.state
        let current = Band.of(rig.displayRxFreq)?.code
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("BAND").font(.caption2.bold()).foregroundStyle(Theme.dim)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                    ForEach(Band.all) { b in
                        LEDButton(title: b.label, on: b.code == current) { rig.send(b.setCommand) }
                    }
                }
                Text("MODE").font(.caption2.bold()).foregroundStyle(Theme.dim).padding(.top, 2)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(modes) { m in
                        LEDButton(title: m.label, on: s.rxMode == m, color: Theme.cyan) { rig.setMode(m) }
                    }
                }
                Menu {
                    ForEach(Mode.ordered.filter { !modes.contains($0) }) { m in
                        Button(m.label) { rig.setMode(m) }
                    }
                } label: {
                    Label("More modes", systemImage: "ellipsis")
                        .font(.footnote)
                }
            }
        }
    }
}

struct VFOCard: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        let s = rig.state
        Card {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    LEDButton(title: "A ▸ B", on: false) { rig.send("AB;") }
                    LEDButton(title: "B ▸ A", on: false) { rig.send("BA;") }
                    LEDButton(title: "A ⇄ B", on: false) { rig.send("SV;") }
                    LEDButton(title: "SPLIT", on: s.split) { rig.toggleSplit() }
                }
                HStack(spacing: 6) {
                    LEDButton(title: "RX A", on: !s.rxOnB, color: Theme.cyan) { rig.send("FR0;") }
                    LEDButton(title: "RX B", on: s.rxOnB, color: Theme.cyan) { rig.send("FR4;") }
                    LEDButton(title: "LOCK", on: s.lock & 1 == 1, color: Theme.red) { rig.send(s.lock & 1 == 1 ? "LK0;" : "LK1;") }
                    LEDButton(title: "ATU", on: s.tuner != 0) { rig.send(s.tuner != 0 ? "AC000;" : "AC001;") }
                }
            }
        }
    }
}

// MARK: - Transmit

struct TransmitCard: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        let s = rig.state
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("TRANSMIT").font(.caption2.bold()).foregroundStyle(Theme.dim)
                    Spacer()
                    if !rig.transmitAllowed {
                        Label("Locked", systemImage: "lock.fill")
                            .font(.caption.bold())
                            .foregroundStyle(Theme.red)
                    }
                }
                HStack(spacing: 6) {
                    LEDButton(title: rig.phoneMic ? "PHONE MIC" : "RADIO MIC", on: rig.phoneMic, color: Theme.red) {
                        rig.setPhoneMic(!rig.phoneMic)
                    }
                    LEDButton(title: "MOX", on: rig.latched || (s.transmitting && rig.txStartedAt != nil), color: Theme.red) {
                        rig.toggleLatch()
                    }
                    LEDButton(title: s.tuner == 2 ? "TUNING" : "TUNE", on: s.tuner == 2) { rig.startTune() }
                }
                if rig.phoneMic {
                    MeterBar(label: "MIC", fraction: (Double(rig.micLevelDb) + 60) / 60,
                             text: rig.micLevelDb > -99 ? String(format: "%.0f dB", rig.micLevelDb) : "—",
                             color: rig.sendingMic ? Theme.red : Theme.green, redFrom: 54.0 / 60, height: 8)
                }
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(rig.sendingMic ? Theme.red : .secondary)
                HStack(spacing: 6) {
                    Text("ANT").font(.caption2.bold()).foregroundStyle(Theme.dim)
                    ForEach(1...3, id: \.self) { a in
                        LEDButton(title: "\(a)", on: s.antenna == a, color: Theme.cyan) { rig.send("AN0\(a);") }
                    }
                }
            }
        }
    }

    private var statusLine: String {
        let s = rig.state
        if let why = rig.transmitBlockReason, !rig.transmitAllowed || !rig.isConnected { return why }
        if rig.phoneMic {
            if rig.sendingMic { return "Sending the phone's microphone to the radio" }
            if s.transmitting, let m = s.txMode, !m.isVoice { return "\(m.label) does not take the microphone" }
            if rig.targetBeacon?.mic == false { return "⚠︎ The station does not accept microphone audio (RigHelm → Remote → Accept microphone audio)" }
            return "Hold the button below to talk through the phone"
        }
        return "Radio mic: the station's own microphone is used"
    }
}

/// Hold-to-talk, pinned above the tab bar.
struct PTTBar: View {
    @Environment(RigController.self) private var rig
    @State private var pressed = false

    var body: some View {
        let txing = rig.state.transmitting
        let locked = !rig.canTransmit
        HStack(spacing: 10) {
            Image(systemName: locked ? "lock.fill" : (txing ? "dot.radiowaves.left.and.right" : "mic.fill"))
                .font(.system(size: 20, weight: .bold))
            Text(locked ? "TRANSMIT LOCKED" : (txing ? "TRANSMITTING" : (rig.latched ? "MOX ON" : "HOLD TO TALK")))
                .font(.system(size: 17, weight: .heavy))
            if let t = rig.txStartedAt, txing {
                TimelineView(.periodic(from: t, by: 1)) { ctx in
                    Text(Duration.seconds(ctx.date.timeIntervalSince(t)).formatted(.time(pattern: .minuteSecond)))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                }
            }
        }
        .foregroundStyle(locked ? Color.white.opacity(0.45) : .white)
        .frame(maxWidth: .infinity, minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(locked ? Color.white.opacity(0.06) : (txing || pressed ? Theme.red : Color(red: 0.35, green: 0.1, blue: 0.09)))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.red.opacity(locked ? 0.15 : 0.6), lineWidth: 1.5))
        .scaleEffect(pressed ? 0.98 : 1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !pressed else { return }
                pressed = true
                Haptics.heavy()
                rig.pttDown()
            }
            .onEnded { _ in
                pressed = false
                rig.pttUp()
            })
        .accessibilityLabel(locked ? "Transmit locked" : "Push to talk")
    }
}
