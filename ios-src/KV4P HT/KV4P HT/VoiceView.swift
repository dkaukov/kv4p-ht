import SwiftUI

// MARK: - Voice Tab root

struct VoiceView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var showCaptions = false
    @State private var showDevicePicker = false

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                NavHeader(
                    title: "Voice",
                    large: false,
                    rightContent: HeaderIconBtn(systemImage: "gearshape.fill") { }
                )
                DeviceStrip(
                    connected: store.ble.bleState == .ready,
                    action: { showDevicePicker = true }
                )

                KVSegmented(
                    options: VoiceMode.allCases.map(\.label),
                    value: Binding(
                        get: { store.voiceMode.label },
                        set: { v in store.voiceMode = VoiceMode.allCases.first { $0.label == v } ?? .simplex }
                    )
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 2)

                switch store.voiceMode {
                case .simplex:  SimplexBody(store: store, showCaptions: $showCaptions)
                case .repeater: RepeaterBody(store: store, showCaptions: $showCaptions)
                case .scan:     ScanBody(store: store)
                }
            }
        }
        .sheet(isPresented: $showCaptions) {
            CaptionsSheet(store: store)
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
        .onAppear {
            if store.ble.bleState == .idle { showDevicePicker = true }
        }
    }
}

// MARK: - Simplex / Repeater body (shared radio stage)

private struct SimplexBody: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @Binding var showCaptions: Bool

    private var channel: (name: String, desc: String, freq: String, offset: String, tone: String) {
        (
            name:   "Simplex",
            desc:   "National calling frequency",
            freq:   store.currentFreqString,
            offset: "Simplex",
            tone:   "Off"
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
    @Binding var showCaptions: Bool

    @GestureState private var pttDown = false

    private var rxState: RadioRxState { pttDown ? .tx : store.rxMode }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Mode chip
            HStack(spacing: 6) {
                Circle()
                    .fill(pttDown ? t.red : t.accent)
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

            // Frequency
            FreqReadout(freq: freq, tx: pttDown)
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
                SMeter(level: pttDown ? 0 : store.signalLevel, active: !pttDown)
                RxBadge(state: rxState)
            }
            .padding(.top, 8)

            Spacer()

            // Info pills
            HStack(spacing: 8) {
                InfoPill(key: "Offset", value: offset)
                InfoPill(key: "Tone",   value: tone)
                InfoPill(key: "Power",  value: store.txPower)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            // PTT + controls row
            HStack(spacing: 24) {
                PTTButton(isDown: pttDown)
                    .gesture(
                        LongPressGesture(minimumDuration: 0.01)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .updating($pttDown) { _, state, _ in state = true }
                            .onEnded { _ in
                                store.ble.sendDesiredState(
                                    freq: Float(freq) ?? 146.52,
                                    squelch: 0, ptt: false, txAllowed: true,
                                    highPower: store.isHighPower
                                )
                            }
                    )
                    .onChange(of: pttDown) { _, down in
                        store.ble.sendDesiredState(
                            freq: Float(freq) ?? 146.52,
                            squelch: 0, ptt: down, txAllowed: true,
                            highPower: store.isHighPower
                        )
                    }

                VStack(spacing: 16) {
                    VolumeSlider(icon: "speaker.wave.2", value: "14", pct: 0.62)
                    VolumeSlider(icon: "waveform",       value: "SQ 3", pct: 0.34)
                    HStack(spacing: 8) {
                        SmallAction(
                            systemImage: "captions.bubble",
                            label:       "Captions",
                            on:          store.captionsEnabled
                        ) {
                            if store.captionsEnabled {
                                showCaptions = true
                            } else {
                                store.captionsEnabled = true
                                showCaptions = true
                            }
                        }
                        SmallAction(
                            systemImage: "record.circle",
                            label:       "Record",
                            on:          store.isRecording
                        ) {
                            store.isRecording.toggle()
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
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
    var value: String
    var pct: Double

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(t.label2)
                .frame(width: 20)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.meterTrack).frame(height: 5)
                    Capsule().fill(t.label2).frame(width: geo.size.width * pct, height: 5)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 15, height: 15)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .offset(x: geo.size.width * pct - 7.5, y: 0)
                }
            }
            .frame(height: 15)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(t.label2)
                .frame(width: 34, alignment: .trailing)
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

// MARK: - Scan screen

private struct ScanBody: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    var body: some View {
        if store.memories.isEmpty {
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
                        Image(systemName: "barcode.viewfinder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(t.label2)
                        Text("SCANNING")
                            .font(.system(size: 12.5, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(t.label2)
                    }
                    FreqReadout(freq: store.currentFreqString, size: 60)
                    SMeter(level: store.signalLevel)
                }
                .padding(.vertical, 20)

                Text("Scan list · \(store.memories.count) channels")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(t.label2)
                    .textCase(.uppercase)
                    .tracking(0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.memories.enumerated()), id: \.element.id) { idx, mem in
                            HStack(spacing: 12) {
                                Circle()
                                    .fill(t.label3)
                                    .frame(width: 6, height: 6)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mem.name)
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundStyle(t.label)
                                    Text(mem.group)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(t.label2)
                                }
                                Spacer()
                                Text(mem.freqString)
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(t.label2)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 50)
                            if idx < store.memories.count - 1 {
                                Divider().padding(.leading, 34).background(t.sep)
                            }
                        }
                    }
                    .background(t.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                }

                PillButton(label: "Start scan", systemImage: "barcode.viewfinder", filled: true)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
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
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                // Header
                NavHeader(
                    title: "Voice",
                    large: false,
                    leftContent: Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Radio")
                                .font(.system(size: 17))
                        }
                        .foregroundStyle(t.accent)
                    } as (any View),
                    rightContent: HeaderIconBtn(systemImage: "gearshape.fill")
                )

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
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }

                // Bottom actions
                HStack(spacing: 8) {
                    SmallAction(systemImage: "captions.bubble", label: "Captions", on: true)
                    SmallAction(systemImage: "record.circle",   label: "Record")
                    SmallAction(systemImage: "magnifyingglass", label: "Search log")
                    SmallAction(systemImage: "arrow.down.to.line", label: "Save")
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
                .padding(.top, 8)
            }
        }
        .environment(\.theme, store.theme)
    }
}
