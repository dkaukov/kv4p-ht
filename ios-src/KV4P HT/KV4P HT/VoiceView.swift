import SwiftUI
import AVFoundation
import Combine
import MediaPlayer
import UIKit

// MARK: - Voice Tab root

struct VoiceView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var showCaptions = false
    @State private var showDevicePicker = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            DeviceStrip(
                connected: store.ble.bleState == .ready,
                action: { showDevicePicker = true }
            )

            Picker("Mode", selection: $store.voiceMode) {
                ForEach(VoiceMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.bottom, 2)

            switch store.voiceMode {
            case .simplex:  SimplexBody(store: store, showCaptions: $showCaptions)
            case .repeater: RepeaterBody(store: store, showCaptions: $showCaptions)
            case .scan:     ScanBody(store: store)
            }

            Spacer(minLength: 0)
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HeaderIconBtn(systemImage: "gearshape.fill") { showSettings = true }
            }
        }
        .sheet(isPresented: $showCaptions) {
            NavigationStack {
                CaptionsSheet(store: store)
            }
            .environment(\.theme, store.theme)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDevicePicker) {
            DevicePickerView(ble: store.ble)
                .environment(\.theme, store.theme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
                .environment(\.theme, store.theme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: store.voiceMode) { _, mode in
            if mode != .scan { store.stopScan() }
        }
        .onAppear {
            if store.ble.bleState == .idle { showDevicePicker = true }
        }
        .onChange(of: store.isSquelched) { _, _ in
            store.checkSquelchTransition()
        }
        .onChange(of: store.ble.bleState) { _, state in
            if state == .ready {
                store.setupAudioSampleHook()
            }
        }
    }
}

// MARK: - Simplex / Repeater body (shared radio stage)

private struct SimplexBody: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @Binding var showCaptions: Bool

    private var channel: (name: String, desc: String, freq: String, offset: String, tone: String) {
        let matched = store.memory(for: store.currentFreq)
        return (
            name:   matched?.name ?? store.currentFreqString,
            desc:   matched?.notes ?? "",
            freq:   store.currentFreqString,
            offset: "Simplex",
            tone:   matched?.toneString ?? "Off"
        )
    }

    var body: some View {
        RadioStage(
            store:        store,
            channelName:  channel.name,
            channelDesc:  channel.desc,
            freq:         channel.freq,
            offset:       channel.offset,
            tone:         channel.tone,
            modeLabel:    "VHF · Simplex",
            freqEditable: true,
            showCaptions: $showCaptions
        )
    }
}

private struct RepeaterBody: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @Binding var showCaptions: Bool

    private var repeater: Repeater? {
        store.repeaters.first
    }

    var body: some View {
        let r = repeater
        RadioStage(
            store:        store,
            channelName:  r?.name ?? "Repeater",
            channelDesc:  r.map { "\($0.callsign) · \($0.location)" } ?? "",
            freq:         r?.freqString ?? store.currentFreqString,
            offset:       r?.offsetString ?? "−0.600",
            tone:         r.map { "PL \(String(format: "%.1f", $0.plTone))" } ?? "Off",
            modeLabel:    "VHF · Repeater",
            showCaptions: $showCaptions
        )
    }
}

// MARK: - Shared radio stage

private struct RadioStage: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    var channelName:  String
    var channelDesc:  String
    var freq:         String
    var offset:       String
    var tone:         String
    var modeLabel:    String
    var freqEditable: Bool = false
    @Binding var showCaptions: Bool

    @GestureState private var pttDown = false
    @State private var stickyPttActive = false
    @State private var showNumpad = false

    private var rxState: RadioRxState {
        if store.stickyPTT && stickyPttActive { return .tx }
        return pttDown ? .tx : store.rxMode
    }

    private var pttActive: Bool {
        pttDown || (store.stickyPTT && stickyPttActive)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Mode chip
            HStack(spacing: 6) {
                Circle()
                    .fill(pttActive ? t.red : t.accent)
                    .frame(width: 6, height: 6)
                Text(modeLabel)
                    .font(.system(size: 12.5, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(t.label)
                    .textCase(.uppercase)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(t.fill)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .padding(.top, 20)

            // Frequency
            Group {
                if freqEditable {
                    Button { showNumpad = true } label: {
                        FreqReadout(freq: freq, tx: pttActive)
                    }
                    .buttonStyle(.plain)
                } else {
                    FreqReadout(freq: freq, tx: pttActive)
                }
            }
            .padding(.top, 6)

            // Channel name
            VStack(spacing: 2) {
                Text(channelName)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(t.label)
                Text(channelDesc)
                    .font(.system(size: 13.5))
                    .foregroundStyle(t.label2)
            }
            .padding(.top, 2)

            // S-meter + badge
            HStack(spacing: 14) {
                SMeter(level: pttActive ? 0 : store.signalLevel, active: !pttActive, rawRSSI: store.rawRSSI)
                RxBadge(state: rxState)
            }
            .padding(.top, 8)

            // Info pills
            HStack(spacing: 8) {
                InfoPill(key: "Offset", value: offset)
                InfoPill(key: "Tone",   value: tone)
                InfoPill(key: "Power",  value: store.txPower)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 14)

            // PTT + controls row
            HStack(spacing: 24) {
                if store.stickyPTT {
                    PTTButton(isDown: stickyPttActive)
                        .onTapGesture {
                            stickyPttActive.toggle()
                            store.sendRadioState(
                                freq: Float(freq) ?? 146.52,
                                ptt: stickyPttActive
                            )
                        }
                } else {
                    PTTButton(isDown: pttDown)
                        .gesture(
                            LongPressGesture(minimumDuration: 0.01)
                                .sequenced(before: DragGesture(minimumDistance: 0))
                                .updating($pttDown) { _, state, _ in state = true }
                                .onEnded { _ in
                                    store.sendRadioState(
                                        freq: Float(freq) ?? 146.52,
                                        ptt: false
                                    )
                                }
                        )
                        .onChange(of: pttDown) { _, down in
                            store.sendRadioState(
                                freq: Float(freq) ?? 146.52,
                                ptt: down
                            )
                        }
                }

                VStack(spacing: 16) {
                    SystemVolumeSlider()
                    VolumeSlider(
                        icon: "waveform",
                        pct: Binding(
                            get: { Double(store.squelch) / 9.0 },
                            set: { store.squelch = UInt8(round($0 * 9.0)) }
                        ),
                        label: "SQ \(store.squelch)",
                        editable: true,
                        onEnded: { pct in
                            store.squelch = UInt8(round(pct * 9.0))
                            store.sendRadioState(freq: Float(freq) ?? 146.52, ptt: false)
                        }
                    )
                    HStack(spacing: 8) {
                        SmallAction(
                            systemImage: "captions.bubble",
                            label:       "Captions",
                            on:          showCaptions
                        ) { showCaptions = true }
                        SmallAction(
                            systemImage: "record.circle",
                            label:       "Record",
                            on:          false
                        ) { }
                        .disabled(true)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 8)
        .sheet(isPresented: $showNumpad) {
            FreqNumpad(store: store, currentFreq: freq)
                .environment(\.theme, store.theme)
                .presentationDetents([.height(420)])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - PTT Button

struct PTTButton: View {
    @Environment(\.theme) var t
    var isDown: Bool

    private var ringColor: Color { isDown ? t.red : t.accent }
    private var grad: LinearGradient {
        if isDown {
            return LinearGradient(colors: [Color(hex: "FF6B61"), t.red], startPoint: .top, endPoint: .bottom)
        } else {
            return LinearGradient(colors: [t.isDark ? Color(hex: "3A9BFF") : Color(hex: "3F96FF"), t.accent], startPoint: .top, endPoint: .bottom)
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(ringColor, lineWidth: 2)
                .opacity(isDown ? 0.5 : 0.22)
                .frame(width: 168, height: 168)
            Circle()
                .stroke(ringColor, lineWidth: 1.5)
                .opacity(isDown ? 0.35 : 0.14)
                .frame(width: 148, height: 148)
            Circle()
                .fill(grad)
                .frame(width: 132, height: 132)
                .shadow(color: isDown ? t.red.opacity(0.53) : t.accent.opacity(0.27), radius: 22)
                .shadow(color: Color.black.opacity(0.35), radius: 15, y: 10)
                .overlay(
                    VStack(spacing: 5) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 36, weight: .medium))
                            .foregroundStyle(.white)
                        Text(isDown ? "ON AIR" : "HOLD")
                            .font(.system(size: 11.5, weight: .heavy))
                            .tracking(1.2)
                            .foregroundStyle(.white)
                    }
                )
        }
        .scaleEffect(isDown ? 0.97 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isDown)
    }
}

// MARK: - Volume slider row

private struct VolumeSlider: View {
    @Environment(\.theme) var t
    var icon: String
    @Binding var pct: Double
    var label: String
    var editable: Bool = false
    var onEnded: ((Double) -> Void)?

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(t.label2)
                .frame(width: 20)
            GeometryReader { geo in
                let bar = ZStack(alignment: .leading) {
                    Capsule().fill(t.meterTrack).frame(height: 5)
                    Capsule().fill(t.label2).frame(width: geo.size.width * pct, height: 5)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: geo.size.width * pct - 7.5, y: 0)
                }
                if editable {
                    bar.gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { v in pct = max(0, min(1, v.location.x / geo.size.width)) }
                            .onEnded { _ in onEnded?(pct) }
                    )
                } else {
                    bar
                }
            }
            .frame(height: 15)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(t.label2)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

// MARK: - System volume observer

private final class VolumeObserver: ObservableObject {
    @Published var volume: Double = Double(AVAudioSession.sharedInstance().outputVolume)
    private var observation: NSKeyValueObservation?
    var isUserDragging = false

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] _, change in
            guard let self, let v = change.newValue, !self.isUserDragging else { return }
            DispatchQueue.main.async { self.volume = Double(v) }
        }
    }
}

// MARK: - System volume slider (matches VolumeSlider design)

private struct SystemVolumeSlider: View {
    @Environment(\.theme) var t
    @Environment(\.mpVolumeView) var mpVolumeView
    @StateObject private var observer = VolumeObserver()

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(t.label2)
                .frame(width: 20)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.meterTrack).frame(height: 5)
                    Capsule().fill(t.label2).frame(width: geo.size.width * observer.volume, height: 5)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: geo.size.width * observer.volume - 7.5, y: 0)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            observer.isUserDragging = true
                            observer.volume = max(0, min(1, Double(v.location.x / geo.size.width)))
                        }
                        .onEnded { _ in
                            observer.isUserDragging = false
                        }
                )
            }
            .frame(height: 15)
            Text("VOL")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(t.label2)
                .frame(width: 34, alignment: .trailing)
        }
        .onChange(of: observer.volume) { _, newVol in
            mpVolumeView?.subviews.compactMap({ $0 as? UISlider }).first?.value = Float(newVol)
        }
    }
}

// MARK: - Frequency readout

struct FreqReadout: View {
    @Environment(\.theme) var t
    var freq: String
    var size: CGFloat = 74
    var tx: Bool = false

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            Text(freq)
                .font(.system(size: size, weight: .bold, design: .default).monospacedDigit())
                .tracking(-1.5)
                .foregroundStyle(tx ? t.red : t.label)
            Text("MHz")
                .font(.system(size: size * 0.27, weight: .semibold))
                .foregroundStyle(t.label2)
        }
    }
}

// MARK: - Frequency numpad

private struct FreqNumpad: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    var currentFreq: String

    @State private var digits: String
    @State private var hasEdited = false

    private static let maxDigits = 7

    init(store: RadioStore, currentFreq: String) {
        self.store = store
        self.currentFreq = currentFreq
        _digits = State(initialValue: currentFreq.replacingOccurrences(of: ".", with: ""))
    }

    private var displayText: String {
        let padded = digits + String(repeating: "0", count: max(0, 3 - digits.count))
        let mhz = String(padded.prefix(3))
        let khz = String(padded.dropFirst(3).prefix(3))
        return "\(mhz).\(khz)"
    }

    private func commit() {
        guard let f = Float(displayText) else { return }
        store.sendRadioState(freq: f, ptt: false)
        dismiss()
    }

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()

                // Display
                VStack(spacing: 2) {
                    Text(displayText)
                        .font(.system(size: 48, weight: .bold, design: .monospaced))
                        .foregroundStyle(t.label)
                        .contentTransition(.numericText())
                    Text("MHz")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(t.label2)
                }
                .padding(.bottom, 28)

                // Numpad
                VStack(spacing: 10) {
                    numpadRow(["1","2","3"])
                    numpadRow(["4","5","6"])
                    numpadRow(["7","8","9"])
                    numpadRow([".","0","⌫"])
                }
                .padding(.horizontal, 28)

                // Set
                Button(action: commit) {
                    Text("SET")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(t.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
        }
    }

    private func numpadRow(_ keys: [String]) -> some View {
        HStack(spacing: 10) {
            ForEach(keys, id: \.self) { key in
                Button {
                    tap(key)
                } label: {
                    Text(key)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(key == "⌫" ? t.label2 : t.label)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(t.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func tap(_ key: String) {
        switch key {
        case "⌫":
            guard !digits.isEmpty else { return }
            digits = String(digits.dropLast())
            hasEdited = true
        case ".":
            break  // decimal is auto-placed — key kept for visual familiarity
        default:
            guard digits.count < Self.maxDigits else { return }
            if !hasEdited { digits = ""; hasEdited = true }
            digits.append(key)
        }
    }
}

// MARK: - Scan screen

private struct ScanBody: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    private var scanList: [Memory] { store.scanList }

    var body: some View {
        if scanList.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "barcode.viewfinder")
                    .font(.system(size: 48, weight: .thin))
                    .foregroundStyle(t.label3)
                Text("No scan channels")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(t.label)
                Text("Add memories to build a scan list.")
                    .font(.system(size: 14))
                    .foregroundStyle(t.label2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Spacer()
            }
        } else {
            VStack(spacing: 0) {
                // Current freq readout
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: store.scanPaused ? "pause.circle.fill" : "barcode.viewfinder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(store.scanPaused ? t.green : t.label2)
                        Text(store.scanPaused ? "PAUSED" : (store.isScanning ? "SCANNING" : "SCAN"))
                            .font(.system(size: 12.5, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(store.scanPaused ? t.green : t.label2)
                    }
                    FreqReadout(freq: store.currentFreqString, size: 60)
                    SMeter(level: store.signalLevel, rawRSSI: store.rawRSSI)
                }
                .padding(.vertical, 20)

                Text("Scan list · \(scanList.count) channels")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(t.label2)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(scanList.enumerated()), id: \.element.id) { idx, mem in
                            let active = store.isScanning && idx == store.scanIndex
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(active ? t.accent : t.label3)
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mem.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(active ? t.accent : t.label)
                                    Text(mem.group)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(active ? t.accent.opacity(0.7) : t.label2)
                                }
                                Spacer()
                                Text(mem.freqString)
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(active ? t.accent : t.label2)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 50)
                            .background(active ? t.accentSoft : Color.clear)
                            if idx < scanList.count - 1 {
                                Divider().padding(.leading, 34).background(t.sep)
                            }
                        }
                    }
                    .background(t.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                }

                if store.isScanning {
                    HStack(spacing: 12) {
                        if store.scanPaused {
                            Text("Signal found")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(t.green)
                        }
                        PillButton(label: "Stop scan", systemImage: "stop.fill", filled: false) {
                            store.stopScan()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                } else {
                    PillButton(label: "Start scan", systemImage: "barcode.viewfinder", filled: true) {
                        store.startScan()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                }
            }
        }
    }
}

// MARK: - Captions sheet

struct CaptionsSheet: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore

    var body: some View {
        VStack(spacing: 0) {
            // Mini freq + LIVE badge
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.currentFreqString)
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                        .foregroundStyle(t.label)
                    Text("Live transcription · on-device")
                        .font(.system(size: 13))
                        .foregroundStyle(t.label2)
                }
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(t.red)
                        .frame(width: 7, height: 7)
                        .shadow(color: t.red, radius: 4)
                    Text("LIVE")
                        .font(.system(size: 12, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(t.red)
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(t.redSoft)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)

            // Transcript
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(store.captionLines) { line in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(line.callsign)
                                    .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                                    .foregroundStyle(line.active ? t.green : t.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(line.active ? t.greenSoft : t.accentSoft)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                if !line.active {
                                    Text(line.time)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .foregroundStyle(t.label3)
                                } else {
                                    HStack(spacing: 3) {
                                        ForEach(0..<3, id: \.self) { i in
                                            Circle()
                                                .fill(t.green.opacity(1.0 - Double(i) * 0.35))
                                                .frame(width: 4, height: 4)
                                        }
                                    }
                                }
                            }
                            if line.active {
                                Text(line.text)
                                    .font(.system(size: 16.5))
                                    .foregroundStyle(t.label2)
                                    .italic()
                                    .padding(.horizontal, 13)
                            } else {
                                Text(line.text)
                                    .font(.system(size: 16.5))
                                    .lineSpacing(4)
                                    .foregroundStyle(t.label)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 10)
                                    .background(t.surface)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }

            // Bottom actions (coming soon)
            HStack(spacing: 8) {
                SmallAction(systemImage: "captions.bubble", label: "Captions", on: true) { }
                    .disabled(true)
                SmallAction(systemImage: "record.circle",   label: "Record") { }
                    .disabled(true)
                SmallAction(systemImage: "magnifyingglass", label: "Search log") { }
                    .disabled(true)
                SmallAction(systemImage: "arrow.down.to.line", label: "Save") { }
                    .disabled(true)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
            .padding(.top, 8)

            if store.captionLines.isEmpty {
                Text("Waiting for audio…")
                    .font(.system(size: 14))
                    .foregroundStyle(t.label3)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)
            }
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HeaderIconBtn(systemImage: "gearshape.fill") { }
            }
        }
        .environment(\.theme, store.theme)
    }
}
