import Foundation
@preconcurrency import CoreBluetooth

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
    // Called on bleQueue with decoded AX.25 frame bytes (no FCS).
    @ObservationIgnored var onAx25Frame: ((Data) -> Void)?
    // Called on bleQueue after HELLO seeding + transport ready, so the app can
    // re-apply user-level desired state (e.g. squelch) on each (re)connect.
    @ObservationIgnored var onTransportReady: (() -> Void)?

    private let bleQueue = DispatchQueue(label: "kv4p-ht.ble", qos: .userInitiated)
    private let audio = AudioManager()
    // Radio state lives in the controller; this class is transport only.
    @ObservationIgnored private let radio: RadioModuleController
    // Confined to bleQueue.
    @ObservationIgnored private let gate = FlowControlGate()

    func setAudioSampleHook(_ handler: (([Float], Int) -> Void)?) {
        audio.onDecodedSamples = handler
    }
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var parser = KissParser()
    @ObservationIgnored private var pendingLogEntries: [String] = []
    @ObservationIgnored private var logFlushScheduled = false
    @ObservationIgnored private var transmitting = false
    @ObservationIgnored private var userInitiatedDisconnect = false

    init(radio: RadioModuleController) {
        self.radio = radio
        super.init()
        gate.onSend = { [weak self] frame in self?.writeRaw(frame) }
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
        userInitiatedDisconnect = false
        peripheral = device.peripheral
        peripheral?.delegate = self
        central.connect(device.peripheral)
        log("Connecting to \(device.name)...")
    }

    func disconnect() {
        userInitiatedDisconnect = true
        if let p = peripheral { central.cancelPeripheralConnection(p) }
    }

    func recoverAudioIfNeeded() {
        Task { await audio.recoverIfNeeded() }
    }

    // Transport hook for RadioModuleController — the controller decides what
    // to send and when; this only encodes, gates, and writes. Also where the
    // audio handoff happens: mic capture follows the PTT_REQUESTED flag of
    // frames actually emitted.
    private func sendDesiredState(_ state: HostDesiredState) {
        bleQueue.async { [weak self] in
            guard let self else { return }
            let frame = buildKv4pVendorFrame(command: 0x0D, payload: state.encoded())
            self.gate.submit(frame)
            let ptt = (state.flags & HOST_STATE_PTT_REQUESTED) != 0
            if ptt != self.transmitting {
                if ptt {
                    self.startTransmitting()
                } else {
                    self.stopTransmitting()
                }
            }
            self.log(String(format: "→ DesiredState seq=%d tx=%.4f rx=%.4f sq=%d flags=0x%04X bw=%d tone=%d",
                            state.sequence, state.freqTx, state.freqRx, state.squelch,
                            state.flags, state.bw, state.ctcssTx))
        }
    }

    // Sends raw AX.25 bytes (no FCS) for the firmware's AFSK modem to
    // transmit. Firmware keys/unkeys PTT itself; TX_ALLOWED is kept set in
    // desired state after HELLO.
    func sendAx25Frame(_ ax25: Data) {
        let frame = buildKissDataFrame(ax25)
        bleQueue.async { [weak self] in
            self?.gate.submit(frame)
        }
        log("→ AX.25 \(ax25.count)B")
    }

    @ObservationIgnored private var txAudioFrameCount = 0

    private func sendTxAudio(_ adpcmFrame: Data) {
        let frame = buildKv4pVendorFrame(command: 0x0C, payload: adpcmFrame)
        gate.submit(frame)
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
        let shouldReconnect = !userInitiatedDisconnect
        userInitiatedDisconnect = false
        onMain {
            self.bleState = shouldReconnect ? .connecting : .idle
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
        radio.detachTransport()
        gate.reset()
        Task { [weak self] in
            guard let self else { return }
            // stop() must finish before a reconnect's audio.start() —
            // serialize through the actor, then queue the reconnect.
            await self.audio.stop()
            if shouldReconnect {
                // CBCentralManager methods are thread-safe; callbacks still
                // arrive on bleQueue. Pending connects never time out; with
                // bluetooth-central background mode iOS wakes us when the
                // radio reappears.
                self.peripheral = peripheral
                peripheral.delegate = self
                self.central.connect(peripheral)
                self.log("Reconnecting when radio reappears...")
            }
        }
        log(error == nil ? "Disconnected"
                         : "Disconnected unexpectedly: \(error!.localizedDescription)")
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
            case 0x00:
                if let f = AX25Frame(decoding: payload),
                   let info = String(data: f.payload, encoding: .ascii)
                            ?? String(data: f.payload, encoding: .isoLatin1) {
                    log("← AX.25 \(f.source.display)>\(f.destination.display): \(info.prefix(64))")
                } else {
                    log("← AX.25 \(payload.count)B (undecodable)")
                }
                onAx25Frame?(payload)
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
                gate.setWindow(Int(h.windowSize))
                // HELLO = FirmwareVersion + initial DeviceState. Seed both into
                // the controller and surface the applied state to the UI before
                // any app-driven changes go out.
                radio.attachTransport { [weak self] state in self?.sendDesiredState(state) }
                radio.seedFirmwareInfo(h)
                radio.seedFromDeviceState(h.deviceState)
                onMain {
                    self.hello = h
                    self.deviceState = h.deviceState
                    self.bleState = .ready
                }
                log(String(format: "← HELLO fw=%d %@ %.0f–%.0f MHz win=%d",
                    h.firmwareVersion,
                    h.rfModuleType == 0 ? "VHF" : "UHF",
                    h.minFreq, h.maxFreq, h.windowSize))
                Task {
                    await audio.start()
                    let playing = await audio.isPlaying
                    self.onMain { self.audioPlaying = playing }
                    self.log(playing ? "Audio engine started" : "Audio engine failed to start")
                }
                // App-required desired-state changes only; the controller diffs
                // against the seeded baseline and emits a single update without
                // overwriting unrelated firmware config.
                radio.beginUpdate()
                radio.markTransportReady()
                radio.setTxAllowed(true)
                radio.openAudio()  // ESP32 won't stream audio until RX_AUDIO_OPEN is set
                radio.endUpdate()
                onTransportReady?()
            }
        case 0x0C:
            audioFrameCount += 1
            let frameData = Data(body)
            audio.feedAdpcmFrame(frameData)
            // Jitter-buffer depth is noisy; uncomment to debug audio timing.
            // if audioFrameCount % 64 == 0 {
            //     log(String(format: "  jitter-buf: %.0f ms", audio.fillMs))
            // }
        case 0x09:
            if let size = parseWindowUpdate(Data(body)) {
                gate.enlargeWindow(by: Int(size))
            }
        case 0x0B:
            if let ds = parseDeviceState(Data(body)) {
                radio.updateDeviceState(ds)
                onMain { self.deviceState = ds }
            }
        case 0x01, 0x02, 0x03:
            // Drop the firmware's periodic loop-frequency spam; keep other debug.
            if let s = String(bytes: body, encoding: .utf8),
               !s.contains("measureLoopFrequency") { log("← DBG: \(s)") }
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
        print("[BLE] \(entry)")
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
