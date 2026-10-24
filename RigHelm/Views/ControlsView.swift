import RigHelmCore
import SwiftUI

/// Receiver, DSP, transmitter, clarifier and CW settings.
struct ControlsView: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        let s = rig.state
        NavigationStack {
            Form {
                Section("Receiver") {
                    CatSlider(title: "AF gain", value: s.afGain, range: 0...255) { String(format: "AG0%03d;", $0) }
                    CatSlider(title: "RF gain", value: s.rfGain, range: 0...255) { String(format: "RG0%03d;", $0) }
                    CatSlider(title: "Squelch", value: s.squelch, range: 0...255) { String(format: "SQ0%03d;", $0) }
                    CatPicker(title: "AGC", selection: min(s.agc, 4), options: AGC.choices.map { ($0.code, $0.label) }, display: AGC.label(s.agc)) { "GT0\($0);" }
                    CatSegments(title: "Preamp", selection: s.preamp, options: [(0, "IPO"), (1, "AMP1"), (2, "AMP2")]) { "PA0\($0);" }
                    CatSegments(title: "ATT", selection: s.att, options: [(0, "OFF"), (1, "6"), (2, "12"), (3, "18")]) { "RA0\($0);" }
                    CatPicker(title: "Roofing", selection: roofingSetCode(s.roofing),
                              options: Roofing.choices.enumerated().map { ($0.offset, $0.element.label) },
                              display: Roofing.label(s.roofing) ?? "—") { "RF0\(Roofing.choices[$0].code);" }
                }

                Section("Filter") {
                    if let m = s.rxMode, s.widthClass(m) != .fixed {
                        CatToggle(title: "Narrow", isOn: s.narrow) { "NA0\($0 ? 1 : 0);" }
                        let choices = widthChoices(s.widthClass(m), narrow: s.narrow)
                        CatPicker(title: "Width", selection: s.widthIndex, options: choices.map { ($0.index, "\($0.hz) Hz") },
                                  display: s.widthHz.map { "\($0) Hz" } ?? "—") { String(format: "SH0%02d;", $0) }
                    } else {
                        CatToggle(title: "Narrow", isOn: s.narrow) { "NA0\($0 ? 1 : 0);" }
                    }
                    CatSlider(title: "IF shift", value: s.ifShift, range: -1200...1200, step: 20, unit: " Hz") {
                        String(format: "IS0%@%04d;", $0 < 0 ? "-" : "+", abs($0))
                    }
                }

                Section("Noise and notch") {
                    CatSegments(title: "Noise blanker", selection: s.nb, options: [(0, "OFF"), (1, "ON"), (2, "WIDE")]) { "NB0\($0);" }
                    CatSlider(title: "NB level", value: s.nbLevel, range: 0...100) { String(format: "NL0%03d;", $0) }
                    CatToggle(title: "Noise reduction (DNR)", isOn: s.nr) { "NR0\($0 ? 1 : 0);" }
                    CatSlider(title: "DNR level", value: max(s.nrLevel, 1), range: 1...15) { String(format: "RL0%02d;", $0) }
                    CatToggle(title: "Auto notch (DNF)", isOn: s.autoNotch) { "BC0\($0 ? 1 : 0);" }
                    CatToggle(title: "Manual notch", isOn: s.manualNotch) { String(format: "BP00%03d;", $0 ? 1 : 0) }
                    CatSlider(title: "Notch frequency", value: max(s.notchFreq, 1) * 10, range: 10...4000, step: 10, unit: " Hz") {
                        String(format: "BP01%03d;", min(max($0 / 10, 1), 400))
                    }
                    CatSegments(title: "Contour", selection: s.contourMode, options: [(0, "OFF"), (1, "CONTOUR"), (2, "APF")]) { String(format: "CO00%02d;", $0) }
                    if s.contourMode == 2 {
                        CatSlider(title: "APF offset", value: (s.apfFreq - 25) * 10, range: -250...250, step: 10, unit: " Hz") {
                            String(format: "CO02%02d;", min(max($0 / 10 + 25, 0), 50))
                        }
                    } else if s.contourMode == 1 {
                        CatSlider(title: "Contour frequency", value: max(s.contourFreq, 1) * 100, range: 100...4000, step: 100, unit: " Hz") {
                            String(format: "CO01%02d;", min(max($0 / 100, 1), 40))
                        }
                    }
                }

                Section {
                    CatSlider(title: "Power", value: s.power, range: 5...100, unit: " W") { String(format: "PC%03d;", $0) }
                    CatSlider(title: "Mic gain", value: s.micGain, range: 0...100) { String(format: "MG%03d;", $0) }
                    CatToggle(title: "Speech processor", isOn: s.processor) { "PR0\($0 ? 1 : 0);" }
                    CatSlider(title: "Processor level", value: s.procLevel, range: 0...100) { String(format: "PL%03d;", $0) }
                    CatToggle(title: "Parametric mic EQ", isOn: s.micEQ) { "PR1\($0 ? 1 : 0);" }
                    CatToggle(title: "Monitor", isOn: s.monitor) { String(format: "ML0%03d;", $0 ? 1 : 0) }
                    CatSlider(title: "Monitor level", value: max(s.monitorLevel, 1), range: 1...100) { String(format: "ML1%03d;", $0) }
                    CatToggle(title: "VOX", isOn: s.vox, transmits: true) { "VX\($0 ? 1 : 0);" }
                    CatSlider(title: "VOX gain", value: s.voxGain, range: 0...100) { String(format: "VG%03d;", $0) }
                    CatSlider(title: "VOX delay", value: max(s.voxDelay, 30), range: 30...3000, step: 10, unit: " ms") { String(format: "VD%04d;", $0) }
                } header: {
                    Text("Transmitter")
                } footer: {
                    Text("These change the radio's settings; none of them transmits. VOX can key the radio, so it follows the transmit lock.")
                }

                Section {
                    CatToggle(title: "RX clarifier", isOn: s.rxClar) { "RT\($0 ? 1 : 0);" }
                    CatToggle(title: "TX clarifier", isOn: s.txClar) { "XT\($0 ? 1 : 0);" }
                    HStack {
                        Text("Offset")
                        Spacer()
                        Text(String(format: "%+d Hz", s.infoA.clarOffset))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(s.rxClar || s.txClar ? Theme.amber : .secondary)
                    }
                    HStack(spacing: 6) {
                        ForEach([-100, -10, 10, 100], id: \.self) { d in
                            LEDButton(title: d > 0 ? "+\(d)" : "−\(-d)", on: false) {
                                rig.send(d < 0 ? String(format: "RD%04d;", -d) : String(format: "RU%04d;", d))
                            }
                        }
                        LEDButton(title: "CLEAR", on: false) { rig.send("RC;") }
                    }
                } header: {
                    Text("Clarifier")
                } footer: {
                    Text("The FTDX3000 has one clarifier offset, shared by RX and TX clarifier.")
                }

                Section("CW") {
                    CatToggle(title: "Keyer", isOn: s.keyer) { "KR\($0 ? 1 : 0);" }
                    CatSlider(title: "Speed", value: max(s.keySpeed, 4), range: 4...60, unit: " WPM") { String(format: "KS%03d;", $0) }
                    CatSlider(title: "Pitch", value: 300 + 10 * s.keyPitch, range: 300...1050, step: 10, unit: " Hz") {
                        String(format: "KP%02d;", min(max(($0 - 300) / 10, 0), 75))
                    }
                    CatToggle(title: "Break-in", isOn: s.breakIn) { "BI\($0 ? 1 : 0);" }
                    CatSlider(title: "Break-in delay", value: max(s.bkDelay, 30), range: 30...3000, step: 10, unit: " ms") { String(format: "SD%04d;", $0) }
                }

                Section("Dial") {
                    CatToggle(title: "Dial lock", isOn: s.lock & 1 == 1) { $0 ? "LK1;" : "LK0;" }
                    CatToggle(title: "Fast tuning", isOn: s.fast & 1 == 1) { $0 ? "FS1;" : "FS0;" }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Controls")
            .disabled(!rig.isConnected)
        }
    }

    /// Answer codes (with AUTO variants) to the Set choices' index.
    private func roofingSetCode(_ code: Character) -> Int {
        switch Character(code.uppercased()) {
        case "1": return 1
        case "2": return 2
        case "3": return 3
        case "7": return 4
        case "8": return 5
        default: return 0
        }
    }
}

/// A slider that follows the radio, sends while it is dragged (a few times
/// a second), and always sends where it was let go.
struct CatSlider: View {
    @Environment(RigController.self) private var rig
    let title: String
    let value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""
    let command: (Int) -> String
    @State private var local: Double?
    @State private var lastSent = Date.distantPast

    var body: some View {
        let shown = local.map { Int($0) } ?? value
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text("\(shown)\(unit)")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(Theme.amber)
            }
            Slider(value: Binding(
                get: { local ?? Double(min(max(value, range.lowerBound), range.upperBound)) },
                set: { v in
                    local = v
                    if Date().timeIntervalSince(lastSent) > 0.15 {
                        lastSent = Date()
                        rig.send(command(Int(v)))
                    }
                }),
                in: Double(range.lowerBound)...Double(range.upperBound), step: Double(step)) { editing in
                    if !editing, let l = local {
                        rig.send(command(Int(l)))
                        // Keep showing it until the radio has answered.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { local = nil }
                    }
                }
        }
    }
}

struct CatToggle: View {
    @Environment(RigController.self) private var rig
    let title: String
    let isOn: Bool
    /// Turning it on can key the radio: it obeys the transmit lock.
    var transmits = false
    let command: (Bool) -> String

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { on in
            if on && transmits && !rig.canTransmit {
                rig.showLockedHint = true
                return
            }
            rig.send(command(on))
        }))
        .tint(Theme.amber)
    }
}

struct CatPicker: View {
    @Environment(RigController.self) private var rig
    let title: String
    let selection: Int
    let options: [(Int, String)]
    let display: String
    let command: (Int) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { opt in
                Button {
                    rig.send(command(opt.0))
                } label: {
                    if opt.0 == selection { Label(opt.1, systemImage: "checkmark") } else { Text(opt.1) }
                }
            }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(display).foregroundStyle(Theme.amber)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CatSegments: View {
    @Environment(RigController.self) private var rig
    let title: String
    let selection: Int
    let options: [(Int, String)]
    let command: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            HStack(spacing: 6) {
                ForEach(options, id: \.0) { opt in
                    LEDButton(title: opt.1, on: opt.0 == selection) { rig.send(command(opt.0)) }
                }
            }
        }
        .padding(.vertical, 2)
    }
}
