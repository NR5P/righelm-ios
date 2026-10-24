// A typed model of the FTDX3000, updated from CAT answers and
// auto-information (a port of righelm's ftdx3000-cat state and types).

import Foundation

public enum Mode: Character, CaseIterable, Identifiable, Sendable {
    case lsb = "1", usb = "2", cw = "3", fm = "4", am = "5", rttyLsb = "6", cwR = "7"
    case dataLsb = "8", rttyUsb = "9", dataFm = "A", fmN = "B", dataUsb = "C", amN = "D"

    public var id: Character { rawValue }

    /// Front-panel order.
    public static let ordered: [Mode] = [.lsb, .usb, .cw, .cwR, .am, .amN, .fm, .fmN, .rttyLsb, .rttyUsb, .dataLsb, .dataUsb, .dataFm]

    public init?(code: Character) {
        self.init(rawValue: Character(code.uppercased()))
    }

    public var label: String {
        switch self {
        case .lsb: return "LSB"
        case .usb: return "USB"
        case .cw: return "CW"
        case .cwR: return "CW-R"
        case .am: return "AM"
        case .amN: return "AM-N"
        case .fm: return "FM"
        case .fmN: return "FM-N"
        case .rttyLsb: return "RTTY-L"
        case .rttyUsb: return "RTTY-U"
        case .dataLsb: return "DATA-L"
        case .dataUsb: return "DATA-U"
        case .dataFm: return "DATA-FM"
        }
    }

    public var setCommand: String { "MD0\(rawValue);" }

    public var isCW: Bool { self == .cw || self == .cwR }

    /// Phone modes, whose transmit audio is a microphone.
    public var isVoice: Bool { [.lsb, .usb, .am, .amN, .fm, .fmN].contains(self) }

    public var widthClass: WidthClass {
        switch self {
        case .lsb, .usb, .dataLsb, .dataUsb: return .ssb
        case .cw, .cwR: return .cw
        case .rttyLsb, .rttyUsb: return .rtty
        case .am, .amN, .fm, .fmN, .dataFm: return .fixed
        }
    }
}

public enum WidthClass: Sendable { case ssb, cw, rtty, fixed }

/// Table 5: `SH` index -> bandwidth in Hz. Index 0 is the default width.
public func widthHz(_ cls: WidthClass, narrow: Bool, index: Int) -> Int? {
    let ssbN = [1500, 200, 400, 600, 850, 1100, 1350, 1500, 1650, 1800]
    let ssbW = [2400, 0, 0, 0, 0, 0, 0, 0, 0, 1800, 1950, 2100, 2200, 2300, 2400, 2500, 2600, 2700, 2800, 2900, 3000, 3200, 3400, 3600, 3800, 4000]
    let cwN = [500, 50, 100, 150, 200, 250, 300, 350, 400, 450, 500]
    let cwW = [2400, 0, 0, 0, 0, 0, 0, 0, 0, 0, 500, 800, 1200, 1400, 1700, 2000, 2400]
    let table: [Int]
    switch (cls, narrow) {
    case (.ssb, true): table = ssbN
    case (.ssb, false): table = ssbW
    case (.cw, true), (.rtty, true): table = cwN
    case (.cw, false), (.rtty, false): table = cwW
    case (.fixed, _): return nil
    }
    guard table.indices.contains(index), table[index] != 0 else { return nil }
    return table[index]
}

/// Valid `SH` indexes (skipping 0, the "default" alias) with their widths.
public func widthChoices(_ cls: WidthClass, narrow: Bool) -> [(index: Int, hz: Int)] {
    (1...25).compactMap { i in widthHz(cls, narrow: narrow, index: i).map { (i, $0) } }
}

public struct Band: Identifiable, Sendable {
    public let code: Int
    public let label: String
    public let lo: Int
    public let hi: Int
    public var id: Int { code }
    public var setCommand: String { String(format: "BS%02d;", code) }

    public static let all: [Band] = [
        Band(code: 0, label: "160", lo: 1_800_000, hi: 2_000_000),
        Band(code: 1, label: "80", lo: 3_500_000, hi: 4_000_000),
        Band(code: 2, label: "60", lo: 5_250_000, hi: 5_450_000),
        Band(code: 3, label: "40", lo: 7_000_000, hi: 7_300_000),
        Band(code: 4, label: "30", lo: 10_100_000, hi: 10_150_000),
        Band(code: 5, label: "20", lo: 14_000_000, hi: 14_350_000),
        Band(code: 6, label: "17", lo: 18_068_000, hi: 18_168_000),
        Band(code: 7, label: "15", lo: 21_000_000, hi: 21_450_000),
        Band(code: 8, label: "12", lo: 24_890_000, hi: 24_990_000),
        Band(code: 9, label: "10", lo: 28_000_000, hi: 29_700_000),
        Band(code: 10, label: "6", lo: 50_000_000, hi: 54_000_000),
    ]

    public static func of(_ hz: Int) -> Band? { all.first { (Int($0.lo)...Int($0.hi)).contains(hz) } }
}

public enum Frequency {
    public static let min = 30_000
    public static let max = 60_000_000

    public static func setCommand(vfoB: Bool, hz: Int) -> String {
        String(format: "F%@%08d;", vfoB ? "B" : "A", Swift.min(Swift.max(hz, min), max))
    }

    /// 14074000 -> "14.074.000"
    public static func format(_ hz: Int) -> String {
        let mhz = hz / 1_000_000
        let khz = hz / 1000 % 1000
        let rest = hz % 1000
        return String(format: "%d.%03d.%03d", mhz, khz, rest)
    }
}

public enum AGC {
    public static func label(_ code: Int) -> String {
        ["OFF", "FAST", "MID", "SLOW", "AUTO-F", "AUTO-M", "AUTO-S"].indices.contains(code)
            ? ["OFF", "FAST", "MID", "SLOW", "AUTO-F", "AUTO-M", "AUTO-S"][code] : "?"
    }

    public static let choices: [(code: Int, label: String)] = [(0, "OFF"), (1, "FAST"), (2, "MID"), (3, "SLOW"), (4, "AUTO")]
}

public enum Roofing {
    public static func label(_ code: Character) -> String? {
        switch Character(code.uppercased()) {
        case "1": return "15 kHz"
        case "2": return "6 kHz"
        case "3": return "3 kHz"
        case "4": return "AUTO 15 kHz"
        case "5": return "AUTO 6 kHz"
        case "6": return "AUTO 3 kHz"
        case "7": return "600 Hz"
        case "8": return "300 Hz"
        case "9": return "AUTO 600 Hz"
        case "A": return "AUTO 300 Hz"
        default: return nil
        }
    }

    public static let choices: [(code: Character, label: String)] =
        [("0", "AUTO"), ("1", "15 kHz"), ("2", "6 kHz"), ("3", "3 kHz"), ("4", "600 Hz"), ("5", "300 Hz")]
}

// MARK: - Meters

public enum Meter: Character, CaseIterable, Sendable {
    case s = "1", comp = "3", alc = "4", po = "5", swr = "6", id = "7", vdd = "8"
}

public enum MeterCal {
    public static let sMeter: [(Int, Double)] = [
        (0, -54), (12, -48), (27, -42), (40, -36), (55, -30), (65, -24), (80, -18), (95, -12),
        (112, -6), (130, 0), (150, 10), (172, 20), (190, 30), (220, 40), (240, 50), (255, 60),
    ]
    public static let po: [(Int, Double)] = [
        (0, 0), (55, 10), (75, 20), (101, 40), (125, 60), (144, 80), (161, 100), (177, 120),
        (190, 140), (202, 160), (215, 180), (225, 200), (237, 220), (242, 240), (255, 250),
    ]
    public static let swr: [(Int, Double)] = [(0, 1.0), (26, 1.2), (52, 1.5), (89, 2.0), (126, 3.0), (173, 4.0), (236, 5.0), (255, 10.0)]
    public static let id: [(Int, Double)] = [(0, 0), (255, 25)]
    public static let vdd: [(Int, Double)] = [(0, 0), (255, 15)]

    public static func interpolate(_ table: [(Int, Double)], _ raw: Int) -> Double {
        guard let first = table.first else { return Double(raw) }
        if raw <= first.0 { return first.1 }
        for i in 1..<table.count {
            let (r0, v0) = table[i - 1]
            let (r1, v1) = table[i]
            if raw <= r1 {
                return v0 + Double(raw - r0) / Double(Swift.max(r1 - r0, 1)) * (v1 - v0)
            }
        }
        return table[table.count - 1].1
    }

    /// "S7", "S9+20"
    public static func sText(_ raw: Int) -> String {
        let db = interpolate(sMeter, raw)
        if db <= 0 {
            return "S\(Int(((db + 54) / 6).rounded()).clamped(0, 9))"
        }
        return "S9+\(Int((db / 10).rounded() * 10))"
    }
}

extension Comparable {
    func clamped(_ lo: Self, _ hi: Self) -> Self { Swift.min(Swift.max(self, lo), hi) }
}

// MARK: - State

/// The information block of `IF`, `OI` and `MR` answers.
public struct ChannelInfo: Equatable, Sendable {
    public var channel = 0
    public var freq = 0
    public var clarOffset = 0
    public var rxClar = false
    public var txClar = false
    public var mode: Mode?
    /// 0 VFO, 1 memory, 2 memory tune, 3 QMB, 4 QMB-MT.
    public var memMode = 0

    public init() {}

    public static func parse(_ p: String) -> ChannelInfo? {
        let c = Array(p)
        guard c.count >= 24 else { return nil }
        func s(_ a: Int, _ b: Int) -> String { String(c[a..<b]) }
        guard let ch = Int(s(0, 3)), let f = Int(s(3, 11)), let off = Int(s(12, 16)) else { return nil }
        var i = ChannelInfo()
        i.channel = ch
        i.freq = f
        i.clarOffset = c[11] == "-" ? -off : off
        i.rxClar = c[16] == "1"
        i.txClar = c[17] == "1"
        i.mode = Mode(code: c[18])
        i.memMode = Int(s(19, 20)) ?? 0
        return i
    }
}

public struct RadioState: Equatable, Sendable {
    /// Answer keys seen at least once ("FA", "AG0", "EX053"...).
    public var seen: Set<String> = []

    public var id: Int?
    public var powerOn: Bool?
    public var freqA = 0
    public var freqB = 0
    public var modeA: Mode?
    public var modeB: Mode?
    public var infoA = ChannelInfo()
    public var infoB = ChannelInfo()
    /// VS: 0 VFO-A, 1 VFO-B.
    public var vfoSelect = 0
    /// FR: 0 A rx, 1 A mute, 4 B rx, 5 B mute.
    public var rxFunction = 0
    /// FT answer: 0 VFO-A transmitter, 1 VFO-B transmitter.
    public var txVFO = 0
    /// TX answer: 0 off, 1 CAT TX, 2 radio TX (PTT/MOX/VOX).
    public var tx = 0
    public var mox = false
    public var busy = false

    public var afGain = 0
    public var rfGain = 0
    public var squelch = 0
    public var power = 0
    public var micGain = 0
    public var procLevel = 0
    public var processor = false
    public var micEQ = false
    public var vox = false
    public var voxGain = 0
    public var voxDelay = 0
    public var monitor = false
    public var monitorLevel = 0

    /// NB: 0 off, 1 on, 2 wide.
    public var nb = 0
    public var nbLevel = 0
    public var nr = false
    public var nrLevel = 0
    public var autoNotch = false
    public var manualNotch = false
    /// Manual notch frequency in 10 Hz units (1-400).
    public var notchFreq = 0
    /// CO00: 0 off, 1 contour, 2 APF.
    public var contourMode = 0
    /// CO01: 1-40 (x100 Hz).
    public var contourFreq = 0
    /// CO02: 0-50 (APF -250..+250 Hz, 25 = centre).
    public var apfFreq = 25
    public var widthIndex = 0
    public var narrow = false
    public var ifShift = 0
    public var roofing: Character = "0"
    /// RA: 0 off, 1 6 dB, 2 12 dB, 3 18 dB.
    public var att = 0
    /// PA: 0 IPO, 1 AMP1, 2 AMP2.
    public var preamp = 0
    public var agc = 0

    public var antenna = 1
    /// AC P3: 0 off, 1 on, 2 tuning.
    public var tuner = 0

    public var keyer = false
    public var keySpeed = 0
    /// KP 0-75 -> 300 + 10*n Hz.
    public var keyPitch = 0
    public var breakIn = false
    public var bkDelay = 0

    public var rxClar = false
    public var txClar = false
    public var lock = 0
    public var fast = 0
    public var meterSelect = 0

    /// Raw meter readings 0-255 by RM code.
    public var meters: [Character: Int] = [:]
    public var sMeter = 0
    /// RI flags by P1 code (0 = HI-SWR).
    public var radioInfo: [Int: Bool] = [:]
    /// EX menu raw parameter text by item number.
    public var menu: [Int: String] = [:]

    public init() {}

    public var transmitting: Bool { tx != 0 || mox }
    public var rxOnB: Bool { rxFunction >= 4 }
    public var split: Bool { (txVFO == 1) != rxOnB }
    public var rxFreq: Int { rxOnB ? freqB : freqA }
    public var rxMode: Mode? { rxOnB ? modeB : modeA }
    public var txMode: Mode? { txVFO == 1 ? modeB : modeA }
    public var txFreq: Int { txVFO == 1 ? freqB : freqA }
    public var highSWR: Bool { radioInfo[0] == true }

    public func meter(_ m: Meter) -> Int? { m == .s ? sMeter : meters[m.rawValue] }

    public func widthClass(_ mode: Mode) -> WidthClass {
        switch mode {
        // DATA modes use the RTTY/PSK widths unless menu 067 DATA MODE is OTHER.
        case .dataLsb, .dataUsb: return menu[67] == "1" ? .ssb : .rtty
        default: return mode.widthClass
        }
    }

    public var widthHz: Int? {
        guard let m = modeA else { return nil }
        return RigHelmCore.widthHz(widthClass(m), narrow: narrow, index: widthIndex)
    }

    /// The MIC SEL code of a menu (53 AM, 85 FM, 103 SSB): 0 front, 1 data, 2 USB.
    public func micSel(_ menuItem: Int) -> Int? { menu[menuItem].flatMap { Int($0) } }

    /// Apply one frame from the radio. Returns false if it was not understood.
    @discardableResult
    public mutating func apply(_ frame: String) -> Bool {
        var body = Substring(frame)
        if body.hasSuffix(";") { body = body.dropLast() }
        guard body.count >= 2 else { return false }
        let code = body.prefix(2).uppercased()
        guard code.allSatisfy(\.isLetter) else { return false }
        let p = Array(body.dropFirst(2))
        guard applyInner(code, p) else { return false }
        if let key = CatCommand.answerKey(frame) { seen.insert(key) }
        return true
    }

    private mutating func applyInner(_ code: String, _ p: [Character]) -> Bool {
        func at(_ i: Int) -> String { p.indices.contains(i) ? String(p[i]) : "" }
        func from(_ i: Int) -> String { i < p.count ? String(p[i...]) : "" }
        func n(_ s: String) -> Int? { Int(s.hasPrefix("+") ? String(s.dropFirst()) : s) }
        let all = String(p)
        let flag = { (s: String) in s == "1" }
        switch code {
        case "AC": guard let v = n(at(2)) else { return false }; tuner = v
        case "AG": guard let v = n(from(1)) else { return false }; afGain = v
        case "AI": break
        case "AN": guard let v = n(at(1)) else { return false }; antenna = v
        case "BC": autoNotch = flag(at(1))
        case "BI": breakIn = flag(all)
        case "BP":
            switch at(1) {
            case "0": guard let v = n(from(2)) else { return false }; manualNotch = v != 0
            case "1": guard let v = n(from(2)) else { return false }; notchFreq = v
            default: return false
            }
        case "BY": busy = flag(at(0))
        case "CO":
            guard let v = n(from(2)) else { return false }
            switch at(1) {
            case "0": contourMode = v
            case "1": contourFreq = v
            case "2": apfFreq = v
            default: return false
            }
        case "EX":
            guard p.count >= 3, let num = Int(String(p[0..<3])) else { return false }
            menu[num] = String(p[3...])
        case "FA": guard let v = n(all) else { return false }; freqA = v; infoA.freq = v
        case "FB": guard let v = n(all) else { return false }; freqB = v; infoB.freq = v
        case "FR": guard let v = n(all) else { return false }; rxFunction = v
        case "FS": guard let v = n(all) else { return false }; fast = v
        case "FT": guard let v = n(all) else { return false }; txVFO = v
        case "GT": guard let v = n(at(1)) else { return false }; agc = v
        case "ID": guard let v = n(all) else { return false }; id = v
        case "IF":
            guard let info = ChannelInfo.parse(all) else { return false }
            freqA = info.freq
            modeA = info.mode ?? modeA
            rxClar = info.rxClar
            txClar = info.txClar
            infoA = info
        case "IS": guard let v = n(from(1)) else { return false }; ifShift = v
        case "KP": guard let v = n(all) else { return false }; keyPitch = v
        case "KR": keyer = flag(all)
        case "KS": guard let v = n(all) else { return false }; keySpeed = v
        case "LK": guard let v = n(all) else { return false }; lock = v
        case "MD":
            guard let c = p.dropFirst().first, let m = Mode(code: c) else { return false }
            modeA = m
            infoA.mode = m
        case "MG": guard let v = n(all) else { return false }; micGain = v
        case "ML":
            guard let v = n(from(1)) else { return false }
            switch at(0) {
            case "0": monitor = v != 0
            case "1": monitorLevel = v
            default: return false
            }
        case "MS": guard let v = n(all) else { return false }; meterSelect = v
        case "MX": mox = flag(all)
        case "NA": narrow = flag(at(1))
        case "NB": guard let v = n(at(1)) else { return false }; nb = v
        case "NL": guard let v = n(from(1)) else { return false }; nbLevel = v
        case "NR": nr = flag(at(1))
        case "OI":
            guard let info = ChannelInfo.parse(all) else { return false }
            freqB = info.freq
            modeB = info.mode ?? modeB
            infoB = info
        case "PA": guard let v = n(at(1)) else { return false }; preamp = v
        case "PC": guard let v = n(all) else { return false }; power = v
        case "PL": guard let v = n(all) else { return false }; procLevel = v
        case "PR":
            switch at(0) {
            case "0": processor = at(1) == "1"
            case "1": micEQ = at(1) == "1"
            default: return false
            }
        case "PS": powerOn = flag(all)
        case "RA": guard let v = n(at(1)) else { return false }; att = v
        case "RF": guard p.count >= 2 else { return false }; roofing = p[1]
        case "RG": guard let v = n(from(1)) else { return false }; rfGain = v
        case "RI": guard let k = n(at(0)) else { return false }; radioInfo[k] = flag(at(1))
        case "RL": guard let v = n(from(1)) else { return false }; nrLevel = v
        case "RM":
            guard let c = p.first, let v = n(from(1)) else { return false }
            if c == "1" { sMeter = v }
            meters[c] = v
        case "RT": rxClar = flag(all)
        case "SD": guard let v = n(all) else { return false }; bkDelay = v
        case "SH": guard let v = n(from(1)) else { return false }; widthIndex = v
        case "SM": guard let v = n(from(1)) else { return false }; sMeter = v
        case "SQ": guard let v = n(from(1)) else { return false }; squelch = v
        case "TX": guard let v = n(all) else { return false }; tx = v
        case "VD": guard let v = n(all) else { return false }; voxDelay = v
        case "VG": guard let v = n(all) else { return false }; voxGain = v
        case "VS": guard let v = n(all) else { return false }; vfoSelect = v
        case "VX": vox = flag(all)
        case "XT": txClar = flag(all)
        default: return false
        }
        return true
    }
}
