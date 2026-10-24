// rhcheck: exercise RigHelmCore against a real RigHelm server from the
// command line. Read-only: transmit stays locked and no Set is ever sent.
//
//     rhcheck discover
//     RIGHELM_PASSWORD=... rhcheck listen HOST[:PORT] [SECONDS]

import Foundation
import RigHelmCore

let args = CommandLine.arguments
let queue = DispatchQueue(label: "rhcheck")

func discover() {
    let d = Discovery()
    d.callbackQueue = queue
    d.start()
    Thread.sleep(forTimeInterval: 5)
    for s in d.servers {
        print("\(s.name)  \(s.host):\(s.port)  radio=\(s.radio) audio=\(s.audio) password=\(s.auth) mic=\(s.mic)")
    }
    if d.servers.isEmpty { print("no RigHelm servers found") }
    d.stop()
}

func listen(target: String, seconds: Double) {
    let password = ProcessInfo.processInfo.environment["RIGHELM_PASSWORD"] ?? ""
    let parts = target.split(separator: ":")
    let host = String(parts[0])
    let port = parts.count > 1 ? UInt16(parts[1]) ?? RemoteProtocol.controlPort : RemoteProtocol.controlPort
    let cat = CatClient(host: host, port: port, password: password)
    cat.callbackQueue = queue
    cat.isTransmitAllowed = { false }
    cat.onStatus = { print("cat: \($0)") }
    cat.onNote = { print("note: \($0)") }
    let audio = AudioLink(host: host, port: port, password: password)
    audio.callbackQueue = queue
    var samples = 0
    audio.onAudio = { s, _ in queue.async { samples += s.count } }
    cat.start()
    audio.start()
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        Thread.sleep(forTimeInterval: 1)
        let s = cat.state
        let a = audio.currentStats
        print(String(format: "%@ %@  B %@  S=%@  AF=%d PWR=%dW  tx=%d  width=%@  MICSEL ssb=%@ | audio %@ pkts=%llu lost=%llu level=%.0f dBFS",
                     Frequency.format(s.freqA), s.modeA?.label ?? "?", Frequency.format(s.freqB), MeterCal.sText(s.sMeter),
                     s.afGain, s.power, s.tx, s.widthHz.map(String.init) ?? "-", s.micSel(103).map(String.init) ?? "?",
                     a.connected ? "on" : "off", a.packets, a.lost, a.rxLevelDb))
    }
    print("keyed by us: \(cat.keyedByUs), seen \(cat.state.seen.count) keys, \(queue.sync { samples }) samples")
    cat.stop()
    audio.stop()
    Thread.sleep(forTimeInterval: 0.5)
}

switch args.dropFirst().first {
case "discover": discover()
case "listen" where args.count >= 3: listen(target: args[2], seconds: args.count > 3 ? Double(args[3]) ?? 5 : 5)
default: print("usage: rhcheck discover | rhcheck listen HOST[:PORT] [SECONDS]")
}
