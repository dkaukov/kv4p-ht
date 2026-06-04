import AVFoundation
import AudioToolbox
import os

// SPSC PCM ring buffer. os_unfair_lock is priority-inversion-safe (kernel
// boosts holder to match waiter), so the RT render thread can block-acquire
// without risk of unbounded priority inversion. Hold time is sub-microsecond
// (bulk memcpy only).
private final class PCMRingBuffer: @unchecked Sendable {
    private var buf: [Float]
    private let cap: Int
    private var writeIdx = 0
    private var count    = 0
    private var _lock    = os_unfair_lock_s()

    init(capacity: Int) {
        cap = capacity
        buf = [Float](repeating: 0, count: capacity)
    }

    var available: Int {
        os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }
        return count
    }

    // Lock-free snapshot for logging only — not sequentially consistent.
    var approximateCount: Int { count }

    func write(_ src: UnsafePointer<Float>, frameCount: Int) -> Int {
        os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }
        let space = cap - count
        let n = Swift.min(frameCount, space)
        guard n > 0 else { return 0 }

        let pos   = writeIdx % cap
        let first = Swift.min(n, cap - pos)

        buf.withUnsafeMutableBufferPointer { bptr in
            let dst = bptr.baseAddress!
            _ = (dst + pos).update(from: src, count: first)
            if first < n {
                _ = dst.update(from: src + first, count: n - first)
            }
        }
        writeIdx += n
        count    += n
        return n
    }

    func read(into dst: UnsafeMutablePointer<Float>, frameCount: Int) {
        os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }

        let n = Swift.min(frameCount, count)
        guard n > 0 else {
            for i in 0..<frameCount { dst[i] = 0 }
            return
        }

        let rPos  = (writeIdx - count + cap) % cap
        let first = Swift.min(n, cap - rPos)

        buf.withUnsafeBufferPointer { bptr in
            let src = bptr.baseAddress!
            _ = dst.update(from: src + rPos, count: first)
            if first < n {
                _ = (dst + first).update(from: src, count: n - first)
            }
        }
        for i in n..<frameCount { dst[i] = 0 }
        count -= n
    }

    func clear() {
        os_unfair_lock_lock(&_lock); defer { os_unfair_lock_unlock(&_lock) }
        writeIdx = 0; count = 0
    }
}

actor AudioManager {
    nonisolated let isAvailable: Bool
    nonisolated(unsafe) var onDecodedSamples: (([Float], Int) -> Void)?

    private static let sampleRate: Double = 16000

    // Jitter-buffer hysteresis:
    //
    // startThreshold: hold silence until ring buffer holds this many samples.
    //   Why 1.5 s?  AirPods use A2DP (BR/EDR) on the same 2.4 GHz radio chip as
    //   BLE NUS.  iOS time-divides the radio; A2DP gets priority, so BLE delivery
    //   gaps can reach 500 ms–1 s+ during active A2DP bursts.  1.5 s absorbs these
    //   gaps with margin.  Through speaker (no contention) startup latency is
    //   bounded by the 37-38 frames needed to fill the buffer (~1.5 s at 25 fps),
    //   not by the threshold itself.
    //
    // stopThreshold: if we're draining and the buffer falls below this value,
    //   re-arm the startup gate rather than playing silence indefinitely.
    //   100 ms = 1600 samples — small enough that we re-arm before the user
    //   notices a sustained dropout rather than after.
    private static let startThreshold  =  6400  // 400 ms @ 16 kHz
    private static let stopThreshold   =  1600  // 100 ms @ 16 kHz — re-arm trigger
    private static let softMaxSamples  = 32000  //   2 s — drop incoming when full
    private static let capacitySamples = 80000  //   5 s — ring-buffer capacity

    // IMA ADPCM constants — must match firmware adpcm.h exactly.
    private static let adpcmSamplesPerFrame = 249
    private static let adpcmFrameBytes      = 128   // 4-byte header + 124 nibble bytes

    private static let adpcmStepTable: [Int32] = [
        7,    8,    9,    10,   11,   12,   13,   14,   16,   17,
        19,   21,   23,   25,   28,   31,   34,   37,   41,   45,
        50,   55,   60,   66,   73,   80,   88,   97,   107,  118,
        130,  143,  157,  173,  190,  209,  230,  253,  279,  307,
        337,  371,  408,  449,  494,  544,  598,  658,  724,  796,
        876,  963,  1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358,
        5894, 6484, 7132, 7845, 8630, 9493, 10442,11487,12635,13899,
        15289,16818,18500,20350,22385,24623,27086,29794,32767,
    ]
    private static let adpcmIndexTable: [Int8] = [-1, -1, -1, -1, 2, 4, 6, 8]

    private let engine:     AVAudioEngine
    private let sourceNode: AVAudioSourceNode
    private let pcmFormat:  AVAudioFormat
    private let ringBuffer: PCMRingBuffer
    // RT-safe one-shot startup gate. Render thread is sole writer (sets true).
    // Actor methods reset to false before engine starts / after engine stops.
    private let started: UnsafeMutablePointer<Bool>
    nonisolated(unsafe) private var playing = false
    // Pre-allocated decode buffer — avoids per-frame heap allocation in feedAdpcmFrame.
    nonisolated(unsafe) private var pcmDecodeBuf = [Float](repeating: 0, count: 249)
    // Notification observer tokens — removed on stop() or restart.
    nonisolated(unsafe) private var observations: [NSObjectProtocol] = []

    // TX mic capture state — accessed only from tap thread or when tap not installed.
    nonisolated(unsafe) private var txEncState = (predictor: Int32(0), stepIndex: 0)
    nonisolated(unsafe) private var txFrameHandler: ((Data) -> Void)?
    nonisolated(unsafe) private var txAccumBuf = [Int16](repeating: 0, count: 249)
    nonisolated(unsafe) private var txAccumCount = 0
    nonisolated(unsafe) private var txResampleRatio: Float = 1.0
    nonisolated(unsafe) private var txResamplePhase: Float = 0.0
    nonisolated(unsafe) private var micTapInstalled = false

    var isPlaying: Bool { playing }

    nonisolated var fillMs: Double {
        Double(ringBuffer.approximateCount) / Self.sampleRate * 1000.0
    }

    deinit {
        for obs in observations { NotificationCenter.default.removeObserver(obs) }
        started.deallocate()
    }

    init() {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                sampleRate: Self.sampleRate,
                                channels: 1,
                                interleaved: false)!
        let rb  = PCMRingBuffer(capacity: Self.capacitySamples)
        let eng = AVAudioEngine()
        let st  = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        st.initialize(to: false)

        let threshold = Self.startThreshold
        let stopThr   = Self.stopThreshold
        let sn = AVAudioSourceNode(format: fmt) { _, _, frameCount, audioBufferList -> OSStatus in
            let frames = Int(frameCount)
            let avail  = rb.available

            // Hysteresis gate:
            //   • Not started → silence until buffer >= startThreshold
            //     (1.5 s, must exceed worst-case A2DP burst gap of ~1 s).
            //   • Started but buffer < stopThreshold → re-arm: discard stale
            //     audio, wait for startThreshold before playing again.
            if !st.pointee {
                if avail >= threshold {
                    st.pointee = true
                } else {
                    for channel in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                        if let ptr = channel.mData?.assumingMemoryBound(to: Float.self) {
                            for i in 0..<frames { ptr[i] = 0 }
                        }
                    }
                    return noErr
                }
            } else if avail < stopThr {
                rb.clear()
                st.pointee = false
                for channel in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                    if let ptr = channel.mData?.assumingMemoryBound(to: Float.self) {
                        for i in 0..<frames { ptr[i] = 0 }
                    }
                }
                return noErr
            }

            for channel in UnsafeMutableAudioBufferListPointer(audioBufferList) {
                if let ptr = channel.mData?.assumingMemoryBound(to: Float.self) {
                    rb.read(into: ptr, frameCount: frames)
                }
            }
            return noErr
        }
        sn.volume = 0.35
        eng.attach(sn)
        eng.connect(sn, to: eng.mainMixerNode, format: fmt)

        pcmFormat  = fmt
        ringBuffer = rb
        engine     = eng
        sourceNode = sn
        started    = st
        isAvailable = true
    }

    func start() {
        guard !playing else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                       options: [.defaultToSpeaker, .allowBluetooth])
            try session.setPreferredIOBufferDuration(0.010)
            try session.setActive(true)
            // Poke inputNode so iOS allocates mic hardware now. Without this,
            // inputNode.inputFormat returns 0 Hz and installTap fails later.
            _ = engine.inputNode
            ringBuffer.clear()
            started.pointee = false
            try engine.start()
            playing = true
            registerObservers()
        } catch {
            print("[AudioManager] start failed: \(error)")
        }
    }

    func stop() {
        removeObservers()
        guard playing else { return }
        engine.stop()
        ringBuffer.clear()
        started.pointee = false
        playing = false
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    nonisolated(unsafe) private var rxFrameLog = 0
    nonisolated(unsafe) private var rxPeakMax: Float = 0
    nonisolated(unsafe) private var rxClipCount: Int = 0

    nonisolated func feedAdpcmFrame(_ data: Data) {
        rxFrameLog += 1
        if rxFrameLog <= 3 || rxFrameLog % 100 == 0 {
            print("[AudioManager] feedAdpcm #\(rxFrameLog) playing=\(playing) bytes=\(data.count) bufAvail=\(ringBuffer.approximateCount) peak=\(String(format: "%.3f", rxPeakMax)) clips=\(rxClipCount)")
            if rxFrameLog % 100 == 0 { rxPeakMax = 0 }
        }
        guard playing, data.count >= 5 else { return }
        if ringBuffer.available >= Self.softMaxSamples { return }

        let predictor = Int32(Int16(bitPattern: UInt16(data[0]) | (UInt16(data[1]) << 8)))
        let stepIdx   = max(0, min(Int(data[2]), 88))
        var state = (predictor: predictor, stepIndex: stepIdx)

        pcmDecodeBuf[0] = Float(predictor) / 32768.0
        let nNibbleBytes = data.count - 4
        var idx = 1
        for i in 0..<nNibbleBytes {
            let byte = data[4 + i]
            pcmDecodeBuf[idx] = Self.decodeNibble(byte & 0x0F, &state); idx += 1
            pcmDecodeBuf[idx] = Self.decodeNibble((byte >> 4) & 0x0F, &state); idx += 1
        }
        let nSamples = 1 + nNibbleBytes * 2

        // Track peaks and apply soft limiter
        for i in 0..<nSamples {
            let mag = abs(pcmDecodeBuf[i])
            if mag > rxPeakMax { rxPeakMax = mag }
            if mag > 0.95 { rxClipCount += 1 }
            pcmDecodeBuf[i] = Self.softClip(pcmDecodeBuf[i])
        }

        pcmDecodeBuf.withUnsafeMutableBufferPointer { buf in
            _ = ringBuffer.write(buf.baseAddress!, frameCount: nSamples)
        }
        onDecodedSamples?(Array(pcmDecodeBuf.prefix(nSamples)), nSamples)
    }

    // tanh soft limiter — prevents harsh digital clipping
    private static func softClip(_ x: Float) -> Float {
        if x > 0.8 || x < -0.8 {
            return 0.8 * tanhf(x / 0.8)
        }
        return x
    }

    // MARK: – TX Mic Capture

    func startMicCapture(handler: @escaping (Data) -> Void) {
        let granted = AVAudioSession.sharedInstance().recordPermission == .granted
        if !granted {
            AVAudioApplication.requestRecordPermission { [weak self] ok in
                guard ok, let self else {
                    print("[AudioManager] mic permission denied")
                    return
                }
                Task { await self.installMicTap(handler: handler) }
            }
            return
        }
        installMicTap(handler: handler)
    }

    private func installMicTap(handler: @escaping (Data) -> Void) {
        if micTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }
        txFrameHandler = handler
        txEncState = (predictor: 0, stepIndex: 0)
        txAccumCount = 0
        txResamplePhase = 0
        txResampleRatio = 0 // sentinel — computed from first buffer

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.processMicBuffer(buffer)
        }
        micTapInstalled = true
    }

    func stopMicCapture() {
        print("[AudioManager] stopMicCapture: tapInstalled=\(micTapInstalled) playing=\(playing) engineRunning=\(engine.isRunning)")
        if micTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
            print("[AudioManager] stopMicCapture: tap removed")
        }
        txFrameHandler = nil
        txAccumCount = 0
        engine.stop()
        ringBuffer.clear()
        started.pointee = false
        print("[AudioManager] stopMicCapture: engine stopped, buffer cleared")
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try engine.start()
            playing = true
            print("[AudioManager] stopMicCapture: engine restarted OK, playing=true route=\(session.currentRoute.outputs.map { $0.portName })")
        } catch {
            print("[AudioManager] stopMicCapture: engine restart FAILED: \(error)")
            playing = false
        }
    }

    nonisolated private func processMicBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatData = buffer.floatChannelData?[0] else { return }
        let frameCount = Int(buffer.frameLength)

        if txResampleRatio == 0 {
            let hwRate = buffer.format.sampleRate
            if hwRate > 0 && hwRate != Self.sampleRate {
                txResampleRatio = Float(Self.sampleRate / hwRate)
            } else {
                txResampleRatio = 1.0
            }
            print("[AudioManager] mic tap format: \(buffer.format) resampleRatio=\(txResampleRatio) frames=\(frameCount)")
        }
        let ratio = txResampleRatio
        guard ratio > 0 else { return }

        if ratio == 1.0 {
            var offset = 0
            while offset < frameCount {
                let space = Self.adpcmSamplesPerFrame - txAccumCount
                let chunk = min(space, frameCount - offset)
                for i in 0..<chunk {
                    let s = max(-1.0, min(1.0, floatData[offset + i]))
                    txAccumBuf[txAccumCount + i] = Int16(s * 32767.0)
                }
                txAccumCount += chunk
                offset += chunk
                if txAccumCount == Self.adpcmSamplesPerFrame {
                    flushTxAccum()
                }
            }
        } else {
            var phase = txResamplePhase
            for i in 0..<frameCount {
                phase += ratio
                while phase >= 1.0 && txAccumCount < Self.adpcmSamplesPerFrame {
                    phase -= 1.0
                    let s = max(-1.0, min(1.0, floatData[i]))
                    txAccumBuf[txAccumCount] = Int16(s * 32767.0)
                    txAccumCount += 1
                    if txAccumCount == Self.adpcmSamplesPerFrame {
                        flushTxAccum()
                    }
                }
            }
            txResamplePhase = phase
        }
    }

    nonisolated(unsafe) private var txFlushCount = 0

    nonisolated private func flushTxAccum() {
        let frame = encodeAdpcmFrame(&txAccumBuf, state: &txEncState)
        txFlushCount += 1
        if txFlushCount <= 3 {
            print("[AudioManager] flushTxAccum #\(txFlushCount) frame=\(frame.count)B handler=\(txFrameHandler != nil)")
        }
        txFrameHandler?(frame)
        txAccumCount = 0
    }

    // MARK: – ADPCM Encoder

    nonisolated private func encodeAdpcmFrame(_ samples: UnsafePointer<Int16>,
                                               state: inout (predictor: Int32, stepIndex: Int)) -> Data {
        var frame = Data(count: Self.adpcmFrameBytes)
        // IMA WAV: sample[0] becomes the header predictor
        state.predictor = Int32(samples[0])
        frame[0] = UInt8(truncatingIfNeeded: state.predictor)
        frame[1] = UInt8(truncatingIfNeeded: state.predictor >> 8)
        frame[2] = UInt8(truncatingIfNeeded: state.stepIndex)
        frame[3] = 0

        // Encode samples 1..248 as 124 nibble-pair bytes
        let nNibbleBytes = (Self.adpcmSamplesPerFrame - 1) / 2
        for i in 0..<nNibbleBytes {
            let lo = Self.encodeNibble(samples[1 + i * 2],     &state)
            let hi = Self.encodeNibble(samples[1 + i * 2 + 1], &state)
            frame[4 + i] = (hi << 4) | lo
        }
        return frame
    }

    private static func encodeNibble(_ sample: Int16,
                                      _ s: inout (predictor: Int32, stepIndex: Int)) -> UInt8 {
        let step = adpcmStepTable[s.stepIndex]
        var diff = Int32(sample) - s.predictor
        var nibble: UInt8 = 0

        if diff < 0 { nibble = 8; diff = -diff }
        if diff >= step        { nibble |= 4; diff -= step }
        if diff >= (step >> 1) { nibble |= 2; diff -= step >> 1 }
        if diff >= (step >> 2) { nibble |= 1 }

        var vdiff = step >> 3
        if nibble & 4 != 0 { vdiff += step }
        if nibble & 2 != 0 { vdiff += step >> 1 }
        if nibble & 1 != 0 { vdiff += step >> 2 }
        if nibble & 8 != 0 { vdiff = -vdiff }

        var pred = s.predictor + vdiff
        if pred >  32767 { pred =  32767 }
        if pred < -32768 { pred = -32768 }
        s.predictor = pred

        var idx = s.stepIndex + Int(adpcmIndexTable[Int(nibble & 7)])
        if idx < 0  { idx = 0 }
        if idx > 88 { idx = 88 }
        s.stepIndex = idx

        return nibble
    }

    // MARK: – Private

    private func registerObservers() {
        removeObservers()

        // AVAudioEngine stops automatically on route changes (headphones, BT device,
        // speaker routing). Restart it and re-arm the startup gate.
        observations.append(
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                Task { await self.restartAfterConfigChange() }
            }
        )

        // Phone call, Siri, alarm, etc. — resume when interruption ends.
        observations.append(
            NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: nil
            ) { [weak self] note in
                guard let self else { return }
                Task { await self.handleInterruption(note) }
            }
        )
    }

    private func removeObservers() {
        for obs in observations { NotificationCenter.default.removeObserver(obs) }
        observations = []
    }

    private func restartAfterConfigChange() {
        guard playing else { return }
        // During TX (tap installed), skip restart — the tap's format may
        // not match the new hardware config, causing -10868. stopMicCapture
        // will do a clean restart when TX ends.
        if micTapInstalled {
            print("[AudioManager] configChange: tap active, deferring restart to stopMicCapture")
            return
        }
        ringBuffer.clear()
        started.pointee = false
        do {
            try engine.start()
        } catch {
            print("[AudioManager] route-change restart failed: \(error)")
            playing = false
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue),
              type == .ended,
              playing else { return }

        let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        guard AVAudioSession.InterruptionOptions(rawValue: optionsValue).contains(.shouldResume)
        else { return }

        ringBuffer.clear()
        started.pointee = false
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
        } catch {
            print("[AudioManager] interruption resume failed: \(error)")
            playing = false
        }
    }

    private static func decodeNibble(_ nibble: UInt8,
                                     _ s: inout (predictor: Int32, stepIndex: Int)) -> Float {
        let step = adpcmStepTable[s.stepIndex]
        var diff = step >> 3
        if nibble & 4 != 0 { diff += step }
        if nibble & 2 != 0 { diff += step >> 1 }
        if nibble & 1 != 0 { diff += step >> 2 }
        if nibble & 8 != 0 { diff = -diff }

        var pred = s.predictor + diff
        if pred >  32767 { pred =  32767 }
        if pred < -32768 { pred = -32768 }
        s.predictor = pred

        var idx = s.stepIndex + Int(adpcmIndexTable[Int(nibble & 7)])
        if idx < 0  { idx = 0  }
        if idx > 88 { idx = 88 }
        s.stepIndex = idx

        return Float(pred) / 32768.0
    }
}
