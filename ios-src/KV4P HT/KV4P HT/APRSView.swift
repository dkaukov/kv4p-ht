import SwiftUI

// MARK: - APRS Tab

struct APRSView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var selectedEntry: APRSEntry? = nil
    @State private var searchText = ""
    @State private var composeTarget: ComposeTarget?

    private let filters = ["All", "Messages", "Bulletins", "Positions", "Weather"]

    private var filteredEntries: [APRSEntry] {
        var entries: [APRSEntry]
        switch store.aprsFilter {
        case "Messages":  entries = store.aprs.entries.filter { $0.kind == .message }
        case "Bulletins": entries = store.aprs.entries.filter { $0.kind == .bulletin }
        case "Positions": entries = store.aprs.entries.filter { $0.kind == .position || $0.kind == .object }
        case "Weather":   entries = store.aprs.entries.filter { $0.kind == .weather }
        default:          entries = store.aprs.entries
        }
        entries.reverse()  // newest first
        guard !searchText.isEmpty else { return entries }
        let q = searchText.lowercased()
        return entries.filter {
            $0.callsign.lowercased().contains(q) ||
            $0.text.lowercased().contains(q)
        }
    }

    private var canSend: Bool {
        store.ble.bleState == .ready &&
        !store.callsign.trimmingCharacters(in: .whitespaces).isEmpty
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

            // Entry list
            if filteredEntries.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 30))
                        .foregroundStyle(t.label3)
                    Text("No APRS packets yet")
                        .font(.system(size: 15))
                        .foregroundStyle(t.label2)
                    Text("Tune to 144.390 MHz to hear APRS traffic")
                        .font(.system(size: 13))
                        .foregroundStyle(t.label3)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { idx, entry in
                            Button {
                                selectedEntry = entry
                            } label: {
                                APRSRow(entry: entry,
                                        distanceMi: entry.distanceMi(from: store.locationManager.location),
                                        isLast: idx == filteredEntries.count - 1)
                                    .contentShape(Rectangle())
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
        }
        .background(t.bg.ignoresSafeArea())
        .searchable(text: $searchText, prompt: "Callsign or message text")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    composeTarget = ComposeTarget(callsign: "")
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(!canSend)
            }
        }
        .sheet(item: $selectedEntry) { entry in
            NavigationStack {
                APRSDetailView(store: store, entry: entry) { replyTo in
                    selectedEntry = nil
                    composeTarget = ComposeTarget(callsign: replyTo)
                }
            }
            .environment(\.theme, store.theme)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $composeTarget) { target in
            NavigationStack {
                APRSComposeView(store: store, toCallsign: target.callsign)
            }
            .environment(\.theme, store.theme)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }
}

// Identifiable wrapper so the compose sheet is presented with `.sheet(item:)`,
// giving the view fresh identity per presentation — without this the compose
// view's @State recipient is seeded only once and Reply never pre-fills.
private struct ComposeTarget: Identifiable {
    let id = UUID()
    var callsign: String
}

// MARK: - APRS Row

struct APRSRow: View {
    @Environment(\.theme) var t
    var entry: APRSEntry
    var distanceMi: Double?
    var isLast: Bool

    private var kindColor: Color {
        if entry.isOutgoing { return t.accent }
        switch entry.kind {
        case .message:  return t.accent
        case .bulletin: return t.amber
        case .weather:  return t.green
        default:        return t.label2
        }
    }

    private var kindIcon: String {
        switch entry.kind {
        case .message:  return entry.isOutgoing ? "arrow.up.message" : "message"
        case .bulletin: return "info.circle"
        case .weather:  return "cloud.sun"
        case .object:   return "mappin.circle"
        default:        return entry.isOutgoing ? "paperplane" : "location"
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
                        Text(entry.isOutgoing && entry.kind == .message ? "→ \(entry.callsign)" : entry.callsign)
                            .font(.system(size: 14.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(t.label)
                        if entry.isOutgoing && entry.kind == .message {
                            Image(systemName: entry.wasAcknowledged
                                  ? "checkmark.circle.fill"
                                  : entry.isUndelivered
                                  ? "exclamationmark.circle"
                                  : entry.heardViaDigi != nil
                                  ? "dot.radiowaves.up.forward" : "clock")
                                .font(.system(size: 12))
                                .foregroundStyle(entry.wasAcknowledged
                                                 ? t.green
                                                 : entry.isUndelivered
                                                 ? t.red
                                                 : entry.heardViaDigi != nil
                                                 ? t.accent : t.label3)
                        } else if entry.isOutgoing, entry.heardViaDigi != nil {
                            Image(systemName: "dot.radiowaves.up.forward")
                                .font(.system(size: 12))
                                .foregroundStyle(t.accent)
                        }
                        Spacer()
                        Text(entry.time)
                            .font(.system(size: 12.5))
                            .foregroundStyle(t.label2)
                    }
                    if !entry.text.isEmpty {
                        Text(entry.text)
                            .font(.system(size: 14.5))
                            .lineSpacing(3)
                            .foregroundStyle(t.label2)
                            .lineLimit(2)
                            .padding(.top, 1)
                    }
                    HStack(spacing: 8) {
                        if entry.isOutgoing {
                            Text("Sent")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(t.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Text(entry.kind.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(kindColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(kindColor.opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        if let dist = distanceMi {
                            Text(String(format: "%.1f mi", dist))
                                .font(.system(size: 11.5))
                                .foregroundStyle(t.label3)
                        }
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
    @Bindable var store: RadioStore
    var entry: APRSEntry
    var onReply: (String) -> Void

    private var canReply: Bool {
        !entry.isOutgoing &&
        (entry.kind == .message || entry.kind == .bulletin) &&
        store.ble.bleState == .ready &&
        !store.callsign.trimmingCharacters(in: .whitespaces).isEmpty
    }

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
                Text(entry.callsign)
                    .font(.system(size: 22, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.label)
                HStack(spacing: 4) {
                    Text("Heard \(entry.time)")
                    if let dist = entry.distanceMi(from: store.locationManager.location) {
                        Text("· \(String(format: "%.1f", dist)) mi")
                    }
                }
                .font(.system(size: 14))
                .foregroundStyle(t.label2)
            }
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 4) {
                    ListGroupView(header: entry.kind.label) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.kind.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(t.accent)
                                if entry.isOutgoing && entry.kind == .message {
                                    Text(entry.wasAcknowledged ? "Acknowledged"
                                         : entry.isUndelivered ? "Undelivered"
                                         : "Awaiting ack · retry \(entry.retryCount)/\(APRSController.maxRetries)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(entry.wasAcknowledged ? t.green
                                                         : entry.isUndelivered ? t.red : t.label3)
                                }
                                if entry.isOutgoing, let digi = entry.heardViaDigi {
                                    Text("Heard via \(digi)")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(t.green)
                                }
                                Spacer()
                                Text(entry.time)
                                    .font(.system(size: 12))
                                    .foregroundStyle(t.label2)
                            }
                            Text(entry.text.isEmpty ? "(no text)" : entry.text)
                                .font(.system(size: 14.5))
                                .lineSpacing(3)
                                .foregroundStyle(t.label)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                    }

                    if let lat = entry.lat, let lon = entry.lon {
                        ListGroupView(header: "Position") {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(String(format: "%.5f, %.5f", lat, lon))
                                    .font(.system(size: 14.5, design: .monospaced))
                                    .foregroundStyle(t.label)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                        }
                    }

                    if canReply {
                        Button {
                            onReply(entry.fromCallsign)
                        } label: {
                            HStack {
                                Image(systemName: "arrowshape.turn.up.left")
                                Text("Reply")
                            }
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(t.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .background(t.bg.ignoresSafeArea())
        .navigationTitle(entry.callsign)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Compose

struct APRSComposeView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var store: RadioStore
    @State var toCallsign: String
    @State private var messageText = ""
    @State private var sendFailed = false

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespaces).isEmpty &&
        store.ble.bleState == .ready &&
        !store.callsign.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 4) {
            ListGroupView(footer: "Leave the recipient blank to send a CQ bulletin. Messages are sent on the current frequency.") {
                TextFieldRow(title: "To", text: $toCallsign,
                             placeholder: "Callsign (optional)", isLast: false, autocap: .characters)
                TextFieldRow(title: "Message", text: $messageText,
                             placeholder: "Max 67 characters", isLast: true)
            }

            Button {
                if store.aprs.sendMessage(to: toCallsign, text: messageText) {
                    dismiss()
                } else {
                    sendFailed = true
                }
            } label: {
                HStack {
                    Image(systemName: "paperplane.fill")
                    Text("Send")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(canSend ? t.accent : t.fill)
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .disabled(!canSend)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if sendFailed {
                Text("Couldn't send — check connection and callsign.")
                    .font(.system(size: 13))
                    .foregroundStyle(t.red)
            }

            Spacer()
        }
        .padding(.top, 8)
        .background(t.bg.ignoresSafeArea())
        .navigationTitle("New Message")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
        }
    }
}
