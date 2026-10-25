import RigHelmCore
import SwiftUI

/// Keyer settings and the text line while the phone key is armed.
struct CWKeyCard: View {
    @Environment(RigController.self) private var rig
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        @Bindable var rig = rig
        let st = rig.cwStatus
        let wpm = max(rig.state.keySpeed, 4)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("● PHONE KEY").font(.caption.bold()).foregroundStyle(Theme.red)
                    if !st.ready && st.error == nil {
                        ProgressView().controlSize(.mini).tint(Theme.amber)
                        Text("opening the keying line…").font(.caption).foregroundStyle(Theme.amber)
                    } else if st.sendingText {
                        Text("sending…").font(.caption).foregroundStyle(Theme.amber)
                    }
                    Spacer()
                    Button("Radio key") { rig.setPhoneKey(false) }
                        .font(.caption.bold())
                        .buttonStyle(.bordered)
                        .tint(Theme.amber)
                }
                Picker("Key type", selection: $rig.keyerMode) {
                    ForEach(KeyerMode.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)
                HStack(spacing: 10) {
                    Text("SPEED").font(.caption2.bold()).foregroundStyle(Theme.dim)
                    Button { setSpeed(wpm - 1) } label: { Image(systemName: "minus") }
                        .buttonStyle(.bordered)
                        .buttonRepeatBehavior(.enabled)
                    Text("\(wpm) WPM")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .frame(minWidth: 70)
                    Button { setSpeed(wpm + 1) } label: { Image(systemName: "plus") }
                        .buttonStyle(.bordered)
                        .buttonRepeatBehavior(.enabled)
                    Spacer()
                    Toggle("Sidetone", isOn: $rig.cwSidetone)
                        .labelsHidden()
                        .tint(Theme.cyan)
                    Image(systemName: rig.cwSidetone ? "speaker.wave.2.fill" : "speaker.slash")
                        .foregroundStyle(rig.cwSidetone ? Theme.cyan : Theme.dim)
                }
                HStack(spacing: 8) {
                    TextField("CQ CQ DE …", text: $text)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.send)
                        .focused($typing)
                        .onSubmit(send)
                        .padding(8)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                    Button("Send", action: send)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.red)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || !st.ready)
                    Button("Stop") { rig.cwStop() }
                        .buttonStyle(.bordered)
                        .tint(Theme.red)
                }
                if let n = st.note {
                    Text(n).font(.caption).foregroundStyle(Theme.amber)
                }
                Text(rig.keyerMode == .straight
                     ? "Hold the key below to transmit. Typed text is sent at the speed above."
                     : "Left paddle = dit, right = dah; hold both to squeeze. Touching the paddles stops typed text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.red.opacity(0.7), lineWidth: 1.5))
    }

    private func send() {
        rig.cwSendText(text)
        text = ""
    }

    private func setSpeed(_ wpm: Int) {
        rig.send(String(format: "KS%03d;", min(max(wpm, 4), 60)))
    }
}

/// The paddles (or straight key), pinned above the tab bar in place of
/// push-to-talk while the phone key is armed.
struct PaddleBar: View {
    @Environment(RigController.self) private var rig
    @State private var held = (dit: false, dah: false)

    var body: some View {
        let straight = rig.keyerMode == .straight
        let ready = rig.cwStatus.ready
        HStack(spacing: 8) {
            if straight {
                pad("KEY", lit: held.dit || held.dah || rig.cwStatus.down, hint: "hold to transmit")
            } else {
                pad("DIT", lit: held.dit, hint: "left paddle")
                pad("DAH", lit: held.dah, hint: "right paddle")
            }
        }
        .opacity(ready ? 1 : 0.45)
        .frame(height: 92)
        .overlay(PaddleSurface { dit, dah in
            held = (dit, dah)
            rig.cwPaddles(dit: dit, dah: dah)
        })
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .accessibilityLabel("CW key")
    }

    private func pad(_ name: String, lit: Bool, hint: String) -> some View {
        VStack(spacing: 4) {
            Text(name).font(.system(size: 22, weight: .heavy))
            Text(hint).font(.caption2).opacity(0.7)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(lit ? Theme.red : Color(red: 0.25, green: 0.08, blue: 0.08))
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Theme.red.opacity(0.6), lineWidth: 1.5))
    }
}

/// Multi-touch paddles with no delay: the left half is dit, the right half
/// dah, and each finger stays on the paddle it first touched (so thumbs on
/// both halves squeeze).
struct PaddleSurface: UIViewRepresentable {
    let onChange: (_ dit: Bool, _ dah: Bool) -> Void

    func makeUIView(context: Context) -> PaddleView {
        let view = PaddleView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: PaddleView, context: Context) {
        view.onChange = onChange
    }

    final class PaddleView: UIView {
        var onChange: ((Bool, Bool) -> Void)?
        /// Each finger and whether it is on the dit side.
        private var fingers: [ObjectIdentifier: Bool] = [:]
        private var last = (dit: false, dah: false)

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .clear
            isMultipleTouchEnabled = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            for t in touches {
                fingers[ObjectIdentifier(t)] = t.location(in: self).x < bounds.midX
            }
            report()
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            lift(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            lift(touches)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // Taken off screen with a finger down: let go.
            if window == nil {
                fingers.removeAll()
                report()
            }
        }

        private func lift(_ touches: Set<UITouch>) {
            for t in touches { fingers[ObjectIdentifier(t)] = nil }
            report()
        }

        private func report() {
            let now = (dit: fingers.values.contains(true), dah: fingers.values.contains(false))
            guard now != last else { return }
            last = now
            onChange?(now.dit, now.dah)
        }
    }
}
