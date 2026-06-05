import Foundation
import CoreBluetooth

private let BLE_KISS_SERVICE_UUID = CBUUID(string: "00000001-ba2a-46c9-ae49-01b0961f68bb")
private let BLE_KISS_TX_CHAR_UUID = CBUUID(string: "00000003-ba2a-46c9-ae49-01b0961f68bb")
private let BLE_KISS_RX_CHAR_UUID = CBUUID(string: "00000002-ba2a-46c9-ae49-01b0961f68bb")

enum BLEState {
    case idle, scanning, connecting, connected, ready
}

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    var rssi: Int
}

@Observable
class BLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var bleState: BLEState = .idle
    var discoveredDevices: [DiscoveredDevice] = []
    var hello: HelloFrame?
    var deviceState: DeviceStateFrame?
    @ObservationIgnored var audioFrameCount: Int = 0
    var logEntries: [String] = []
    var bleUnavailable = false
    var audioPlaying = false
    var audioAvailable = false

    private let bleQueue = DispatchQueue(label: "kv4p-ht.ble", qos: .userInitiated)
    private let audio = AudioManager()

    func setAudioSampleHook(_ handler: (([Float], Int) -> Void)?) {
        audio.onDecodedSamples = handler
    }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var parser = KissParser()
    private var seq: UInt32 = UInt32(Date().timeIntervalSince1970)
    @ObservationIgnored private var pendingLogEntries: [String] = []
    @ObservationIgnored private var logFlushScheduled = false
    @ObservationIgnored private var transmitting = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: bleQueue)
        audioAvailable = audio.isAvailable  // nonisolated — no await needed
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        onMain {
            self.discoveredDevices = []
            self.bleState = .scanning
        }
        central.scanForPeripherals(withServices: [BLE_KISS_SERVICE_UUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log("Scanning for KV4P-HT...")
    }

    func stopScan() {
        central.stopScan()
        onMain { if self.bleState == .scanning { self.bleState = .idle } }
    }

    func connect(_ device: DiscoveredDevice) {
        stopScan()
        onMain { self.bleState = .connecting }
        peripheral = device.peripheral
        peripheral?.delegate = self
        central.connect(device.peripheral)
        log("Connecting to \(device.name)...")
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    func sendDesiredState(freqTx: Float, freqRx: Float, squelch: UInt8,
                          ptt: Bool = false, txAllowed: Bool = false, highPower: Bool = false,
                          bw: UInt8 = 0, ctcssTx: UInt8 = 0, ctcssRx: UInt8 = 0,
                          filterPre: Bool = false, filterHigh: Bool = false, filterLow: Bool = false) {
        var flags: UInt16 = HOST_STATE_RADIO_CONFIG_VALID
                          | HOST_STATE_RSSI_ENABLED
                          | HOST_STATE_RX_AUDIO_OPEN
                          | HOST_STATE_ENABLE_STATUS_REPORTS
        if highPower  { flags |= HOST_STATE_HIGH_POWER }
        if ptt        { flags |= HOST_STATE_PTT_REQUESTED }
        if txAllowed  { flags |= HOST_STATE_TX_ALLOWED }
        if filterPre  { flags |= HOST_STATE_FILTER_PRE }
        if filterHigh { flags |= HOST_STATE_FILTER_HIGH }
        if filterLow  { flags |= HOST_STATE_FILTER_LOW }
        seq += 1
        let payload = buildDesiredState(sequence: seq, freqTx: freqTx, freqRx: freqRx,
                                        squelch: squelch, flags: flags,
                                        bw: bw, ctcssTx: ctcssTx, ctcssRx: ctcssRx)
        let frame   = buildKv4pVendorFrame(command: 0x0D, payload: payload)
        writeRaw(frame)
        print("[BLE] sendDesiredState ptt=\(ptt) transmitting=\(transmitting)")
        if ptt != transmitting {
            if ptt {
                startTransmitting()
            } else {
                stopTransmitting()
            }
        }
        log(String(format: "→ DesiredState tx=%.4f rx=%.4f sq=%d ptt=%d hp=%d bw=%d tone=%d",
                   freqTx, freqRx, squelch, ptt ? 1 : 0, highPower ? 1 : 0, bw, ctcssTx))
    }

    @ObservationIgnored private var txAudioFrameCount = 0

    private func sendTxAudio(_ adpcmFrame: Data) {
        let frame = buildKv4pVendorFrame(command: 0x0C, payload: adpcmFrame)
        writeRaw(frame)
        txAudioFrameCount += 1
        if txAudioFrameCount % 25 == 1 {
            print("[BLE] TX audio #\(txAudioFrameCount) payload=\(adpcmFrame.count)B wire=\(frame.count)B periph=\(peripheral != nil) rxChar=\(rxChar != nil)")
        }
    }

    private func startTransmitting() {
        guard !transmitting else { return }
        transmitting = true
        txAudioFrameCount = 0
        Task { [weak self] in
            guard let self else { return }
            await self.audio.stopMicCapture()
            await self.audio.startMicCapture { [weak self] adpcmFrame in
                guard let self else { return }
                self.bleQueue.async {
                    self.sendTxAudio(adpcmFrame)
                }
            }
            self.log("TX: mic capture started")
        }
    }

    private func stopTransmitting() {
        guard transmitting else { print("[BLE] stopTransmitting: already stopped"); return }
        transmitting = false
        print("[BLE] stopTransmitting: firing stopMicCapture task")
        Task { [weak self] in
            guard let self else { print("[BLE] stopTransmitting: self deallocated"); return }
            print("[BLE] stopTransmitting: awaiting stopMicCapture")
            await self.audio.stopMicCapture()
            print("[BLE] stopTransmitting: stopMicCapture done")
            self.log("TX: mic capture stopped")
        }
    }

    // MARK: – CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onMain { self.bleUnavailable = false }
            log("BLE ready")
        case .poweredOff:
            onMain { self.bleUnavailable = true; self.bleState = .idle }
            log("BLE powered off")
        case .unauthorized:
            onMain { self.bleUnavailable = true }
            log("BLE unauthorized — check permissions")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "KV4P-HT"
        let rssi = RSSI.intValue
        onMain {
            if let idx = self.discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
                self.discoveredDevices[idx].rssi = rssi
            } else {
                self.discoveredDevices.append(DiscoveredDevice(
                    id: peripheral.identifier, peripheral: peripheral, name: name, rssi: rssi))
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onMain { self.bleState = .connected }
        log("Connected — discovering services")
        peripheral.discoverServices([BLE_KISS_SERVICE_UUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        onMain { self.bleState = .idle }
        log("Connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        onMain {
            self.bleState = .idle
            self.hello = nil
            self.deviceState = nil
            self.audioPlaying = false
        }
        self.peripheral = nil
        txChar = nil
        rxChar = nil
        audioFrameCount = 0
        transmitting = false
        parser.reset()
        Task { await audio.stop() }
        log("Disconnected")
    }

    // MARK: – CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == BLE_KISS_SERVICE_UUID {
            peripheral.discoverCharacteristics([BLE_KISS_TX_CHAR_UUID, BLE_KISS_RX_CHAR_UUID], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for char in chars {
            switch char.uuid {
            case BLE_KISS_TX_CHAR_UUID:
                txChar = char
                peripheral.setNotifyValue(true, for: char)
                log("TX char found — subscribing")
            case BLE_KISS_RX_CHAR_UUID:
                rxChar = char
                log("RX char found")
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if characteristic.uuid == BLE_KISS_TX_CHAR_UUID && characteristic.isNotifying {
            log("TX notifications active — waiting for HELLO (~1s)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value else { return }
        let frames = parser.feed(data)
        for (cmd, payload) in frames {
            switch cmd {
            case 0x06: handleVendorFrame(payload)
            case 0x00: log("← AX.25 \(payload.count)B")
            default:   break
            }
        }
    }

    // MARK: – Private

    private func handleVendorFrame(_ payload: Data) {
        guard payload.count >= 6,
              payload.prefix(4) == Data(KV4P_VENDOR_PREFIX),
              payload[4] == KV4P_PROTOCOL_VERSION
        else { return }

        let command = payload[5]
        let body    = payload.dropFirst(6)

        switch command {
        case 0x06:
            if let h = parseHello(Data(body)) {
                onMain {
                    self.hello = h
                    self.deviceState = h.deviceState
                    self.bleState = .ready
                }
                log(String(format: "← HELLO fw=%d %@ %.0f–%.0f MHz",
                    h.firmwareVersion,
                    h.rfModuleType == 0 ? "VHF" : "UHF",
                    h.minFreq, h.maxFreq))
                Task {
                    await audio.start()
                    let playing = await audio.isPlaying
                    self.onMain { self.audioPlaying = playing }
                    self.log(playing ? "Audio engine started" : "Audio engine failed to start")
                }
                // ESP32 won't stream audio until it receives DesiredState with RX_AUDIO_OPEN.
                let rxFreq = h.deviceState.freqRx > 100 ? h.deviceState.freqRx : 146.520
                sendDesiredState(freqTx: rxFreq, freqRx: rxFreq, squelch: 0)
                log(String(format: "→ auto DesiredState %.4f MHz (RX audio open)", rxFreq))
            }
        case 0x0C:
            audioFrameCount += 1
            let frameData = Data(body)
            audio.feedAdpcmFrame(frameData)
            if audioFrameCount % 64 == 0 {
                log(String(format: "  jitter-buf: %.0f ms", audio.fillMs))
            }
        case 0x09:
            break
        case 0x0B:
            if let ds = parseDeviceState(Data(body)) {
                onMain { self.deviceState = ds }
            }
        case 0x01, 0x02, 0x03:
            if let s = String(bytes: body, encoding: .utf8) { log("← DBG: \(s)") }
        default:
            break
        }
    }

    private func writeRaw(_ data: Data) {
        guard let p = peripheral, let char = rxChar else { return }
        let mtu    = p.maximumWriteValueLength(for: .withoutResponse)
        var offset = 0
        while offset < data.count {
            let end   = min(offset + mtu, data.count)
            p.writeValue(Data(data[offset..<end]), for: char, type: .withoutResponse)
            offset = end
        }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() }
        else { DispatchQueue.main.async(execute: work) }
    }

    private func log(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let entry = "[\(ts)] \(msg)"
        pendingLogEntries.append(entry)
        guard !logFlushScheduled else { return }
        logFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let batch = self.pendingLogEntries
            self.pendingLogEntries = []
            self.logFlushScheduled = false
            self.logEntries.insert(contentsOf: batch.reversed(), at: 0)
            if self.logEntries.count > 100 {
                self.logEntries.removeSubrange(100...)
            }
        }
    }
}
