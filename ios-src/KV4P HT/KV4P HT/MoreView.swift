import SwiftUI

// MARK: - More Tab

struct MoreView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var showSettings = false
    @State private var showRecordings = false

    private struct Tile { var icon: String; var label: String; var color: String }
    private let tiles: [Tile] = [
        Tile(icon: "record.circle",      label: "Recordings",    color: "red"),
        Tile(icon: "captions.bubble",    label: "Transcript log", color: "accent"),
        Tile(icon: "cpu",                label: "Auto-config",    color: "green"),
        Tile(icon: "barcode.viewfinder", label: "Scan lists",     color: "amber"),
    ]

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                NavHeader(title: "More")

                ScrollView {
                    VStack(spacing: 4) {
                        // 2×2 tile grid
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                            ForEach(tiles.indices, id: \.self) { i in
                                let tile = tiles[i]
                                Button {
                                    if tile.label == "Recordings"    { showRecordings = true }
                                    if tile.label == "Transcript log" { /* nav */ }
                                } label: {
                                    MoreTile(
                                    icon: tile.icon,
                                    label: tile.label,
                                    color: tileColor(tile.color),
                                    badge: tile.label == "Recordings" && !store.recordings.isEmpty
                                        ? "\(store.recordings.count)" : nil
                                )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)

                        // Radio rows
                        ListGroupView {
                            ListRow(
                                title: "Device & firmware",
                                value: store.ble.hello.map { "v\($0.firmwareVersion)" } ?? "–",
                                leading: IconTile(color: t.accent, systemImage: "antenna.radiowaves.left.and.right") as (any View),
                                isLast: false
                            )
                            ListRow(
                                title: "My position & beacon",
                                value: "Off",
                                leading: IconTile(color: t.green, systemImage: "location.fill") as (any View),
                                isLast: false
                            )
                            ListRow(
                                title: "Band plan & limits",
                                leading: IconTile(color: Color(hex: "8E8E93"), systemImage: "info.circle") as (any View),
                                isLast: true
                            )
                        }

                        // Settings / About rows
                        ListGroupView {
                            Button { showSettings = true } label: {
                                ListRow(
                                    title: "Settings",
                                    leading: IconTile(color: Color(hex: "8E8E93"), systemImage: "gearshape.fill") as (any View),
                                    isLast: false
                                )
                            }
                            .buttonStyle(.plain)
                            ListRow(
                                title: "About kv4p HT",
                                leading: IconTile(color: t.accent, systemImage: "info.circle") as (any View),
                                isLast: true
                            )
                        }

                        Text("kv4p HT · Open-source ham radio · GPLv3")
                            .font(.system(size: 12.5))
                            .foregroundStyle(t.label3)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                            .padding(.bottom, 16)
                    }
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
                .environment(\.theme, store.theme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showRecordings) {
            RecordingsView(store: store)
                .environment(\.theme, store.theme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func tileColor(_ name: String) -> Color {
        switch name {
        case "red":    return t.red
        case "green":  return t.green
        case "amber":  return t.amber
        default:       return t.accent
        }
    }
}

// MARK: - More tile

struct MoreTile: View {
    @Environment(\.theme) var t
    var icon: String
    var label: String
    var color: Color
    var badge: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 10) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(color)
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(label)
                    .font(.system(size: 15.5, weight: .semibold))
                    .foregroundStyle(t.label)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(t.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            if let b = badge {
                Text(b)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(minWidth: 20, minHeight: 20)
                    .padding(.horizontal, 6)
                    .background(t.red)
                    .clipShape(Capsule())
                    .padding(.top, 14)
                    .padding(.trailing, 14)
            }
        }
    }
}

// MARK: - Settings view

struct SettingsView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                NavHeader(
                    title: "Settings",
                    large: true,
                    leftContent: Button(action: { dismiss() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                            Text("More")
                                .font(.system(size: 17))
                        }
                        .foregroundStyle(t.accent)
                    } as (any View)
                )

                ScrollView {
                    VStack(spacing: 4) {
                        // Station
                        ListGroupView(header: "Station") {
                            TextFieldRow(title: "Callsign",  text: $store.callsign,  placeholder: "N0CALL", isLast: false)
                            TextFieldRow(title: "APRS SSID", text: $store.aprsSSID,  placeholder: "–9",     isLast: true, autocap: .never)
                        }

                        // Radio
                        ListGroupView(header: "Radio") {
                            SquelchSliderRow()
                            Divider().padding(.leading, 16).background(t.sep)
                            ListRow(title: "TX power", value: store.txPower, isLast: false)
                            ListRow(title: "Band",     value: "2 m · VHF",   isLast: true)
                        }

                        // Audio filters
                        ListGroupView(header: "Audio filters") {
                            ListRow(title: "Pre- & de-emphasis", isLast: false, dense: true,
                                    accessory: KVToggle(isOn: $store.filterPreemphasis) as (any View))
                            ListRow(title: "High-pass", isLast: false, dense: true,
                                    accessory: KVToggle(isOn: $store.filterHighPass) as (any View))
                            ListRow(title: "Low-pass",  isLast: true, dense: true,
                                    accessory: KVToggle(isOn: $store.filterLowPass) as (any View))
                        }

                        // Transcription
                        ListGroupView(
                            header: "Transcription",
                            footer: "Speech is transcribed on-device. Audio never leaves your phone."
                        ) {
                            ListRow(title: "Live captions",     isLast: false, dense: true,
                                    accessory: KVToggle(isOn: $store.liveCaptions) as (any View))
                            ListRow(title: "Save transcripts",  isLast: false, dense: true,
                                    accessory: KVToggle(isOn: $store.saveTranscripts) as (any View))
                            ListRow(title: "Language", value: store.captionLanguage, isLast: true)
                        }

                        // Appearance
                        ListGroupView(header: "Appearance") {
                            VStack(spacing: 0) {
                                Divider().opacity(0)
                                KVSegmented(
                                    options: AppThemeMode.allCases.map(\.label),
                                    value: Binding(
                                        get: { store.themeMode.label },
                                        set: { v in
                                            if let m = AppThemeMode.allCases.first(where: { $0.label == v }) {
                                                store.themeMode = m
                                            }
                                        }
                                    )
                                )
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                Divider().padding(.leading, 16).background(t.sep)
                            }
                            ListRow(title: "Sticky PTT",     isLast: false, dense: true,
                                    accessory: KVToggle(isOn: $store.stickyPTT) as (any View))
                            ListRow(title: "Reduce motion",  isLast: true, dense: true,
                                    accessory: KVToggle(isOn: $store.reduceMotion) as (any View))
                        }
                    }
                    .padding(.bottom, 32)
                }
            }
        }
        .environment(\.theme, store.theme)
    }
}

// MARK: - Squelch slider

private struct SquelchSliderRow: View {
    @Environment(\.theme) var t
    @State private var squelch: Double = 0.3

    var levelLabel: String { "Level \(Int(squelch * 9))" }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Squelch")
                    .font(.system(size: 16.5))
                    .foregroundStyle(t.label)
                Spacer()
                Text(levelLabel)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.meterTrack).frame(height: 5)
                    Capsule().fill(t.accent).frame(width: geo.size.width * squelch, height: 5)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 19, height: 19)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .offset(x: geo.size.width * squelch - 9.5)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in squelch = max(0, min(1, v.location.x / geo.size.width)) }
                )
            }
            .frame(height: 19)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

// MARK: - Recordings view

struct RecordingsView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                NavHeader(
                    title: "Recordings",
                    subtitle: "\(store.recordings.count) clips · auto-record on signal",
                    rightContent: HeaderIconBtn(systemImage: "record.circle", tint: t.red)
                )

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.recordings.enumerated()), id: \.element.id) { idx, rec in
                            RecordingRow(recording: rec, isLast: idx == store.recordings.count - 1)
                        }
                    }
                    .background(t.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }

                HStack(spacing: 4) {
                    Text("Clips with")
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 12))
                    Text("include a searchable transcript.")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(t.label2)
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }
        }
        .environment(\.theme, store.theme)
    }
}

private struct RecordingRow: View {
    @Environment(\.theme) var t
    var recording: Recording
    var isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(recording.isPlaying ? t.accent : t.fill)
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(recording.isPlaying ? .white : t.label)
                        )
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            Text(recording.label)
                                .font(.system(size: 15.5, weight: .semibold))
                                .foregroundStyle(t.label)
                            if recording.hasTranscript {
                                Image(systemName: "captions.bubble")
                                    .font(.system(size: 13))
                                    .foregroundStyle(t.label2)
                            }
                        }
                        HStack(spacing: 0) {
                            Text(recording.callsign)
                                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(t.label2)
                            Text(" · \(recording.freqString) · \(recording.date)")
                                .font(.system(size: 12.5))
                                .foregroundStyle(t.label2)
                        }
                    }
                    Spacer()
                    Text(recording.duration)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(t.label2)
                }

                // Playback waveform (playing only)
                if recording.isPlaying {
                    ZStack(alignment: .leading) {
                        WaveformView(color: t.label2.opacity(0.35), seed: 1)
                        WaveformView(color: t.accent, seed: 1)
                            .mask(
                                GeometryReader { geo in
                                    Rectangle()
                                        .frame(width: geo.size.width * CGFloat(recording.progress))
                                }
                            )
                    }
                    .padding(.leading, 52)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(recording.isPlaying ? t.accentSoft : Color.clear)

            if !isLast {
                Divider().padding(.leading, 66).background(t.sep)
            }
        }
    }
}
