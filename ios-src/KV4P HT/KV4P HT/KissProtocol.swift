import Foundation

// KISS framing constants
nonisolated let KISS_FEND:  UInt8 = 0xC0
nonisolated let KISS_FESC:  UInt8 = 0xDB
nonisolated let KISS_TFEND: UInt8 = 0xDC
nonisolated let KISS_TFESC: UInt8 = 0xDD

// KV4P protocol constants
nonisolated let KV4P_VENDOR_PREFIX:    [UInt8] = [0x4B, 0x56, 0x34, 0x50]
nonisolated let KV4P_PROTOCOL_VERSION: UInt8   = 0x01

// DesiredState flag bits
nonisolated let HOST_STATE_RADIO_CONFIG_VALID:    UInt16 = 1 << 0
nonisolated let HOST_STATE_PTT_REQUESTED:         UInt16 = 1 << 1
nonisolated let HOST_STATE_RX_AUDIO_OPEN:         UInt16 = 1 << 2
nonisolated let HOST_STATE_HIGH_POWER:            UInt16 = 1 << 3
nonisolated let HOST_STATE_RSSI_ENABLED:          UInt16 = 1 << 4
nonisolated let HOST_STATE_FILTER_PRE:            UInt16 = 1 << 5
nonisolated let HOST_STATE_FILTER_HIGH:           UInt16 = 1 << 6
nonisolated let HOST_STATE_FILTER_LOW:            UInt16 = 1 << 7
nonisolated let HOST_STATE_TX_ALLOWED:            UInt16 = 1 << 11
nonisolated let HOST_STATE_ENABLE_STATUS_REPORTS: UInt16 = 1 << 12

// DeviceState-only flag bits (reported by firmware)
nonisolated let DEVICE_STATE_PHYS_PTT_DOWN:       UInt16 = 1 << 8
nonisolated let DEVICE_STATE_TX_ACTIVE:           UInt16 = 1 << 9
nonisolated let DEVICE_STATE_SQUELCHED:           UInt16 = 1 << 10

// DRA818/SA818 bandwidth byte values (match firmware)
nonisolated let DRA818_25K:  UInt8 = 0x01
nonisolated let DRA818_12K5: UInt8 = 0x00

// Radio module status chars reported by firmware
nonisolated let RADIO_STATUS_FOUND:     UInt8 = 0x66  // 'f'
nonisolated let RADIO_STATUS_NOT_FOUND: UInt8 = 0x78  // 'x'

// CTCSS tone table — SA818 module indices 1–38
nonisolated let CTCSS_TONES: [Float] = [
    67.0, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5,
    91.5, 94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8,
    118.8, 123.0, 127.3, 131.8, 136.5, 141.3, 146.2, 151.4,
    156.7, 162.2, 167.9, 173.8, 179.9, 186.2, 192.8, 203.5,
    210.7, 218.1, 225.7, 233.6, 241.8, 250.3
]

nonisolated func ctcssIndex(for toneHz: Float) -> UInt8 {
    guard toneHz > 0 else { return 0 }
    if let idx = CTCSS_TONES.firstIndex(where: { abs($0 - toneHz) < 0.5 }) {
        return UInt8(idx + 1)
    }
    return 0
}

nonisolated func ctcssToneHz(for index: UInt8) -> Float? {
    guard index >= 1, Int(index) <= CTCSS_TONES.count else { return nil }
    return CTCSS_TONES[Int(index) - 1]
}

nonisolated struct HelloFrame {
    let firmwareVersion: UInt16
    let radioModuleFound: Bool
    let windowSize: UInt32
    let rfModuleType: UInt8   // 0 = VHF, 1 = UHF
    let minFreq: Float        // MHz
    let maxFreq: Float        // MHz
    let features: UInt8
    let deviceState: DeviceStateFrame
}

nonisolated struct DeviceStateFrame {
    let appliedSequence: UInt32
    let memoryId: Int32
    let flags: UInt16
    let bw: UInt8
    let freqTx: Float  // MHz
    let freqRx: Float  // MHz
    let ctcssTx: UInt8
    let squelch: UInt8
    let ctcssRx: UInt8
    let radioModuleStatus: UInt8  // 'f' found, 'x' not found, 'u' unknown
    let mode: UInt8    // 0=TX 1=RX 2=STOPPED
    let lastError: UInt8
    let rssi: UInt8

    var hasRadioConfig: Bool { (flags & HOST_STATE_RADIO_CONFIG_VALID) != 0 }
}

// Host-side desired radio state, wire-compatible with Android's
// Protocol.HostDesiredState (22 bytes, little endian).
// nonisolated: built and compared on bleQueue, not the main actor.
nonisolated struct HostDesiredState: Equatable {
    var sequence: UInt32
    var memoryId: Int32
    var flags: UInt16
    var bw: UInt8
    var freqTx: Float  // MHz
    var freqRx: Float  // MHz
    var ctcssTx: UInt8
    var squelch: UInt8
    var ctcssRx: UInt8

    // Byte-append so there are no alignment requirements on any field.
    // (storeBytes crashes in debug builds at unaligned offsets, e.g. Float at offset 11/15.)
    func encoded() -> Data {
        var data = Data()
        withUnsafeBytes(of: sequence.littleEndian) { data.append(contentsOf: $0) }  // 0..3
        withUnsafeBytes(of: memoryId.littleEndian) { data.append(contentsOf: $0) }  // 4..7
        withUnsafeBytes(of: flags.littleEndian)    { data.append(contentsOf: $0) }  // 8..9
        data.append(bw)                                                              // 10
        withUnsafeBytes(of: freqTx)                { data.append(contentsOf: $0) }  // 11..14
        withUnsafeBytes(of: freqRx)                { data.append(contentsOf: $0) }  // 15..18
        data.append(ctcssTx)                                                         // 19
        data.append(squelch)                                                         // 20
        data.append(ctcssRx)                                                         // 21
        return data  // 22 bytes total
    }
}

nonisolated func kissEscape(_ data: Data) -> Data {
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

nonisolated func kissUnescape(_ data: Data) -> Data {
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

nonisolated func buildKv4pVendorFrame(command: UInt8, payload: Data) -> Data {
    let header  = Data([0x4B, 0x56, 0x34, 0x50, KV4P_PROTOCOL_VERSION, command])
    let escaped = kissEscape(header + payload)
    return Data([KISS_FEND, 0x06]) + escaped + Data([KISS_FEND])
}

// KISS DATA frame (port 0, cmd 0): raw AX.25 bytes for the firmware's AFSK
// modem to transmit. The firmware self-keys PTT (TX_ALLOWED flag required).
nonisolated func buildKissDataFrame(_ ax25: Data) -> Data {
    Data([KISS_FEND, 0x00]) + kissEscape(ax25) + Data([KISS_FEND])
}

nonisolated func parseWindowUpdate(_ data: Data) -> UInt32? {
    guard data.count >= 4 else { return nil }
    return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian }
}

nonisolated func parseHello(_ data: Data) -> HelloFrame? {
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

nonisolated func parseDeviceState(_ data: Data) -> DeviceStateFrame? {
    guard data.count >= 26 else { return nil }
    return data.withUnsafeBytes { parseDeviceStateAt($0, offset: 0) }
}

nonisolated func parseDeviceStateAt(_ ptr: UnsafeRawBufferPointer, offset: Int) -> DeviceStateFrame? {
    guard ptr.count >= offset + 26 else { return nil }
    let seq   = ptr.loadUnaligned(fromByteOffset: offset + 0,  as: UInt32.self).littleEndian
    let memId = ptr.loadUnaligned(fromByteOffset: offset + 4,  as: Int32.self).littleEndian
    let flags = ptr.loadUnaligned(fromByteOffset: offset + 8,  as: UInt16.self).littleEndian
    let bw    = ptr.loadUnaligned(fromByteOffset: offset + 10, as: UInt8.self)
    let fTx   = ptr.loadUnaligned(fromByteOffset: offset + 11, as: Float.self)
    let fRx   = ptr.loadUnaligned(fromByteOffset: offset + 15, as: Float.self)
    let cTx   = ptr.loadUnaligned(fromByteOffset: offset + 19, as: UInt8.self)
    let sq    = ptr.loadUnaligned(fromByteOffset: offset + 20, as: UInt8.self)
    let cRx   = ptr.loadUnaligned(fromByteOffset: offset + 21, as: UInt8.self)
    let stat  = ptr.loadUnaligned(fromByteOffset: offset + 22, as: UInt8.self)
    let mode  = ptr.loadUnaligned(fromByteOffset: offset + 23, as: UInt8.self)
    let err   = ptr.loadUnaligned(fromByteOffset: offset + 24, as: UInt8.self)
    let rssi  = ptr.loadUnaligned(fromByteOffset: offset + 25, as: UInt8.self)
    return DeviceStateFrame(
        appliedSequence: seq, memoryId: memId, flags: flags,
        bw: bw, freqTx: fTx, freqRx: fRx,
        ctcssTx: cTx, squelch: sq, ctcssRx: cRx,
        radioModuleStatus: stat, mode: mode, lastError: err, rssi: rssi
    )
}

// Transport-level send window mirroring Android's Protocol.Sender flow
// control: the window counts encoded wire bytes the firmware has granted.
// Frames that don't fit are queued (in order) until the firmware enlarges
// the window via COMMAND_WINDOW_UPDATE (0x09). Not thread-safe — confine
// to a single queue (BLEManager uses bleQueue).
nonisolated final class FlowControlGate {
    static let defaultWindow = 1024

    private(set) var window: Int = FlowControlGate.defaultWindow
    private(set) var pending: [Data] = []
    var onSend: ((Data) -> Void)?

    func setWindow(_ size: Int) {
        window = size
        drain()
    }

    func enlargeWindow(by size: Int) {
        window += size
        drain()
    }

    func submit(_ frame: Data) {
        pending.append(frame)
        drain()
    }

    func reset() {
        window = Self.defaultWindow
        pending.removeAll()
    }

    private func drain() {
        while let next = pending.first, next.count <= window {
            pending.removeFirst()
            window -= next.count
            onSend?(next)
        }
    }
}

nonisolated class KissParser {
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
