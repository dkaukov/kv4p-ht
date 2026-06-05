import Foundation

// KISS framing constants
let KISS_FEND:  UInt8 = 0xC0
let KISS_FESC:  UInt8 = 0xDB
let KISS_TFEND: UInt8 = 0xDC
let KISS_TFESC: UInt8 = 0xDD

// KV4P protocol constants
let KV4P_VENDOR_PREFIX:    [UInt8] = [0x4B, 0x56, 0x34, 0x50]
let KV4P_PROTOCOL_VERSION: UInt8   = 0x01

// DesiredState flag bits
let HOST_STATE_RADIO_CONFIG_VALID:    UInt16 = 1 << 0
let HOST_STATE_PTT_REQUESTED:         UInt16 = 1 << 1
let HOST_STATE_RX_AUDIO_OPEN:         UInt16 = 1 << 2
let HOST_STATE_HIGH_POWER:            UInt16 = 1 << 3
let HOST_STATE_RSSI_ENABLED:          UInt16 = 1 << 4
let HOST_STATE_FILTER_PRE:            UInt16 = 1 << 5
let HOST_STATE_FILTER_HIGH:           UInt16 = 1 << 6
let HOST_STATE_FILTER_LOW:            UInt16 = 1 << 7
let HOST_STATE_TX_ALLOWED:            UInt16 = 1 << 11
let HOST_STATE_ENABLE_STATUS_REPORTS: UInt16 = 1 << 12

// DeviceState-only flag bits (reported by firmware)
let DEVICE_STATE_SQUELCHED:           UInt16 = 1 << 10

// CTCSS tone table — SA818 module indices 1–38
private let CTCSS_TONES: [Float] = [
    67.0, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5,
    91.5, 94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8,
    118.8, 123.0, 127.3, 131.8, 136.5, 141.3, 146.2, 151.4,
    156.7, 162.2, 167.9, 173.8, 179.9, 186.2, 192.8, 203.5,
    210.7, 218.1, 225.7, 233.6, 241.8, 250.3
]

func ctcssIndex(for toneHz: Float) -> UInt8 {
    guard toneHz > 0 else { return 0 }
    if let idx = CTCSS_TONES.firstIndex(where: { abs($0 - toneHz) < 0.5 }) {
        return UInt8(idx + 1)
    }
    return 0
}

struct HelloFrame {
    let firmwareVersion: UInt16
    let radioModuleFound: Bool
    let windowSize: UInt32
    let rfModuleType: UInt8   // 0 = VHF, 1 = UHF
    let minFreq: Float        // MHz
    let maxFreq: Float        // MHz
    let features: UInt8
    let deviceState: DeviceStateFrame
}

struct DeviceStateFrame {
    let appliedSequence: UInt32
    let memoryId: Int32
    let flags: UInt16
    let bw: UInt8
    let freqTx: Float  // MHz
    let freqRx: Float  // MHz
    let mode: UInt8    // 0=TX 1=RX 2=STOPPED
    let rssi: UInt8
}

func kissEscape(_ data: Data) -> Data {
    var out = Data()
    for byte in data {
        switch byte {
        case 0xC0: out.append(contentsOf: [0xDB, 0xDC])
        case 0xDB: out.append(contentsOf: [0xDB, 0xDD])
        default:   out.append(byte)
        }
    }
    return out
}

func kissUnescape(_ data: Data) -> Data {
    var out = Data()
    var escaping = false
    for byte in data {
        if escaping {
            switch byte {
            case 0xDC: out.append(0xC0)
            case 0xDD: out.append(0xDB)
            default:   out.append(byte)
            }
            escaping = false
        } else if byte == 0xDB {
            escaping = true
        } else {
            out.append(byte)
        }
    }
    return out
}

func buildKv4pVendorFrame(command: UInt8, payload: Data) -> Data {
    let header  = Data([0x4B, 0x56, 0x34, 0x50, KV4P_PROTOCOL_VERSION, command])
    let escaped = kissEscape(header + payload)
    return Data([KISS_FEND, 0x06]) + escaped + Data([KISS_FEND])
}

// Builds using byte-append so there are no alignment requirements on any field.
// (storeBytes crashes in debug builds at unaligned offsets, e.g. Float at offset 11/15.)
func buildDesiredState(sequence: UInt32, freqTx: Float, freqRx: Float, squelch: UInt8,
                       flags: UInt16, bw: UInt8 = 0, ctcssTx: UInt8 = 0, ctcssRx: UInt8 = 0) -> Data {
    var data = Data()
    withUnsafeBytes(of: sequence.littleEndian)  { data.append(contentsOf: $0) }  // 0..3
    withUnsafeBytes(of: Int32(-1).littleEndian) { data.append(contentsOf: $0) }  // 4..7
    withUnsafeBytes(of: flags.littleEndian)     { data.append(contentsOf: $0) }  // 8..9
    data.append(bw)                                                               // 10  bw
    withUnsafeBytes(of: freqTx)                 { data.append(contentsOf: $0) }  // 11..14 freqTx
    withUnsafeBytes(of: freqRx)                 { data.append(contentsOf: $0) }  // 15..18 freqRx
    data.append(ctcssTx)                                                          // 19 ctcssTx
    data.append(squelch)                                                          // 20
    data.append(ctcssRx)                                                          // 21 ctcssRx
    return data  // 22 bytes total
}

func parseHello(_ data: Data) -> HelloFrame? {
    guard data.count >= 43 else { return nil }
    return data.withUnsafeBytes { ptr -> HelloFrame? in
        let ver    = ptr.loadUnaligned(fromByteOffset: 0,  as: UInt16.self).littleEndian
        let status = ptr.loadUnaligned(fromByteOffset: 2,  as: UInt8.self)
        let window = ptr.loadUnaligned(fromByteOffset: 3,  as: UInt32.self).littleEndian
        let rfType = ptr.loadUnaligned(fromByteOffset: 7,  as: UInt8.self)
        let minF   = ptr.loadUnaligned(fromByteOffset: 8,  as: Float.self)
        let maxF   = ptr.loadUnaligned(fromByteOffset: 12, as: Float.self)
        let feat   = ptr.loadUnaligned(fromByteOffset: 16, as: UInt8.self)
        guard let ds = parseDeviceStateAt(ptr, offset: 17) else { return nil }
        return HelloFrame(
            firmwareVersion: ver,
            radioModuleFound: status == 0x66,
            windowSize: window,
            rfModuleType: rfType,
            minFreq: minF,
            maxFreq: maxF,
            features: feat,
            deviceState: ds
        )
    }
}

func parseDeviceState(_ data: Data) -> DeviceStateFrame? {
    guard data.count >= 26 else { return nil }
    return data.withUnsafeBytes { parseDeviceStateAt($0, offset: 0) }
}

func parseDeviceStateAt(_ ptr: UnsafeRawBufferPointer, offset: Int) -> DeviceStateFrame? {
    guard ptr.count >= offset + 26 else { return nil }
    let seq   = ptr.loadUnaligned(fromByteOffset: offset + 0,  as: UInt32.self).littleEndian
    let memId = ptr.loadUnaligned(fromByteOffset: offset + 4,  as: Int32.self).littleEndian
    let flags = ptr.loadUnaligned(fromByteOffset: offset + 8,  as: UInt16.self).littleEndian
    let bw    = ptr.loadUnaligned(fromByteOffset: offset + 10, as: UInt8.self)
    let fTx   = ptr.loadUnaligned(fromByteOffset: offset + 11, as: Float.self)
    let fRx   = ptr.loadUnaligned(fromByteOffset: offset + 15, as: Float.self)
    let mode  = ptr.loadUnaligned(fromByteOffset: offset + 23, as: UInt8.self)
    let rssi  = ptr.loadUnaligned(fromByteOffset: offset + 25, as: UInt8.self)
    return DeviceStateFrame(
        appliedSequence: seq, memoryId: memId, flags: flags,
        bw: bw, freqTx: fTx, freqRx: fRx, mode: mode, rssi: rssi
    )
}

class KissParser {
    private var buffer = Data()
    private var inFrame = false

    func feed(_ data: Data) -> [(UInt8, Data)] {
        var frames: [(UInt8, Data)] = []
        for byte in data {
            if byte == KISS_FEND {
                if inFrame && !buffer.isEmpty {
                    if let frame = processFrame(buffer) { frames.append(frame) }
                }
                buffer.removeAll()
                inFrame = true
            } else if inFrame {
                buffer.append(byte)
            }
        }
        return frames
    }

    func reset() {
        buffer.removeAll()
        inFrame = false
    }

    private func processFrame(_ raw: Data) -> (UInt8, Data)? {
        guard !raw.isEmpty else { return nil }
        let cmdByte  = raw[0]
        let kissPort = cmdByte >> 4
        let kissCmd  = cmdByte & 0x0F
        guard kissPort == 0 else { return nil }
        return (kissCmd, kissUnescape(raw.dropFirst()))
    }
}
