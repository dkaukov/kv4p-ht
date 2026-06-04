import SwiftUI

// MARK: - Memories Tab

struct MemoriesView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var showRepeaters = false
    @State private var showAddMemory = false

    private var groupedMemories: [(name: String, items: [Memory])] {
        let groups = Dictionary(grouping: store.memories, by: \.group)
        return groups.sorted { $0.key < $1.key }.map { (name: $0.key, items: $0.value) }
    }

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                NavHeader(
                    title: "Memories",
                    rightContent: HStack(spacing: 8) {
                        HeaderIconBtn(systemImage: "magnifyingglass")
                        HeaderIconBtn(systemImage: "plus") { showAddMemory = true }
                        HeaderIconBtn(systemImage: "antenna.radiowaves.left.and.right") { showRepeaters = true }
                    } as (any View)
                )

                ScrollView {
                    LazyVStack(spacing: 4, pinnedViews: []) {
                        ForEach(groupedMemories, id: \.name) { group in
                            ListGroupView(header: "\(group.name) · \(group.items.count)") {
                                ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, mem in
                                    MemoryRow(memory: mem, channelNum: idx + 1, groupColor: t.accent, isLast: idx == group.items.count - 1)
                                }
                            }
                        }

                        Text("Drag to reorder · swipe to delete · long-press to set as scan channel.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(t.label2)
                            .lineSpacing(3)
                            .padding(.horizontal, 24)
                            .padding(.top, 10)
                            .padding(.bottom, 16)
                    }
                }
            }
        }
        .sheet(isPresented: $showRepeaters) {
            RepeaterBrowserView(store: store)
                .environment(\.theme, store.theme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAddMemory) {
            AddMemoryView(store: store)
                .environment(\.theme, store.theme)
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

    var body: some View {
        ListRow(
            title: memory.name,
            subtitle: memory.metaString,
            value: memory.freqString,
            valueColor: t.label,
            leading: VStack {
                Text("CH\(channelNum)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.3)
                    .foregroundStyle(groupColor)
            }
            .frame(width: 38) as (any View),
            showChevron: true,
            isLast: isLast
        )
    }
}

// MARK: - Repeater Browser

struct RepeaterBrowserView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                NavHeader(
                    title: "Repeaters",
                    subtitle: "Auto-configured from RepeaterBook",
                    rightContent: HeaderIconBtn(systemImage: "magnifyingglass")
                )

                // Location + band filter
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(t.accent)
                        Text("Durham, NC")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(t.label)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 38)
                    .padding(.horizontal, 12)
                    .background(t.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 11))

                    HStack(spacing: 6) {
                        Text("2 m")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(t.label)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(t.label2)
                    }
                    .frame(height: 38)
                    .padding(.horizontal, 14)
                    .background(t.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                // Repeater list
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
                                            store.ble.sendDesiredState(
                                                freq: rep.freq,
                                                squelch: 2
                                            )
                                        }
                                    } label: {
                                        Image(systemName: isActive ? "checkmark" : "bolt.fill")
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(isActive ? .white : t.accent)
                                            .frame(width: 30, height: 30)
                                            .background(isActive ? t.accent : t.fill)
                                            .clipShape(Circle())
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 64)
                            if idx < store.repeaters.count - 1 {
                                Divider().padding(.leading, 16).background(t.sep)
                            }
                        }
                    }
                    .background(t.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }

                Text("Tap ")
                + Text(Image(systemName: "bolt.fill")).font(.system(size: 12))
                + Text(" to instantly load frequency, offset and tone. Saved repeaters appear in Memories.")
            }
            .font(.system(size: 12.5))
            .foregroundStyle(t.label2)
            .lineSpacing(3)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Add Memory sheet

struct AddMemoryView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore

    @State private var name = "TV Hill"
    @State private var group = "Durham"
    @State private var freqText = "145.450"
    @State private var offsetText = "-0.600"
    @State private var toneValue: Float = 88.5
    @State private var power = "5 W"
    @State private var bwWide = true

    private let tones: [Float] = [0, 67.0, 71.9, 74.4, 77.0, 79.7, 82.5, 85.4, 88.5, 91.5, 94.8, 97.4, 100.0, 103.5, 107.2, 110.9, 114.8, 118.8, 123.0, 127.3, 131.8, 136.5, 141.3, 146.2, 151.4, 156.7, 162.2, 167.9, 173.8, 179.9, 186.2, 192.8, 203.5]

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Button("Cancel") { dismiss() }
                        .font(.system(size: 17))
                        .foregroundStyle(t.accent)
                    Spacer()
                    Text("New Memory")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(t.label)
                    Spacer()
                    Button("Save") {
                        let freq = Float(freqText) ?? 145.450
                        let offset = Float(offsetText) ?? -0.600
                        store.memories.append(Memory(
                            name: name, group: group, freq: freq, offset: offset,
                            plTone: toneValue, squelch: 2,
                            isRepeater: offset != 0
                        ))
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
                            StepperRow(
                                label: "Power",
                                valueText: power,
                                onDecrement: {},
                                onIncrement: {}
                            )
                            FieldRow(
                                label: "Bandwidth",
                                value: .constant(bwWide ? "Wide · 25 kHz" : "Narrow · 12.5 kHz"),
                                isLast: true
                            )
                        }

                        // Auto-fill button
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(t.accent)
                            Text("Auto-fill from RepeaterBook")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(t.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(t.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 16)
                    }
                }
            }
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
