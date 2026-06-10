import Foundation

/// Owns the iOS-side desired/applied radio state (port of Android's
/// `RadioModuleController`).
///
/// The transport (BLEManager) only knows how to write frames; this class
/// decides what the next desired-state snapshot should contain and when one
/// must be emitted. UI writes go through the problem-oriented setters, which
/// mutate desired state and send a `HostDesiredState` frame only when
/// something actually changed. Firmware `DEVICE_STATE` frames feed
/// `updateDeviceState(_:)`, which tracks applied-state sync and retries the
/// last sent desired state (up to `maxDesiredStateRetries`) on mismatch.
///
/// Thread-safe: setters may be called from the main thread while transport
/// callbacks arrive on bleQueue. The injected send callback is invoked while
/// the internal lock is held, so it must not call back into this class
/// synchronously (BLEManager dispatches onto bleQueue).
nonisolated final class RadioModuleController: @unchecked Sendable {
    static let maxDesiredStateRetries = 3

    private static let desiredDeviceFlagsMask: UInt16 =
        HOST_STATE_RADIO_CONFIG_VALID
        | HOST_STATE_PTT_REQUESTED
        | HOST_STATE_RX_AUDIO_OPEN
        | HOST_STATE_HIGH_POWER
        | HOST_STATE_RSSI_ENABLED
        | HOST_STATE_FILTER_PRE
        | HOST_STATE_FILTER_HIGH
        | HOST_STATE_FILTER_LOW
        | HOST_STATE_TX_ALLOWED
        | HOST_STATE_ENABLE_STATUS_REPORTS

    private static let defaultDesiredFlags: UInt16 =
        HOST_STATE_HIGH_POWER | HOST_STATE_RSSI_ENABLED | HOST_STATE_ENABLE_STATUS_REPORTS

    private static let initialDesiredState = HostDesiredState(
        sequence: 0, memoryId: -1, flags: defaultDesiredFlags, bw: DRA818_25K,
        freqTx: 0, freqRx: 0, ctcssTx: 0, squelch: 0, ctcssRx: 0)

    private let lock = NSRecursiveLock()

    private var send: ((HostDesiredState) -> Void)?
    private var firmwareInfo: HelloFrame?
    private var _desiredState = RadioModuleController.initialDesiredState
    private var updateDepth = 0
    private var lastDesiredStateSent: HostDesiredState?
    private var lastDeviceState: DeviceStateFrame?
    private var lastPhysPttDown = false
    private var _appliedStateInSync = false
    private var transportReady = false
    private var desiredStateRetries = 0

    // MARK: - Transport lifecycle

    func attachTransport(_ send: @escaping (HostDesiredState) -> Void) {
        withLock {
            self.send = send
            transportReady = false
            lastDesiredStateSent = _desiredState
            desiredStateRetries = 0
        }
    }

    func markTransportReady() {
        withLock {
            transportReady = true
            sendDesiredStateIfChanged()
        }
    }

    func detachTransport() {
        withLock {
            send = nil
            transportReady = false
            lastDesiredStateSent = nil
            lastDeviceState = nil
            firmwareInfo = nil
            _appliedStateInSync = false
            desiredStateRetries = 0
        }
    }

    // MARK: - Seeding from HELLO

    func seedFirmwareInfo(_ hello: HelloFrame) {
        withLock { firmwareInfo = hello }
    }

    func seedFromDeviceState(_ state: DeviceStateFrame) {
        withLock {
            lastDeviceState = state
            lastPhysPttDown = isPhysPttDown
            _desiredState = desiredBaseline(from: state)
            // Strip STATUS_REPORTS from the no-op baseline so the post-HELLO
            // flush always emits at least one frame that (re-)enables reports.
            lastDesiredStateSent = withFlags(_desiredState, _desiredState.flags & ~HOST_STATE_ENABLE_STATUS_REPORTS)
            _appliedStateInSync = isDeviceStateInSync(state, with: lastDesiredStateSent)
            desiredStateRetries = 0
        }
    }

    // MARK: - Batched updates

    func beginUpdate() {
        withLock { updateDepth += 1 }
    }

    func endUpdate() {
        withLock {
            guard updateDepth > 0 else { return }
            updateDepth -= 1
            if updateDepth == 0 {
                sendDesiredStateIfChanged()
            }
        }
    }

    // MARK: - Desired-state setters (UI writes)

    func pttDown() { setDesiredFlag(HOST_STATE_PTT_REQUESTED, true) }
    func pttUp()   { setDesiredFlag(HOST_STATE_PTT_REQUESTED, false) }

    func setBandwidth(_ bandwidth: UInt8) {
        updateRadioConfig { $0.bw = bandwidth }
    }

    func setTxFrequency(_ txFrequency: Float) {
        updateRadioConfig { $0.freqTx = txFrequency }
    }

    func setRxFrequency(_ rxFrequency: Float) {
        updateRadioConfig { $0.freqRx = rxFrequency }
    }

    func setMemoryId(_ memoryId: Int32) {
        updateRadioConfig { $0.memoryId = memoryId }
    }

    func setTxTone(_ txTone: UInt8) {
        updateRadioConfig { $0.ctcssTx = txTone }
    }

    func setRxTone(_ rxTone: UInt8) {
        updateRadioConfig { $0.ctcssRx = rxTone }
    }

    func setSquelch(_ squelch: UInt8) {
        updateRadioConfig { $0.squelch = squelch }
    }

    func setFilters(emphasis: Bool, highpass: Bool, lowpass: Bool) {
        withLock {
            var flags = _desiredState.flags & ~(HOST_STATE_FILTER_PRE | HOST_STATE_FILTER_HIGH | HOST_STATE_FILTER_LOW)
            if emphasis { flags |= HOST_STATE_FILTER_PRE }
            if highpass { flags |= HOST_STATE_FILTER_HIGH }
            if lowpass  { flags |= HOST_STATE_FILTER_LOW }
            updateDesiredState { $0.flags = flags }
        }
    }

    func setHighPower(_ isHighPower: Bool) {
        setDesiredFlag(HOST_STATE_HIGH_POWER, isHighPower)
    }

    func setRssiEnabled(_ on: Bool) {
        setDesiredFlag(HOST_STATE_RSSI_ENABLED, on)
    }

    func setTxAllowed(_ allowed: Bool) {
        setDesiredFlag(HOST_STATE_TX_ALLOWED, allowed)
    }

    func openAudio() {
        withLock {
            updateDesiredState { $0.flags |= HOST_STATE_RX_AUDIO_OPEN | HOST_STATE_ENABLE_STATUS_REPORTS }
        }
    }

    func closeAudio() {
        clearDesiredFlags(HOST_STATE_RX_AUDIO_OPEN | HOST_STATE_PTT_REQUESTED | HOST_STATE_ENABLE_STATUS_REPORTS)
    }

    func stop() {
        clearDesiredFlags(HOST_STATE_RX_AUDIO_OPEN | HOST_STATE_PTT_REQUESTED | HOST_STATE_ENABLE_STATUS_REPORTS)
    }

    func flushDesiredState() {
        withLock { sendDesiredStateIfChanged() }
    }

    // MARK: - Firmware device state (UI reads)

    func updateDeviceState(_ state: DeviceStateFrame) {
        withLock {
            lastPhysPttDown = isPhysPttDown
            lastDeviceState = state
            _appliedStateInSync = isDeviceStateInSync(state, with: lastDesiredStateSent)
            if _appliedStateInSync {
                desiredStateRetries = 0
            } else {
                retryDesiredStateIfNeeded()
            }
        }
    }

    var desiredState: HostDesiredState {
        withLock { _desiredState }
    }

    var deviceState: DeviceStateFrame? {
        withLock { lastDeviceState }
    }

    var isAppliedStateInSync: Bool {
        withLock { _appliedStateInSync }
    }

    var isHighPowerEnabled: Bool { hasDesiredFlag(HOST_STATE_HIGH_POWER) }
    var isTxAllowed: Bool { hasDesiredFlag(HOST_STATE_TX_ALLOWED) }
    var desiredSquelch: UInt8 { withLock { _desiredState.squelch } }

    var isPhysPttDown: Bool { hasDeviceFlag(DEVICE_STATE_PHYS_PTT_DOWN) }
    var isSquelched: Bool { hasDeviceFlag(DEVICE_STATE_SQUELCHED) }

    var didPhysPttChange: Bool {
        withLock { lastPhysPttDown != isPhysPttDown }
    }

    // MARK: - Firmware metadata (from HELLO)

    var firmwareVersion: Int {
        withLock { firmwareInfo.map { Int($0.firmwareVersion) } ?? -1 }
    }

    var minRadioFreq: Float {
        withLock { firmwareInfo?.minFreq ?? 0.0 }
    }

    var maxRadioFreq: Float {
        withLock { firmwareInfo?.maxFreq ?? 999.0 }
    }

    var hasHighLowPowerSwitch: Bool {
        withLock { firmwareInfo.map { ($0.features & 0x01) != 0 } ?? false }
    }

    var hasPhysPttButton: Bool {
        withLock { firmwareInfo.map { ($0.features & 0x02) != 0 } ?? false }
    }

    // MARK: - Private

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func withFlags(_ state: HostDesiredState, _ flags: UInt16) -> HostDesiredState {
        var next = state
        next.flags = flags
        return next
    }

    private func desiredBaseline(from state: DeviceStateFrame) -> HostDesiredState {
        guard state.hasRadioConfig else {
            var baseline = Self.initialDesiredState
            baseline.sequence = state.appliedSequence
            return baseline
        }
        return HostDesiredState(
            sequence: state.appliedSequence,
            memoryId: state.memoryId,
            flags: (state.flags & Self.desiredDeviceFlagsMask & ~(HOST_STATE_PTT_REQUESTED | HOST_STATE_RX_AUDIO_OPEN))
                | HOST_STATE_ENABLE_STATUS_REPORTS,
            bw: state.bw,
            freqTx: state.freqTx,
            freqRx: state.freqRx,
            ctcssTx: state.ctcssTx,
            squelch: state.squelch,
            ctcssRx: state.ctcssRx)
    }

    private func isDeviceStateInSync(_ deviceState: DeviceStateFrame?, with desiredState: HostDesiredState?) -> Bool {
        guard let deviceState, let desiredState, deviceState.lastError == 0 else { return false }
        guard deviceState.appliedSequence == desiredState.sequence else { return false }
        guard (deviceState.flags & Self.desiredDeviceFlagsMask) == (desiredState.flags & Self.desiredDeviceFlagsMask) else {
            return false
        }
        guard (desiredState.flags & HOST_STATE_RADIO_CONFIG_VALID) != 0 else { return true }
        return deviceState.bw == desiredState.bw
            && deviceState.memoryId == desiredState.memoryId
            && deviceState.freqTx == desiredState.freqTx
            && deviceState.freqRx == desiredState.freqRx
            && deviceState.ctcssTx == desiredState.ctcssTx
            && deviceState.squelch == desiredState.squelch
            && deviceState.ctcssRx == desiredState.ctcssRx
    }

    private func updateRadioConfig(_ change: (inout HostDesiredState) -> Void) {
        withLock {
            updateDesiredState { state in
                let before = state
                change(&state)
                if state != before {
                    state.flags |= HOST_STATE_RADIO_CONFIG_VALID
                }
            }
        }
    }

    private func setDesiredFlag(_ flag: UInt16, _ enabled: Bool) {
        withLock {
            updateDesiredState { state in
                if enabled { state.flags |= flag } else { state.flags &= ~flag }
            }
        }
    }

    private func clearDesiredFlags(_ flags: UInt16) {
        withLock {
            updateDesiredState { $0.flags &= ~flags }
        }
    }

    private func updateDesiredState(_ change: (inout HostDesiredState) -> Void) {
        var next = _desiredState
        change(&next)
        if next != _desiredState {
            _desiredState = next
            sendDesiredStateIfChanged()
        }
    }

    private func hasDesiredFlag(_ flag: UInt16) -> Bool {
        withLock { (_desiredState.flags & flag) != 0 }
    }

    private func hasDeviceFlag(_ flag: UInt16) -> Bool {
        withLock { lastDeviceState.map { ($0.flags & flag) != 0 } ?? false }
    }

    private func sendDesiredStateIfChanged() {
        guard updateDepth == 0, let send, transportReady, _desiredState != lastDesiredStateSent else { return }
        _desiredState.sequence &+= 1
        lastDesiredStateSent = _desiredState
        desiredStateRetries = 0
        _appliedStateInSync = false
        send(_desiredState)
    }

    private func retryDesiredStateIfNeeded() {
        guard let send, transportReady,
              let lastSent = lastDesiredStateSent, _desiredState == lastSent,
              desiredStateRetries < Self.maxDesiredStateRetries
        else { return }
        desiredStateRetries += 1
        send(lastSent)
    }
}
