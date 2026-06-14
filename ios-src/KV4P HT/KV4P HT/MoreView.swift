import SwiftUI

// MARK: - More Tab

struct MoreView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var showSettings = false
    @State private var showRecordings = false
    @State private var showDeviceInfo = false
    @State private var showPosition = false
    @State private var showBandPlan = false

    private struct Tile { var icon: String; var label: String; var color: String }
    private let tiles: [Tile] = [
        Tile(icon: "record.circle",      label: "Recordings",      color: "red"),
        Tile(icon: "captions.bubble",    label: "Transcript log", color: "accent"),
        Tile(icon: "cpu",                label: "Auto-config",     color: "green"),
        Tile(icon: "barcode.viewfinder", label: "Scan lists",      color: "amber"),
    ]
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    // 2×2 tile grid
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        ForEach(tiles.indices, id: \.self) { i in
                            let tile = tiles[i]
                            Button {
                                if tile.label == "Recordings" { showRecordings = true }
                            } label: {
                                MoreTile(
                                icon: tile.icon,
                                label: tile.label,
                                color: tileColor(tile.color),
                                badge: "Soon"
                            )
                            }
                            .disabled(true)
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)

                    // Radio rows
                    ListGroupView {
                        Button { showDeviceInfo = true } label: {
                            ListRow(
                                title: "Device & firmware",
                                value: store.ble.hello.map { "v\($0.firmwareVersion)" } ?? "–",
                                leading: IconTile(color: t.accent, systemImage: "antenna.radiowaves.left.and.right") as (any View),
                                isLast: false
                            )
                        }
                        .buttonStyle(.plain)
                        Button { showPosition = true } label: {
                            ListRow(
                                title: "My position & beacon",
                                value: store.aprsBeaconEnabled ? "On" : "Off",
                                leading: IconTile(color: t.green, systemImage: "location.fill") as (any View),
                                isLast: false
                            )
                        }
                        .buttonStyle(.plain)
                        Button { showBandPlan = true } label: {
                            ListRow(
                                title: "Band plan & limits",
                                leading: IconTile(color: Color(hex: "8E8E93"), systemImage: "info.circle") as (any View),
                                isLast: true
                            )
                        }
                        .buttonStyle(.plain)
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
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("More")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showRecordings) {
            NavigationStack {
                RecordingsView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDeviceInfo) {
            NavigationStack {
                DeviceInfoView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPosition) {
            NavigationStack {
                BeaconSettingsView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBandPlan) {
            NavigationStack {
                PlaceholderView(title: "Band Plan & Limits",
                                subtitle: "Band plan configuration and frequency limits coming in a future update.")
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    // Station
                    ListGroupView(header: "Station") {
                        TextFieldRow(title: "Callsign",  text: $store.callsign,  placeholder: "N0CALL", isLast: false)
                        TextFieldRow(title: "APRS SSID", text: $store.aprsSSID,  placeholder: "–9",     isLast: true, autocap: .never)
                    }

                    // Radio
                    ListGroupView(header: "Radio") {
                        SquelchSliderRow(store: store)
                        Divider().padding(.leading, 16).background(t.sep)
                        TXPowerRow(store: store)
                        Divider().padding(.leading, 16).background(t.sep)
                        ListRow(title: "Band",     value: "2 m · VHF",   isLast: true)
                    }

                    // Audio filters
                    ListGroupView(
                        header: "Audio filters",
                        footer: "Controlled by firmware."
                    ) {
                        ListRow(title: "Pre- & de-emphasis", isLast: false, dense: true,
                                accessory: KVToggle(isOn: $store.filterPreemphasis) as (any View))
                        ListRow(title: "High-pass", isLast: false, dense: true,
                                accessory: KVToggle(isOn: $store.filterHighPass) as (any View))
                        ListRow(title: "Low-pass",  isLast: false, dense: true,
                                accessory: KVToggle(isOn: $store.filterLowPass) as (any View))
                        BandwidthRow(store: store)
                    }
                    .onChange(of: store.filterPreemphasis) { _, _ in store.sendRadioState() }
                    .onChange(of: store.filterHighPass)     { _, _ in store.sendRadioState() }
                    .onChange(of: store.filterLowPass)      { _, _ in store.sendRadioState() }

                    // Transcription
                    ListGroupView(
                        header: "Transcription",
                        footer: "On-device speech recognition. No data sent to the cloud."
                    ) {
                        ListRow(title: "Live captions",     isLast: false, dense: true,
                                accessory: KVToggle(isOn: $store.liveCaptions) as (any View))
                        ListRow(title: "Save transcripts",  isLast: false, dense: true,
                                accessory: KVToggle(isOn: $store.saveTranscripts) as (any View))
                            .disabled(true)
                        ListRow(title: "Language", value: store.captionLanguage, isLast: true)
                    }
                    .onChange(of: store.liveCaptions) { _, enabled in
                        if enabled && !store.speechManager.isAuthorized {
                            store.speechManager.requestAuthorization { granted in
                                if !granted { store.liveCaptions = false }
                            }
                        }
                        if enabled {
                            store.speechManager.configure(language: store.captionLanguage)
                        }
                    }

                    // Appearance
                    ListGroupView(header: "Appearance") {
                        VStack(spacing: 0) {
                            Divider().opacity(0)
                            Picker("Appearance", selection: $store.themeMode) {
                                ForEach(AppThemeMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
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
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("More")
                            .font(.system(size: 17))
                    }
                }
            }
        }
        .environment(\.theme, store.theme)
    }
}

// MARK: - TX power picker

private struct TXPowerRow: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    private let options = ["1 W", "5 W"]

    var body: some View {
        HStack {
            Text("TX power")
                .font(.system(size: 16.5, weight: .medium))
                .foregroundStyle(t.label)
            Spacer()
            Picker("TX power", selection: $store.txPower) {
                ForEach(options, id: \.self) { opt in
                    Text(opt).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 140)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .onChange(of: store.txPower) { _, _ in
            store.sendRadioState()
        }
    }
}

// MARK: - Bandwidth picker

private struct BandwidthRow: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    private var bwBinding: Binding<String> {
        Binding(
            get: { store.bandwidth == 0 ? "Wide" : "Narrow" },
            set: { store.bandwidth = $0 == "Wide" ? 0 : 1 }
        )
    }

    var body: some View {
        HStack {
            Text("Bandwidth")
                .font(.system(size: 16.5, weight: .medium))
                .foregroundStyle(t.label)
            Spacer()
            Picker("Bandwidth", selection: bwBinding) {
                Text("Wide").tag("Wide")
                Text("Narrow").tag("Narrow")
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
        .onChange(of: store.bandwidth) { _, _ in
            store.sendRadioState()
        }
    }
}

// MARK: - Squelch slider

private struct SquelchSliderRow: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore

    private var squelchPct: Double { Double(store.squelch) / 9.0 }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Squelch")
                    .font(.system(size: 16.5))
                    .foregroundStyle(t.label)
                Spacer()
                Text("Level \(store.squelch)")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label2)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(t.meterTrack).frame(height: 5)
                    Capsule().fill(t.accent).frame(width: geo.size.width * squelchPct, height: 5)
                    Circle()
                        .fill(Color.white)
                        .frame(width: 19, height: 19)
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .offset(x: geo.size.width * squelchPct - 9.5)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let pct = max(0, min(1, v.location.x / geo.size.width))
                            store.squelch = UInt8(round(pct * 9.0))
                        }
                        .onEnded { _ in
                            store.sendRadioState()
                        }
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
        VStack(spacing: 0) {
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
                Text("Recording is a preview — coming in a future update.")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(t.label3)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("Recordings")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HeaderIconBtn(systemImage: "record.circle", tint: t.red)
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

// MARK: - Device Info stub

struct DeviceInfoView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    if let hello = store.ble.hello {
                        ListGroupView(header: "Hello Frame") {
                            DeviceDetailRow(label: "Firmware", value: "v\(hello.firmwareVersion)", isLast: false)
                            DeviceDetailRow(label: "Radio Module", value: hello.radioModuleFound ? "Found" : "Not found", isLast: false)
                            DeviceDetailRow(label: "RF Module", value: hello.rfModuleType == 0 ? "VHF" : "UHF", isLast: false)
                            DeviceDetailRow(label: "Freq Range", value: "\(String(format: "%.1f", hello.minFreq))–\(String(format: "%.1f", hello.maxFreq)) MHz", isLast: false)
                            DeviceDetailRow(label: "Features", value: "0x\(String(hello.features, radix: 16))", isLast: true)
                        }
                    } else {
                        ListGroupView(header: "Hello Frame") {
                            Text("No device connected")
                                .font(.system(size: 15))
                                .foregroundStyle(t.label2)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 11)
                        }
                    }
                }
                .padding(.bottom, 32)
            }
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle("Device & Firmware")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("More")
                            .font(.system(size: 17))
                    }
                }
            }
        }
        .environment(\.theme, store.theme)
    }
}

// MARK: - Beacon settings

struct BeaconSettingsView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    @State private var beaconStatus: String? = nil

    // Curated APRS symbols (table "/"), mirroring Android's APRSIconType subset.
    private static let symbols: [(code: String, label: String)] = [
        ("[", "Person"), ("-", "House"), (">", "Car"), ("b", "Bicycle"),
        ("v", "Van"), ("k", "Truck"), ("Y", "Sailboat"), ("$", "Phone"),
    ]

    private let intervals = [5, 10, 15, 30, 60]
    private let frequencies = ["Current", "144.390"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 4) {
                    ListGroupView(
                        header: "Position beacon",
                        footer: "Periodically transmits your GPS position via APRS. Requires a callsign in Settings. Beaconing only runs while the app is open."
                    ) {
                        ListRow(title: "Beacon position", isLast: false, dense: true,
                                accessory: KVToggle(isOn: $store.aprsBeaconEnabled) as (any View))
                        PickerRow(title: "Interval",
                                  selection: Binding(
                                      get: { "\(store.aprsBeaconIntervalMin) min" },
                                      set: { store.aprsBeaconIntervalMin = Int($0.dropLast(4)) ?? 15 }),
                                  options: intervals.map { "\($0) min" },
                                  isLast: false)
                        PickerRow(title: "Frequency",
                                  selection: $store.aprsBeaconFrequency,
                                  options: frequencies,
                                  isLast: false)
                        ListRow(title: "Approximate position", isLast: true, dense: true,
                                accessory: KVToggle(isOn: $store.aprsPositionApprox) as (any View))
                    }

                    ListGroupView(header: "Map symbol") {
                        PickerRow(title: "Symbol",
                                  selection: Binding(
                                      get: {
                                          Self.symbols.first { $0.code == store.aprsSymbol }?.label
                                              ?? Self.symbols[0].label
                                      },
                                      set: { label in
                                          store.aprsSymbol = Self.symbols.first { $0.label == label }?.code ?? "["
                                      }),
                                  options: Self.symbols.map(\.label),
                                  isLast: true)
                    }

                    Button {
                        beaconStatus = "Sending…"
                        Task {
                            let result = await store.aprs.sendPositionBeacon()
                            switch result {
                            case .sent:       beaconStatus = "Beacon sent"
                            case .noLocation: beaconStatus = "Waiting for GPS fix — try again"
                            case .notReady:   beaconStatus = "Not connected or no callsign set"
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text("Beacon now")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(t.green)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    if let status = beaconStatus {
                        Text(status)
                            .font(.system(size: 13))
                            .foregroundStyle(t.label2)
                            .padding(.top, 4)
                    }
                }
                .padding(.bottom, 32)
            }
        }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Position & Beacon")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("More")
                            .font(.system(size: 17))
                    }
                }
            }
        }
        .environment(\.theme, store.theme)
    }
}

private struct PickerRow: View {
    @Environment(\.theme) var t
    var title: String
    @Binding var selection: String
    var options: [String]
    var isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 16.5, weight: .medium))
                    .foregroundStyle(t.label)
                Spacer()
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(t.label2)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            if !isLast {
                Divider().padding(.leading, 16).background(t.sep)
            }
        }
    }
}

// MARK: - Placeholder stub

struct PlaceholderView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    var title: String
    var subtitle: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "clock")
                    .font(.system(size: 36))
                    .foregroundStyle(t.label3)
                Text(subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(t.label2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            Spacer()
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { dismiss() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                        Text("More")
                            .font(.system(size: 17))
                    }
                }
            }
        }
    }
}

private struct DeviceDetailRow: View {
    @Environment(\.theme) var t
    var label: String
    var value: String
    var isLast: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 15.5))
                    .foregroundStyle(t.label)
                Spacer()
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label2)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            if !isLast {
                Divider().padding(.leading, 16).background(t.sep)
            }
        }
    }
}
