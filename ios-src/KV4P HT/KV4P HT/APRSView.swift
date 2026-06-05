import SwiftUI

// MARK: - APRS Tab

struct APRSView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var selectedPacket: APRSPacket? = nil
    @State private var searchText = ""

    private let filters = ["All", "Messages", "Bulletins", "Weather"]

    private var filteredPackets: [APRSPacket] {
        var packets: [APRSPacket]
        switch store.aprsFilter {
        case "Messages":  packets = store.aprsPackets.filter { $0.kind == .message }
        case "Bulletins": packets = store.aprsPackets.filter { $0.kind == .bulletin }
        case "Weather":   packets = store.aprsPackets.filter { $0.kind == .weather }
        default:          packets = store.aprsPackets
        }
        guard !searchText.isEmpty else { return packets }
        let q = searchText.lowercased()
        return packets.filter {
            $0.callsign.lowercased().contains(q) ||
            $0.text.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filters, id: \.self) { f in
                        let on = f == store.aprsFilter
                        Button(f) { store.aprsFilter = f }
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(on ? .white : t.label)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                            .background(on ? t.accent : t.fill)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 10)

            // Packet list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredPackets.enumerated()), id: \.element.id) { idx, packet in
                        Button {
                            selectedPacket = packet
                        } label: {
                            APRSRow(packet: packet, isLast: idx == filteredPackets.count - 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(t.surface)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
                .background(t.bg.ignoresSafeArea())
        .searchable(text: $searchText, prompt: "Callsign or message text")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                HeaderIconBtn(systemImage: "gearshape.fill")
            }
        }
        .sheet(item: $selectedPacket) { packet in
            NavigationStack {
                APRSDetailView(packet: packet)
            }
            .environment(\.theme, store.theme)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - APRS Row

struct APRSRow: View {
    @Environment(\.theme) var t
    var packet: APRSPacket
    var isLast: Bool

    private var kindColor: Color {
        switch packet.kind {
        case .message:  return t.accent
        case .bulletin: return t.amber
        case .weather:  return t.green
        case .position: return t.label2
        }
    }

    private var kindIcon: String {
        switch packet.kind {
        case .message:  return "message"
        case .bulletin: return "info.circle"
        case .weather:  return "location"
        case .position: return "location"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Circle()
                    .fill(kindColor.opacity(0.13))
                    .frame(width: 38, height: 38)
                    .overlay(
                        Image(systemName: kindIcon)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(kindColor)
                    )
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(packet.callsign)
                            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(t.label)
                        if packet.isNew {
                            Circle().fill(t.accent).frame(width: 7, height: 7)
                        }
                        Spacer()
                        Text(packet.time)
                            .font(.system(size: 12.5))
                            .foregroundStyle(t.label2)
                    }
                    Text(packet.text)
                        .font(.system(size: 14.5))
                        .lineSpacing(3)
                        .foregroundStyle(t.label2)
                        .lineLimit(2)
                        .padding(.top, 1)
                    HStack(spacing: 8) {
                        Text(packet.kind.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(kindColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(kindColor.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Text(String(format: "%.1f mi", packet.distanceMi))
                            .font(.system(size: 11.5))
                            .foregroundStyle(t.label3)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if !isLast {
                Divider().padding(.leading, 66).background(t.sep)
            }
        }
    }
}

// MARK: - APRS Detail

struct APRSDetailView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    var packet: APRSPacket

    var body: some View {
        VStack(spacing: 0) {
            // Station header
            VStack(spacing: 4) {
                Circle()
                    .fill(t.accent.opacity(0.13))
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "message")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(t.accent)
                    )
                Text(packet.callsign)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.label)
                Text("Last heard \(packet.time) · \(String(format: "%.1f", packet.distanceMi)) mi")
                    .font(.system(size: 14))
                    .foregroundStyle(t.label2)
            }
            .padding(.bottom, 16)

            // Packet list
            ScrollView {
                VStack(spacing: 4) {
                    ListGroupView(header: "Message") {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(packet.kind.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(t.accent)
                                Spacer()
                                Text(packet.time)
                                    .font(.system(size: 12))
                                    .foregroundStyle(t.label2)
                            }
                            Text(packet.text)
                                .font(.system(size: 14.5))
                                .lineSpacing(3)
                                .foregroundStyle(t.label)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    }

                    Text("Receive-only in this build. Outbound APRS messaging is planned for a future release.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(t.label2)
                        .lineSpacing(3)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }
                .padding(.bottom, 16)
            }
        }
                .background(t.bg.ignoresSafeArea())
        .navigationTitle(packet.callsign)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HeaderIconBtn(systemImage: "map")
            }
        }
    }
}
