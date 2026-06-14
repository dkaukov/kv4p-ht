import SwiftUI

// MARK: - Memories Tab

struct MemoriesView: View {
    @Environment(\.theme) var t
    let store: RadioStore
    @State private var showRepeaters = false
    @State private var showAddMemory = false
    @State private var editingMemory: Memory? = nil
    @State private var searchText = ""

    private var filteredMemories: [Memory] {
        guard !searchText.isEmpty else { return store.memories }
        let q = searchText.lowercased()
        return store.memories.filter {
            $0.name.lowercased().contains(q) ||
            $0.group.lowercased().contains(q) ||
            $0.freqString.contains(q) ||
            $0.notes.lowercased().contains(q)
        }
    }

    private var groupedMemories: [(name: String, items: [Memory])] {
        let groups = Dictionary(grouping: filteredMemories, by: \.group)
        return groups.sorted { $0.key < $1.key }.map { (name: $0.key, items: $0.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4, pinnedViews: []) {
                    ForEach(groupedMemories, id: \.name) { group in
                        ListGroupView(header: "\(group.name) · \(group.items.count)") {
                            ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, mem in
                                MemoryRow(memory: mem, channelNum: idx + 1, groupColor: t.accent, isLast: idx == group.items.count - 1, isActive: mem.id == store.activeMemoryId, onTap: {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    store.applyMemory(mem)
                                })
                                .contextMenu {
                                    Button {
                                        editingMemory = mem
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    Button(role: .destructive) {
                                        store.deleteMemory(id: mem.id)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
                .background(t.bg.ignoresSafeArea())
        .searchable(text: $searchText, prompt: "Name, group, or frequency")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                HeaderIconBtn(systemImage: "plus") { showAddMemory = true }
                HeaderIconBtn(systemImage: "antenna.radiowaves.left.and.right") { showRepeaters = true }
            }
        }
        .sheet(isPresented: $showRepeaters) {
            NavigationStack {
                RepeaterBrowserView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddMemory) {
            AddMemoryView(store: store)
                .environment(\.theme, store.theme)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingMemory) { mem in
            AddMemoryView(store: store, editing: mem)
                .environment(\.theme, store.theme)
                .preferredColorScheme(store.theme.isDark ? .dark : .light)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Memory row

struct MemoryRow: View {
    @Environment(\.theme) var t
    var memory: Memory
    var channelNum: Int
    var groupColor: Color
    var isLast: Bool
    var isActive: Bool
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Group {
                    if isActive {
                        ZStack {
                            Circle()
                                .fill(groupColor)
                                .frame(width: 24, height: 24)
                            Text("\(channelNum)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(0.3)
                                .foregroundStyle(.white)
                        }
                    } else {
                        Text("CH\(channelNum)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .tracking(0.3)
                            .foregroundStyle(groupColor)
                    }
                }
                .frame(width: 38)
                .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(memory.name)
                            .font(.system(size: 16.5, weight: .medium))
                            .foregroundStyle(isActive ? groupColor : t.label)
                        if isActive {
                            Text("TUNED")
                                .font(.system(size: 10.5, weight: .bold))
                                .tracking(0.4)
                                .foregroundStyle(t.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(t.greenSoft)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    Text(memory.metaString)
                        .font(.system(size: 13))
                        .foregroundStyle(t.label2)
                }

                Spacer(minLength: 8)

                Text(memory.freqString)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isActive ? groupColor : t.label2)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            .background(isActive ? groupColor.opacity(0.08) : Color.clear)

            if !isLast {
                Divider()
                    .padding(.leading, 56)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
    }
}

// MARK: - Repeater Browser

struct RepeaterBrowserView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    @State private var showSaveSheet = false
    @State private var saveGroupName = ""

    private var locationLabel: String {
        if store.locationManager.isLoading { return "Locating…" }
        return store.locationManager.locality ?? "Tap to locate"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    store.locationManager.requestLocation()
                } label: {
                    HStack(spacing: 7) {
                        if store.locationManager.isLoading {
                            ProgressView().tint(t.accent).scaleEffect(0.8)
                        } else {
                            Image(systemName: "location.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(t.accent)
                        }
                        Text(locationLabel)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(t.label)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 38)
                    .padding(.horizontal, 12)
                    .background(t.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)

                Button {
                    store.fetchNearbyRepeaters()
                } label: {
                    HStack(spacing: 6) {
                        if store.repeaterFetchState == .loading {
                            ProgressView().tint(t.accent).scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(t.accent)
                        }
                        Text("Search")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(t.label)
                    }
                    .frame(height: 38)
                    .padding(.horizontal, 14)
                    .background(t.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .disabled(store.locationManager.location == nil || store.repeaterFetchState == .loading)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            // Distance + band controls
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "ruler")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(t.label2)
                    Picker("", selection: $store.repeaterSearchDistance) {
                        Text("10 mi").tag(10)
                        Text("25 mi").tag(25)
                        Text("50 mi").tag(50)
                        Text("100 mi").tag(100)
                    }
                    .pickerStyle(.menu)
                    .tint(t.accent)
                }

                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(t.label2)
                    Picker("", selection: $store.repeaterSearchBand) {
                        Text("2m").tag(4)
                        Text("70cm").tag(16)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            switch store.repeaterFetchState {
            case .idle:
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(t.label3)
                    Text("Find Nearby Repeaters")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(t.label)
                    Text("Allow location access, then tap Search to find repeaters from RepeaterBook.")
                        .font(.system(size: 14))
                        .foregroundStyle(t.label2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }

            case .loading:
                VStack(spacing: 12) {
                    Spacer()
                    ProgressView().tint(t.accent)
                    Text("Searching RepeaterBook…")
                        .font(.system(size: 14))
                        .foregroundStyle(t.label2)
                    Spacer()
                }

            case .empty:
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(t.label3)
                    Text("No Repeaters Found")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(t.label)
                    Text("Try a different location or check your internet connection.")
                        .font(.system(size: 14))
                        .foregroundStyle(t.label2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }

            case .error(let msg):
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 48, weight: .thin))
                        .foregroundStyle(t.amber)
                    Text("Error")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(t.label)
                    Text(msg)
                        .font(.system(size: 14))
                        .foregroundStyle(t.label2)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    Spacer()
                }

            case .loaded:
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(store.repeaters.enumerated()), id: \.element.id) { idx, rep in
                            let isActive = store.activeRepeaterId == rep.id
                            HStack(spacing: 0) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text(rep.name)
                                            .font(.system(size: 16.5, weight: .semibold))
                                            .foregroundStyle(t.label)
                                        if isActive {
                                            Text("TUNED")
                                                .font(.system(size: 10.5, weight: .bold))
                                                .tracking(0.4)
                                                .foregroundStyle(t.green)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 2)
                                                .background(t.greenSoft)
                                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                        }
                                    }
                                    HStack(spacing: 0) {
                                        Text(rep.freqString)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(t.label)
                                        Text(" · \(rep.offsetString) · PL \(String(format: "%.1f", rep.plTone)) · \(rep.callsign)")
                                            .font(.system(size: 13))
                                            .foregroundStyle(t.label2)
                                    }
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 4) {
                                    Text(String(format: "%.1f mi", rep.distanceMi))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(t.label2)
                                    Button {
                                        store.activeRepeaterId = isActive ? nil : rep.id
                                        if !isActive {
                                            store.tune(toRepeater: rep)
                                        }
                                    } label: {
                                        Image(systemName: isActive ? "checkmark" : "bolt.fill")
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(isActive ? t.green : t.accent)
                                            .frame(width: 38, height: 30)
                                            .background(isActive ? t.greenSoft : t.accentSoft)
                                            .clipShape(RoundedRectangle(cornerRadius: 9))
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 56)
                            if idx < store.repeaters.count - 1 {
                                Divider().padding(.leading, 16).background(t.sep)
                            }
                        }
                    }
                    .background(t.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                }

                HStack(spacing: 12) {
                    Text("Tap \(Image(systemName: "bolt.fill")) to tune.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(t.label2)

                    Spacer()

                    Button {
                        saveGroupName = store.locationManager.locality ?? "Repeaters"
                        showSaveSheet = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Save All")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(t.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(t.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("Repeaters")
        .navigationBarTitleDisplayMode(.large)
        .onAppear {
            if store.locationManager.location == nil {
                store.locationManager.requestLocation()
            }
        }
        .onChange(of: store.locationManager.location != nil) { _, hasLocation in
            if hasLocation && store.repeaters.isEmpty {
                store.fetchNearbyRepeaters()
            }
        }
        .alert("Save to Memories", isPresented: $showSaveSheet) {
            TextField("Group name", text: $saveGroupName)
            Button("Save") {
                store.importAllRepeaters(group: saveGroupName)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Save \(store.repeaters.count) repeaters as a memory group.")
        }
    }
}

// MARK: - Add Memory sheet

struct AddMemoryView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    let store: RadioStore
    let editing: Memory?

    @State private var name = ""
    @State private var group = ""
    @State private var freqText = ""
    @State private var offsetText = "0"
    @State private var toneValue: Float = 0
    @State private var scanEnabled = true
    @State private var bwWide = true
    @State private var showRepeaters = false

    init(store: RadioStore, editing: Memory? = nil) {
        self.store = store
        self.editing = editing
        if let m = editing {
            _name = State(initialValue: m.name)
            _group = State(initialValue: m.group)
            _freqText = State(initialValue: m.freqString)
            _offsetText = State(initialValue: m.offset == 0 ? "0" : String(format: "%.3f", m.offset))
            _toneValue = State(initialValue: m.plTone)
            _scanEnabled = State(initialValue: m.scanEnabled)
        }
    }

    private let tones: [Float] = [0, 67.0, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5, 94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3, 131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 162.2, 167.9, 173.8, 179.9, 186.2, 192.8, 203.5]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }
                    .font(.system(size: 17))
                    .foregroundStyle(t.accent)
                Spacer()
                Text(editing == nil ? "New Memory" : "Edit Memory")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(t.label)
                Spacer()
                Button("Save") {
                    guard let freq = Float(freqText), freq > 0 else { return }
                    let offset = Float(offsetText) ?? 0
                    if var updated = editing {
                        updated.name = name
                        updated.group = group
                        updated.freq = freq
                        updated.offset = offset
                        updated.plTone = toneValue
                        updated.isRepeater = offset != 0
                        updated.scanEnabled = scanEnabled
                        store.updateMemory(updated)
                    } else {
                        store.memories.append(Memory(
                            name: name, group: group, freq: freq, offset: offset,
                            plTone: toneValue, squelch: 2,
                            isRepeater: offset != 0, scanEnabled: scanEnabled
                        ))
                    }
                    dismiss()
                }
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(t.accent)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            ScrollView {
                VStack(spacing: 4) {
                    ListGroupView(header: "Identity") {
                        FieldRow(label: "Name",  value: $name)
                        FieldRow(label: "Group", value: $group, isLast: true)
                    }

                    ListGroupView(header: "Frequency") {
                        FieldRow(label: "Frequency", value: $freqText, mono: true)
                        FieldRow(label: "Offset",    value: $offsetText, mono: true)
                        StepperRow(
                            label: "Tone (PL)",
                            valueText: toneValue == 0 ? "Off" : String(format: "%.1f Hz", toneValue),
                            onDecrement: {
                                if let idx = tones.firstIndex(of: toneValue), idx > 0 { toneValue = tones[idx - 1] }
                            },
                            onIncrement: {
                                if let idx = tones.firstIndex(of: toneValue), idx < tones.count - 1 { toneValue = tones[idx + 1] }
                            },
                            isLast: true
                        )
                    }

                    ListGroupView(header: "Transmit") {
                        FieldRow(
                            label: "Bandwidth",
                            value: .constant(bwWide ? "Wide · 25 kHz" : "Narrow · 12.5 kHz"),
                            isLast: true
                        )
                    }

                    ListGroupView(header: "Scan") {
                        ListRow(
                            title: "Include in Scan",
                            isLast: true,
                            accessory: KVToggle(isOn: $scanEnabled) as (any View)
                        )
                    }

                    Button {
                        showRepeaters = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(t.accent)
                            Text("Browse from RepeaterBook")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(t.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(t.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(t.bg.ignoresSafeArea())
        .sheet(isPresented: $showRepeaters) {
            NavigationStack {
                RepeaterBrowserView(store: store)
            }
            .environment(\.theme, store.theme)
            .preferredColorScheme(store.theme.isDark ? .dark : .light)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

private struct FieldRow: View {
    @Environment(\.theme) var t
    var label: String
    @Binding var value: String
    var mono: Bool = false
    var isLast: Bool = false
    var tint: Color? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 16.5))
                    .foregroundStyle(t.label)
                    .frame(width: 110, alignment: .leading)
                Spacer()
                TextField("", text: $value)
                    .font(mono ? .system(size: 16.5, weight: .semibold, design: .monospaced) : .system(size: 16.5, weight: .semibold))
                    .foregroundStyle(tint ?? t.label)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            if !isLast {
                Divider().padding(.leading, 16).background(t.sep)
            }
        }
    }
}

private struct StepperRow: View {
    @Environment(\.theme) var t
    var label: String
    var valueText: String
    var onDecrement: () -> Void
    var onIncrement: () -> Void
    var isLast: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 16.5))
                    .foregroundStyle(t.label)
                Spacer()
                Text(valueText)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label)
                    .padding(.trailing, 12)
                HStack(spacing: 0) {
                    Button(action: onDecrement) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(t.label)
                            .frame(width: 40, height: 30)
                    }
                    Divider().frame(height: 30).background(t.sep)
                    Button(action: onIncrement) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(t.label)
                            .frame(width: 40, height: 30)
                    }
                }
                .background(t.fill)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 50)
            if !isLast {
                Divider().padding(.leading, 16).background(t.sep)
            }
        }
    }
}
