import Testing
import Foundation
@testable import KV4P_HT

private final class SentFrames {
    var frames: [HostDesiredState] = []
}

private func makeDeviceState(
    seq: UInt32 = 7,
    flags: UInt16 = HOST_STATE_RADIO_CONFIG_VALID | HOST_STATE_HIGH_POWER | HOST_STATE_RSSI_ENABLED,
    bw: UInt8 = DRA818_25K,
    freqTx: Float = 146.52,
    freqRx: Float = 146.52,
    ctcssTx: UInt8 = 0,
    squelch: UInt8 = 2,
    ctcssRx: UInt8 = 0,
    lastError: UInt8 = 0
) -> DeviceStateFrame {
    DeviceStateFrame(
        appliedSequence: seq, memoryId: -1, flags: flags,
        bw: bw, freqTx: freqTx, freqRx: freqRx,
        ctcssTx: ctcssTx, squelch: squelch, ctcssRx: ctcssRx,
        radioModuleStatus: RADIO_STATUS_FOUND, mode: 1, lastError: lastError, rssi: 100)
}

// Firmware echo of a desired state the host sent (i.e. firmware applied it).
private func echo(_ d: HostDesiredState, lastError: UInt8 = 0) -> DeviceStateFrame {
    DeviceStateFrame(
        appliedSequence: d.sequence, memoryId: d.memoryId, flags: d.flags,
        bw: d.bw, freqTx: d.freqTx, freqRx: d.freqRx,
        ctcssTx: d.ctcssTx, squelch: d.squelch, ctcssRx: d.ctcssRx,
        radioModuleStatus: RADIO_STATUS_FOUND, mode: 1, lastError: lastError, rssi: 100)
}

// Controller seeded from `seed`, transport attached and ready. The post-seed
// flush always emits one frame (the STATUS_REPORTS re-enable), so tests start
// from sent.frames.count == 1.
private func makeReadyController(seed: DeviceStateFrame = makeDeviceState()) -> (RadioModuleController, SentFrames) {
    let controller = RadioModuleController()
    let sent = SentFrames()
    controller.attachTransport { sent.frames.append($0) }
    controller.seedFromDeviceState(seed)
    controller.markTransportReady()
    return (controller, sent)
}

struct RadioModuleControllerTests {

    @Test func seedsDesiredStateFromDeviceState() {
        let controller = RadioModuleController()
        let seed = makeDeviceState(seq: 42, freqTx: 147.0, freqRx: 146.4, ctcssTx: 5, squelch: 3)
        controller.seedFromDeviceState(seed)

        let desired = controller.desiredState
        #expect(desired.sequence == 42)
        #expect(desired.freqTx == 147.0)
        #expect(desired.freqRx == 146.4)
        #expect(desired.ctcssTx == 5)
        #expect(desired.squelch == 3)
        #expect(desired.bw == DRA818_25K)
        // PTT/RX_AUDIO never seeded on; status reports forced on.
        #expect(desired.flags & HOST_STATE_PTT_REQUESTED == 0)
        #expect(desired.flags & HOST_STATE_RX_AUDIO_OPEN == 0)
        #expect(desired.flags & HOST_STATE_ENABLE_STATUS_REPORTS != 0)
        #expect(desired.flags & HOST_STATE_RADIO_CONFIG_VALID != 0)
    }

    @Test func seedWithoutRadioConfigFallsBackToDefaults() {
        let controller = RadioModuleController()
        controller.seedFromDeviceState(makeDeviceState(seq: 9, flags: 0, freqTx: 0, freqRx: 0))

        let desired = controller.desiredState
        #expect(desired.sequence == 9)
        #expect(desired.flags & HOST_STATE_RADIO_CONFIG_VALID == 0)
        #expect(desired.bw == DRA818_25K)
    }

    @Test func seedFlushEnablesStatusReportsOnce() {
        let (_, sent) = makeReadyController()
        #expect(sent.frames.count == 1)
        #expect(sent.frames[0].flags & HOST_STATE_ENABLE_STATUS_REPORTS != 0)
    }

    @Test func sendsOnlyOnChange() {
        let seed = makeDeviceState(squelch: 2)
        let (controller, sent) = makeReadyController(seed: seed)
        #expect(sent.frames.count == 1)

        controller.setSquelch(2)  // no-op: same value
        #expect(sent.frames.count == 1)

        controller.setSquelch(5)
        #expect(sent.frames.count == 2)
        #expect(sent.frames[1].squelch == 5)
    }

    @Test func batchedUpdateEmitsSingleFrame() {
        let (controller, sent) = makeReadyController()
        controller.beginUpdate()
        controller.setRxFrequency(147.105)
        controller.setTxFrequency(147.705)
        controller.setSquelch(4)
        #expect(sent.frames.count == 1)  // nothing sent mid-batch
        controller.endUpdate()
        #expect(sent.frames.count == 2)
        #expect(sent.frames[1].freqRx == 147.105)
        #expect(sent.frames[1].freqTx == 147.705)
        #expect(sent.frames[1].squelch == 4)
    }

    @Test func sequenceIncrementsPerSend() {
        let seed = makeDeviceState(seq: 10)
        let (controller, sent) = makeReadyController(seed: seed)
        #expect(sent.frames[0].sequence == 11)

        controller.setSquelch(5)
        #expect(sent.frames[1].sequence == 12)

        controller.setRxFrequency(147.0)
        #expect(sent.frames[2].sequence == 13)
    }

    @Test func appliedStateSyncTracksFirmwareEcho() {
        let (controller, sent) = makeReadyController()
        controller.setSquelch(6)
        #expect(!controller.isAppliedStateInSync)

        controller.updateDeviceState(echo(sent.frames.last!))
        #expect(controller.isAppliedStateInSync)
    }

    @Test func mismatchAndLastErrorBreakSync() {
        let (controller, sent) = makeReadyController()
        controller.setSquelch(6)
        let applied = sent.frames.last!

        // Firmware error → out of sync even if fields match.
        controller.updateDeviceState(echo(applied, lastError: 3))
        #expect(!controller.isAppliedStateInSync)

        // Stale sequence → out of sync.
        var stale = applied
        stale.sequence &-= 1
        controller.updateDeviceState(echo(stale))
        #expect(!controller.isAppliedStateInSync)
    }

    @Test func retriesCappedAtThree() {
        let (controller, sent) = makeReadyController()
        controller.setSquelch(6)
        let countAfterSend = sent.frames.count
        let lastSent = sent.frames.last!

        // Firmware keeps reporting a stale sequence → retry per report, max 3.
        var stale = lastSent
        stale.sequence &-= 1
        for _ in 0..<6 {
            controller.updateDeviceState(echo(stale))
        }
        #expect(sent.frames.count == countAfterSend + RadioModuleController.maxDesiredStateRetries)
        #expect(sent.frames.suffix(RadioModuleController.maxDesiredStateRetries).allSatisfy { $0 == lastSent })

        // Once firmware catches up, sync restores and retries stop.
        controller.updateDeviceState(echo(lastSent))
        #expect(controller.isAppliedStateInSync)
        #expect(sent.frames.count == countAfterSend + RadioModuleController.maxDesiredStateRetries)
    }

    @Test func noSendsBeforeTransportReady() {
        let controller = RadioModuleController()
        let sent = SentFrames()
        controller.attachTransport { sent.frames.append($0) }
        controller.seedFromDeviceState(makeDeviceState())
        controller.setSquelch(8)
        #expect(sent.frames.isEmpty)
        controller.markTransportReady()
        #expect(sent.frames.count == 1)
        #expect(sent.frames[0].squelch == 8)
    }
}

struct FlowControlGateTests {

    private func makeGate(window: Int) -> (FlowControlGate, SentData) {
        let gate = FlowControlGate()
        let sent = SentData()
        gate.onSend = { sent.frames.append($0) }
        gate.setWindow(window)
        return (gate, sent)
    }

    final class SentData {
        var frames: [Data] = []
    }

    @Test func decrementsWindowByWireLength() {
        let (gate, sent) = makeGate(window: 100)
        gate.submit(Data(count: 30))
        #expect(sent.frames.count == 1)
        #expect(gate.window == 70)
    }

    @Test func defersFramesWhenWindowTooSmall() {
        let (gate, sent) = makeGate(window: 10)
        gate.submit(Data(count: 30))
        #expect(sent.frames.isEmpty)
        #expect(gate.pending.count == 1)
    }

    @Test func windowUpdateDrainsQueueInOrder() {
        let (gate, sent) = makeGate(window: 0)
        gate.submit(Data([1]))
        gate.submit(Data([2, 2]))
        gate.submit(Data([3, 3, 3]))
        #expect(sent.frames.isEmpty)

        gate.enlargeWindow(by: 3)  // fits first two only
        #expect(sent.frames == [Data([1]), Data([2, 2])])
        #expect(gate.window == 0)

        gate.enlargeWindow(by: 10)
        #expect(sent.frames.count == 3)
        #expect(sent.frames[2] == Data([3, 3, 3]))
        #expect(gate.window == 7)
    }

    @Test func preservesOrderEvenWhenLaterFrameFits() {
        let (gate, sent) = makeGate(window: 5)
        gate.submit(Data(count: 10))  // blocked
        gate.submit(Data(count: 2))   // would fit, but must wait its turn
        #expect(sent.frames.isEmpty)
        gate.enlargeWindow(by: 10)
        #expect(sent.frames.count == 2)
        #expect(sent.frames[0].count == 10)
    }

    @Test func resetRestoresDefaultWindowAndDropsQueue() {
        let (gate, sent) = makeGate(window: 0)
        gate.submit(Data(count: 4))
        gate.reset()
        #expect(gate.pending.isEmpty)
        #expect(gate.window == FlowControlGate.defaultWindow)
        #expect(sent.frames.isEmpty)
    }
}
