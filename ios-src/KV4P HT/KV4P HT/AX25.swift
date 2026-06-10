import Foundation

// AX.25 UI-frame encoding/decoding for APRS, ported from the Android app's
// aprs/parser package (Callsign.java, Digipeater.java, APRSPacket.toAX25Frame,
// Parser.parseAX25). Frames are exchanged with the firmware as raw bytes
// without FCS — the ESP32 AFSK modem adds/strips the checksum.

let KV4P_HT_VENDOR_TOCALL = "APKVPA"

struct AX25Callsign: Equatable {
    var base: String        // up to 6 chars, uppercased
    var ssid: UInt8         // 0–15
    var hasBeenRepeated: Bool = false   // '*' flag, bit 0x80 of the SSID byte

    init(base: String, ssid: UInt8, hasBeenRepeated: Bool = false) {
        self.base = base.uppercased()
        self.ssid = ssid
        self.hasBeenRepeated = hasBeenRepeated
    }

    // "N0CALL-7" or "WIDE1-1*"
    init?(parsing text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("*") {
            hasBeenRepeated = true
            s = String(s.dropLast())
        }
        let parts = s.split(separator: "-", maxSplits: 1)
        guard let first = parts.first, !first.isEmpty, first.count <= 6 else { return nil }
        base = first.uppercased()
        if parts.count > 1 {
            guard let v = UInt8(parts[1]), v <= 15 else { return nil }
            ssid = v
        } else {
            ssid = 0
        }
    }

    // 7 wire bytes: chars shifted left one bit, SSID byte 0x60 | (ssid << 1).
    init?(decoding data: Data, at offset: Int) {
        guard data.count >= offset + 7 else { return nil }
        var chars = [UInt8]()
        for i in 0..<6 {
            chars.append(data[data.startIndex + offset + i] >> 1)
        }
        guard let s = String(bytes: chars, encoding: .ascii) else { return nil }
        base = s.trimmingCharacters(in: .whitespaces)
        let ssidByte = data[data.startIndex + offset + 6]
        ssid = (ssidByte & 0x1e) >> 1
        hasBeenRepeated = (ssidByte & 0x80) != 0
    }

    var display: String {
        ssid == 0 ? base : "\(base)-\(ssid)"
    }

    func encoded(last: Bool) -> Data {
        var out = [UInt8](repeating: 0x40, count: 7)  // ' ' << 1
        for (i, c) in base.uppercased().utf8.prefix(6).enumerated() {
            out[i] = c << 1
        }
        out[6] = 0x60 | ((ssid << 1) & 0x1e)
        if hasBeenRepeated { out[6] |= 0x80 }
        if last { out[6] |= 0x01 }
        return Data(out)
    }
}

let defaultDigipeaters: [AX25Callsign] = [
    AX25Callsign(base: "WIDE1", ssid: 1),
    AX25Callsign(base: "WIDE2", ssid: 1),
]

struct AX25Frame {
    var destination: AX25Callsign
    var source: AX25Callsign
    var digipeaters: [AX25Callsign]
    var payload: Data

    init(destination: AX25Callsign, source: AX25Callsign,
         digipeaters: [AX25Callsign], payload: Data) {
        self.destination = destination
        self.source = source
        self.digipeaters = Array(digipeaters.prefix(8))
        self.payload = payload
    }

    // Outgoing app-originated packet: TOCALL is the assigned vendor ID,
    // destination marked has-been-repeated to match Android's toAX25Frame.
    init(source: AX25Callsign, digipeaters: [AX25Callsign] = defaultDigipeaters,
         payload: Data) {
        var dest = AX25Callsign(base: KV4P_HT_VENDOR_TOCALL, ssid: 0)
        dest.hasBeenRepeated = true
        self.init(destination: dest, source: source,
                  digipeaters: digipeaters, payload: payload)
    }

    init?(decoding data: Data) {
        guard data.count >= 16 else { return nil }
        var pos = 0
        guard let dest = AX25Callsign(decoding: data, at: pos) else { return nil }
        pos += 7
        guard let src = AX25Callsign(decoding: data, at: pos) else { return nil }
        pos += 7
        var digis: [AX25Callsign] = []
        // Address list ends at the byte with the last-address bit set.
        while (data[data.startIndex + pos - 1] & 0x01) == 0 {
            guard data.count >= pos + 7, digis.count < 8,
                  let d = AX25Callsign(decoding: data, at: pos) else { return nil }
            digis.append(d)
            pos += 7
        }
        guard data.count >= pos + 2,
              data[data.startIndex + pos] == 0x03,
              data[data.startIndex + pos + 1] == 0xF0 else { return nil }
        pos += 2
        destination = dest
        source = src
        digipeaters = digis
        payload = Data(data.dropFirst(pos))
    }

    func encodedWithoutFCS() -> Data {
        var out = Data()
        out.append(destination.encoded(last: false))
        out.append(source.encoded(last: digipeaters.isEmpty))
        for (i, digi) in digipeaters.enumerated() {
            out.append(digi.encoded(last: i == digipeaters.count - 1))
        }
        out.append(0x03)  // control: UI frame
        out.append(0xF0)  // PID: no layer 3
        out.append(payload)
        return out
    }
}
