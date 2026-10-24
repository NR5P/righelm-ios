import XCTest
@testable import RigHelmCore

final class ProtocolTests: XCTestCase {
    func testProofMatchesServer() {
        // Python: hmac.new(b"secret", b"ftdx3000:0123456789abcdef:CAT", sha256)
        XCTAssertEqual(RemoteProtocol.proof(password: "secret", nonce: "0123456789abcdef", mode: "CAT"),
                       "a24b82faf7ccc57095b516d26cd00f51d56966dc2d44a1f21efa8b5b0a850ab0")
    }

    func testBeacon() {
        let b = ServerBeacon.parse("FTDX3000-REMOTE v1;id=b7974e2e3ab6a5b1;name=thinkpad;port=4533;audio=1;auth=1;mic=0;radio=connected", from: "192.168.1.5")
        XCTAssertEqual(b?.name, "thinkpad")
        XCTAssertEqual(b?.host, "192.168.1.5")
        XCTAssertEqual(b?.port, 4533)
        XCTAssertEqual(b?.auth, true)
        XCTAssertEqual(b?.mic, false)
        XCTAssertEqual(b?.radio, "connected")
        XCTAssertNil(ServerBeacon.parse("FTDX3000-DISCOVER", from: "1.2.3.4"))
    }

    func testAudioPacketRoundTrip() {
        let p = AudioPacket.encode(kind: AudioPacket.rx, session: 42, seq: 7, samples: [1, -2, 3])
        XCTAssertEqual(p.count, 22)
        let d = AudioPacket.decode(p)
        XCTAssertEqual(d?.kind, AudioPacket.rx)
        XCTAssertEqual(d?.session, 42)
        XCTAssertEqual(d?.seq, 7)
        XCTAssertEqual(d?.samples, [1, -2, 3])
        XCTAssertNil(AudioPacket.decode(Array("nope".utf8)))
    }

    func testSweepCoversSubnet() {
        let iface = NetInterface(name: "en0", address: 0xC0A8_0AEA, netmask: 0xFFFF_FF00, broadcast: 0xC0A8_0AFF)
        let hosts = Discovery.sweep(iface)
        XCTAssertEqual(hosts.count, 253)
        XCTAssertTrue(hosts.contains(0xC0A8_0ADF)) // .223
        XCTAssertFalse(hosts.contains(0xC0A8_0AEA)) // ourselves
        let wide = NetInterface(name: "en0", address: 0x0A00_0105, netmask: 0xFFFF_0000, broadcast: 0x0A00_FFFF)
        XCTAssertEqual(Discovery.sweep(wide).count, 253)
    }
}

final class CatTests: XCTestCase {
    func testTransmitClassification() {
        for f in ["TX1;", "TX2;", "MX1;", "AC002;", "KY1;", "PB01;", "VX1;", "EN1;"] {
            XCTAssertTrue(CatCommand.isTransmit(f), f)
        }
        for f in ["TX0;", "MX0;", "AC001;", "AC000;", "PB00;", "VX0;", "FA14074000;", "TX;", "MD02;"] {
            XCTAssertFalse(CatCommand.isTransmit(f), f)
        }
    }

    func testReadback() {
        XCTAssertEqual(CatCommand.readback(for: "AG0128;"), "AG0;")
        XCTAssertEqual(CatCommand.readback(for: "BP01040;"), "BP01;")
        XCTAssertEqual(CatCommand.readback(for: "FA07074000;"), "FA;")
        XCTAssertEqual(CatCommand.readback(for: "EX0532;"), "EX053;")
        XCTAssertEqual(CatCommand.answerKey("RM5161;"), "RM5")
    }

    func testFramer() {
        var f = Framer()
        XCTAssertEqual(f.push(Array("FA0707".utf8)), [])
        XCTAssertEqual(f.push(Array("4000;\r\nMD03;".utf8)), ["FA07074000;", "MD03;"])
    }

    func testBlockedTransmitNeverQueues() {
        let c = CatClient(host: "127.0.0.1", password: "")
        c.isTransmitAllowed = { false }
        c.send("TX1;")
        XCTAssertFalse(c.keyedByUs)
        c.isTransmitAllowed = { true }
        c.send("TX1;")
        XCTAssertTrue(c.keyedByUs)
        c.send("TX0;")
        XCTAssertFalse(c.keyedByUs)
    }
}

final class StateTests: XCTestCase {
    func testParsesIF() {
        var s = RadioState()
        XCTAssertTrue(s.apply("IF00114074000+012010200000;"))
        XCTAssertEqual(s.freqA, 14_074_000)
        XCTAssertEqual(s.infoA.clarOffset, 120)
        XCTAssertTrue(s.rxClar)
        XCTAssertFalse(s.txClar)
        XCTAssertEqual(s.modeA, .usb)
        XCTAssertTrue(s.seen.contains("IF"))
    }

    func testCommonAnswers() {
        var s = RadioState()
        for f in ["FA07074000;", "FB14074000;", "MD03;", "AG0128;", "SM0130;", "RM5161;", "TX1;", "FT1;", "FR0;", "EX0383;", "NA01;", "SH010;", "IS0-0120;", "RF04;"] {
            XCTAssertTrue(s.apply(f), f)
        }
        XCTAssertEqual(s.freqA, 7_074_000)
        XCTAssertEqual(s.modeA, .cw)
        XCTAssertEqual(s.afGain, 128)
        XCTAssertEqual(s.sMeter, 130)
        XCTAssertEqual(s.meter(.po), 161)
        XCTAssertTrue(s.transmitting)
        XCTAssertTrue(s.split)
        XCTAssertEqual(s.menu[38], "3")
        XCTAssertEqual(s.widthHz, 500)
        XCTAssertEqual(s.ifShift, -120)
        XCTAssertEqual(s.roofing, "4")
        XCTAssertTrue(s.apply("MD0C;"))
        XCTAssertEqual(s.widthClass(.dataUsb), .rtty)
        XCTAssertFalse(s.apply("?;"))
        XCTAssertFalse(s.apply("ZZ1;"))
    }

    func testMeterText() {
        XCTAssertEqual(MeterCal.sText(0), "S0")
        XCTAssertEqual(MeterCal.sText(130), "S9")
        XCTAssertEqual(MeterCal.sText(172), "S9+20")
        XCTAssertEqual(MeterCal.interpolate(MeterCal.po, 161), 100, accuracy: 0.01)
        XCTAssertEqual(Frequency.format(7_137_040), "7.137.040")
        XCTAssertEqual(Frequency.setCommand(vfoB: true, hz: 14_074_000), "FB14074000;")
    }
}
