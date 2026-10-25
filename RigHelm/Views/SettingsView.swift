import RigHelmCore
import SwiftUI

struct SettingsView: View {
    @Environment(RigController.self) private var rig

    var body: some View {
        @Bindable var rig = rig
        NavigationStack {
            Form {
                Section("Station") {
                    LabeledContent("Name", value: rig.serverName)
                    if let t = rig.target {
                        LabeledContent("Address", value: "\(t.host):\(String(t.port))")
                    }
                    LabeledContent("Status", value: statusText)
                    if let b = rig.targetBeacon {
                        LabeledContent("Accepts phone mic", value: b.mic ? "Yes" : "No")
                    }
                    Button("Disconnect", role: .destructive) { rig.disconnect() }
                }

                Section {
                    Toggle("Play the radio's audio", isOn: $rig.receiveAudio)
                    HStack {
                        Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                        Slider(value: $rig.volume, in: 0...2)
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    }
                    if rig.audioStats.connected {
                        LabeledContent("Stream", value: "\(rig.audioStats.rate / 1000) kHz · \(rig.audioStats.packets) packets · \(rig.audioStats.lost) lost")
                            .font(.footnote)
                    } else if let e = rig.audioStats.error {
                        Text(e).font(.footnote).foregroundStyle(Theme.red)
                    }
                } header: {
                    Text("Receive audio")
                } footer: {
                    Text("Keeps playing with the screen off or in another app.")
                }

                Section {
                    Toggle("Allow transmit from this phone", isOn: $rig.transmitAllowed)
                        .tint(Theme.red)
                    Picker("Let go after", selection: $rig.txTimeoutSeconds) {
                        ForEach([60, 120, 180, 300, 600], id: \.self) { s in
                            Text("\(s / 60) min").tag(s)
                        }
                    }
                } header: {
                    Text("Transmit")
                } footer: {
                    Text("While this is off, nothing that keys the radio leaves the phone: PTT, MOX, TUNE and VOX are refused. It stays on until you turn it off. The radio is also let go when the app goes to the background, after the time-out, and by the station if the phone drops off the network.")
                }

                Section {
                    LabeledContent("Microphone", value: rig.phoneMic ? "Phone (MIC SEL = USB)" : "Radio")
                    HStack {
                        Text("Mic gain")
                        Slider(value: $rig.micGain, in: 0.25...4)
                        Text(String(format: "%.1f×", rig.micGain))
                            .font(.system(.footnote, design: .monospaced))
                            .frame(width: 40)
                    }
                    if rig.phoneMic {
                        MeterBar(label: "MIC", fraction: (Double(rig.micLevelDb) + 60) / 60,
                                 text: rig.micLevelDb > -99 ? String(format: "%.0f dB", rig.micLevelDb) : "—",
                                 color: Theme.green, redFrom: 54.0 / 60, height: 8)
                    }
                } header: {
                    Text("Phone microphone")
                } footer: {
                    Text("Switch between the radio's and the phone's mic on the Operate page. The phone mic sets the radio's AM, FM and SSB MIC SEL menus (053, 085, 103) to USB and puts them back when you switch off or disconnect. Speak at a normal level: peaks should stay out of the red.")
                }

                Section("General") {
                    Toggle("Keep the screen on", isOn: $rig.keepAwake)
                    Toggle("Reconnect when the app opens", isOn: $rig.reconnectOnLaunch)
                }

                Section("Log") {
                    if rig.notes.isEmpty {
                        Text("Nothing yet").foregroundStyle(.secondary)
                    }
                    ForEach(rig.notes.suffix(30).reversed(), id: \.self) { n in
                        Text(n).font(.system(.caption, design: .monospaced))
                    }
                }

                Section {
                    HStack(spacing: 14) {
                        Image("Logo").resizable().frame(width: 52, height: 52)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("RigHelm").font(.headline)
                            Text("Remote control for a RigHelm station (Yaesu FTDX3000)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
        }
    }

    private var statusText: String {
        switch rig.phase {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return rig.state.powerOn == false ? "Connected, radio off" : "Connected"
        case .failed(let why): return why
        }
    }
}
