// FTDX3000 CAT framing and command classification.

import Foundation

/// Splits a CAT byte stream into `;`-terminated frames. Control characters
/// are dropped, as the radio does.
public struct Framer {
    private var buf = ""
    public static let maxFrame = 128

    public init() {}

    public mutating func push(_ bytes: [UInt8]) -> [String] {
        var out: [String] = []
        for b in bytes {
            if b == UInt8(ascii: ";") {
                out.append(buf + ";")
                buf = ""
            } else if b >= 0x20 && b < 0x7f {
                if buf.count >= Framer.maxFrame { buf = "" }
                if !(b == 0x20 && buf.isEmpty) { buf.append(Character(UnicodeScalar(b))) }
            }
        }
        return out
    }
}

public enum CatCommand {
    /// Readable state polled in the background, slowest group (from righelm's engine).
    public static let miscPoll = [
        "AC;", "AG0;", "AN0;", "BC0;", "BI;", "BP00;", "BP01;", "BY;", "CO00;", "CO01;", "CO02;",
        "FR;", "FS;", "FT;", "GT0;", "IS0;", "KP;", "KR;", "KS;", "LK;", "MG;",
        "ML0;", "ML1;", "MS;", "MX;", "NA0;", "NB0;", "NL0;", "NR0;", "PA0;", "PC;", "PL;", "PR0;",
        "PR1;", "RA0;", "RF0;", "RG0;", "RI0;", "RL0;", "RT;", "SD;", "SH0;", "SQ0;",
        "VD;", "VG;", "VS;", "VX;", "XT;",
        // MIC SEL (AM, FM, SSB): where transmit audio comes from.
        "EX053;", "EX085;", "EX103;", "EX067;",
    ]

    public static let vfoPoll = ["FA;", "FB;", "MD0;", "IF;", "OI;"]

    /// Keys that change as a side effect of VFO, band or mode operations.
    public static let vfoKeys = ["FA;", "FB;", "IF;", "OI;", "MD0;", "SH0;", "NA0;", "RF0;", "FT;", "FR;", "VS;", "PA0;", "RA0;", "AN0;", "GT0;"]

    /// Commands whose Set moves the VFOs or the mode.
    static let vfoMovers: Set<String> = ["MD", "BS", "BU", "BD", "AB", "BA", "SV", "FR", "FT", "VS", "QS", "MC", "MA", "AM", "UP", "DN"]

    private static let readable = Set(miscPoll + vfoPoll + ["TX;", "SM0;", "RM3;", "RM4;", "RM5;", "RM6;", "RM8;", "ID;", "PS;"])

    /// Split text such as "FA14074000;MD02;" into frames.
    public static func frames(_ text: String) -> [String] {
        text.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 2 }.map { $0 + ";" }
    }

    /// Does this Set command make the radio transmit, or arm it to? PTT/MOX
    /// on, tuner start (sends a carrier), keyer/voice/encoder playback, VOX on.
    public static func isTransmit(_ frame: String) -> Bool {
        let body = frame.hasSuffix(";") ? String(frame.dropLast()) : frame
        guard body.count >= 2 else { return false }
        let code = body.prefix(2).uppercased()
        let p = String(body.dropFirst(2))
        if p.isEmpty { return false } // a Read
        switch code {
        case "TX", "MX": return p != "0"
        case "AC": return p.hasSuffix("2")
        case "KY", "EN": return true
        case "PB": return p.count >= 2 && Array(p)[1] != "0"
        case "VX": return p == "1"
        default: return false
        }
    }

    public static func isUnkey(_ frame: String) -> Bool {
        let f = frame.uppercased()
        return f == "TX0;" || f == "MX0;"
    }

    /// The Read that fetches what a Set changes ("AG0128;" -> "AG0;").
    public static func readback(for set: String) -> String? {
        let body = set.uppercased().dropLast()
        var best: String?
        for r in readable {
            let rb = r.dropLast()
            if body.count > rb.count, body.hasPrefix(rb), best.map({ rb.count > $0.count - 1 }) ?? true {
                best = r
            }
        }
        return best
    }

    /// Key identifying what an answer reports ("AG0128;" -> "AG0", "EX0532;" -> "EX053").
    public static func answerKey(_ frame: String) -> String? {
        let up = frame.uppercased()
        if up.hasPrefix("EX"), up.count >= 6 { return String(up.prefix(5)) }
        if up.hasPrefix("RM"), up.count >= 4 { return String(up.prefix(3)) }
        return readback(for: up).map { String($0.dropLast()) } ?? (up.count >= 2 ? String(up.prefix(2)) : nil)
    }

    /// Whether a Set moves the VFOs, band or mode (so related keys are re-read).
    public static func movesVFO(_ frame: String) -> Bool {
        vfoMovers.contains(String(frame.uppercased().prefix(2))) && frame.count > 3
    }
}
