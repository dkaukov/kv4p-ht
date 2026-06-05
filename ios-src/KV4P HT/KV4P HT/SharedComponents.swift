import SwiftUI
import MediaPlayer

// MARK: - Typography helpers

let kvFont  = Font.system(size: 16, weight: .medium, design: .default)
let kvMono  = Font.system(size: 14, weight: .medium, design: .monospaced)

// MARK: - Device strip (hardware connection status)

struct DeviceStrip: View {
    @Environment(\.theme) var t
    var connected: Bool
    var battery: Int? = nil   // nil = no data from device yet
    var label: String = "kv4p HT"
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) { HStack(spacing: 8) {
            Circle()
                .fill(connected ? t.green : t.red)
                .frame(width: 7, height: 7)
                .shadow(color: connected ? t.green : t.red, radius: 3)
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(t.label2)
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(t.label)
            Text(connected ? "Connected" : "Disconnected")
                .font(.system(size: 13))
                .foregroundStyle(t.label2)
            Spacer()
            if let batt = battery {
                BattGlyph(pct: batt)
                Text("\(batt)%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(t.label2)
            }
        }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(t.fill2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
        .buttonStyle(.plain)
    }
}

struct BattGlyph: View {
    @Environment(\.theme) var t
    var pct: Int

    var body: some View {
        let col = pct < 20 ? t.red : t.label2
        Canvas { ctx, size in
            let w: CGFloat = 22
            // Outline
            let outline = Path(roundedRect: CGRect(x: 0.5, y: 0.5, width: w, height: 12), cornerRadius: 3)
            ctx.stroke(outline, with: .color(col.opacity(0.45)), lineWidth: 1)
            // Fill
            let fillW = max(2, (w - 4) * CGFloat(pct) / 100)
            let fill = Path(roundedRect: CGRect(x: 2, y: 2, width: fillW, height: 8), cornerRadius: 1.5)
            ctx.fill(fill, with: .color(col))
            // Nub
            let nub = Path(roundedRect: CGRect(x: w + 1.5, y: 3.5, width: 2.5, height: 5), cornerRadius: 1.2)
            ctx.fill(nub, with: .color(col.opacity(0.45)))
        }
        .frame(width: 26, height: 13)
    }
}

// MARK: - S-Meter

struct SMeter: View {
    @Environment(\.theme) var t
    var level: Int     // 0-9
    var max: Int = 9
    var active: Bool = true
    var rawRSSI: UInt8 = 0
    @State private var showRSSI = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<max, id: \.self) { i in
                let on = active && i < level
                let h: CGFloat = 8 + CGFloat(i) / CGFloat(max - 1) * 18
                let col: Color = i >= 6 ? t.red : i >= 4 ? t.amber : t.green
                RoundedRectangle(cornerRadius: 2)
                    .fill(on ? col : t.meterTrack)
                    .frame(width: 6, height: h)
                    .animation(.easeOut(duration: 0.15), value: on)
            }
            if showRSSI {
                Text("RSSI \(rawRSSI)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.label2)
                    .transition(.opacity)
            }
        }
        .frame(height: 26)
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showRSSI.toggle() }
        }
    }
}

// MARK: - Grouped list components

struct ListGroupView<Content: View>: View {
    @Environment(\.theme) var t
    var header: String? = nil
    var footer: String? = nil
    var inset: Bool = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let h = header {
                Text(h.uppercased())
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(t.label2)
                    .tracking(0.4)
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
                    .padding(.bottom, 7)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(t.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, inset ? 16 : 0)
            if let f = footer {
                Text(f)
                    .font(.system(size: 12.5))
                    .foregroundStyle(t.label2)
                    .padding(.horizontal, 20)
                    .padding(.top, 7)
                    .lineSpacing(3)
            }
        }
    }
}

struct ListRow: View {
    @Environment(\.theme) var t
    var title: String
    var subtitle: String? = nil
    var value: String? = nil
    var valueColor: Color? = nil
    var leading: (any View)? = nil
    var showChevron: Bool = true
    var showDivider: Bool = true
    var isLast: Bool = false
    var dense: Bool = false
    var accessory: (any View)? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let l = leading {
                    AnyView(l).padding(.trailing, 12)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 16.5, weight: .medium))
                        .foregroundStyle(t.label)
                    if let sub = subtitle {
                        Text(sub)
                            .font(.system(size: 13))
                            .foregroundStyle(t.label2)
                    }
                }
                Spacer(minLength: 8)
                if let v = value {
                    Text(v)
                        .font(.system(size: 16))
                        .foregroundStyle(valueColor ?? t.label2)
                        .padding(.trailing, showChevron ? 4 : 0)
                }
                if let a = accessory {
                    AnyView(a)
                } else if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(t.label3)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: dense ? 40 : 46)
            if !isLast {
                Divider()
                    .background(t.sep)
                    .padding(.leading, leading != nil ? 56 : 16)
            }
        }
    }
}

struct IconTile: View {
    var color: Color
    var systemImage: String
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

struct KVToggle: View {
    @Environment(\.theme) var t
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .tint(t.green)
    }
}

// MARK: - Text field row (settings)

struct TextFieldRow: View {
    @Environment(\.theme) var t
    var title: String
    @Binding var text: String
    var placeholder: String = ""
    var isLast: Bool = false
    var autocap: TextInputAutocapitalization = .characters

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 16.5, weight: .medium))
                    .foregroundStyle(t.label)
                Spacer(minLength: 8)
                TextField(placeholder, text: $text)
                    .multilineTextAlignment(.trailing)
                    .font(.system(size: 16))
                    .foregroundStyle(t.label2)
                    .frame(maxWidth: 200)
                    .textInputAutocapitalization(autocap)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 46)
            if !isLast {
                Divider()
                    .background(t.sep)
                    .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Pill button

struct PillButton: View {
    @Environment(\.theme) var t
    var label: String
    var systemImage: String
    var filled: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(filled ? .white : t.label)
                Text(label)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(filled ? .white : t.label)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(filled ? t.accent : t.fill)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }
}

// MARK: - SmallAction button

struct SmallAction: View {
    @Environment(\.theme) var t
    var systemImage: String
    var label: String
    var on: Bool = false
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(on ? t.accent : t.label2)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? t.accent : t.label2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(on ? t.accentSoft : t.fill2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - RX/TX badge

struct RxBadge: View {
    @Environment(\.theme) var t
    var state: RadioRxState

    private var color: Color {
        switch state {
        case .idle: return t.label3
        case .rx:   return t.green
        case .tx:   return t.red
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: state == .idle ? .clear : color, radius: 4)
            Text(state.label)
                .font(.system(size: 12, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(color)
        }
    }
}

// MARK: - Info pill (offset / tone / power)

struct InfoPill: View {
    @Environment(\.theme) var t
    var key: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(t.label2)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(t.label)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(t.surface)
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}

// MARK: - Waveform (recordings)

struct WaveformView: View {
    @Environment(\.theme) var t
    var color: Color
    var seed: Int = 1
    var barCount: Int = 40

    private func barHeight(_ i: Int) -> Double {
        let v = (sin(Double(i) * 0.7 + Double(seed)) * 0.5 + 0.5)
              * (sin(Double(i) * 0.27 + Double(seed) * 2) * 0.4 + 0.6)
        return 0.18 + v * 0.82
    }

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: 2.5, height: geo.size.height * barHeight(i))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 30)
    }
}

// MARK: - Environment key: persistent MPVolumeView

private struct MPVolumeViewKey: EnvironmentKey {
    static let defaultValue: MPVolumeView? = nil
}

extension EnvironmentValues {
    var mpVolumeView: MPVolumeView? {
        get { self[MPVolumeViewKey.self] }
        set { self[MPVolumeViewKey.self] = newValue }
    }
}

struct HeaderIconBtn: View {
    @Environment(\.theme) var t
    var systemImage: String
    var tint: Color? = nil
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(tint ?? t.accent)
                .frame(width: 32, height: 32)
                .background(t.fill2)
                .clipShape(Circle())
        }
    }
}
