import SwiftUI
import CoreBluetooth

// MARK: - BLE Device Picker

struct DevicePickerView: View {
    @Environment(\.theme) var t
    @Environment(\.dismiss) var dismiss
    @Bindable var ble: BLEManager

    private var stateLabel: String {
        switch ble.bleState {
        case .idle:       return "Ready to scan"
        case .scanning:   return "Scanning…"
        case .connecting: return "Connecting…"
        case .connected:  return "Discovering services…"
        case .ready:      return "Connected"
        }
    }

    private var scanning: Bool { ble.bleState == .scanning }

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button("Cancel") {
                        ble.stopScan()
                        dismiss()
                    }
                    .font(.system(size: 17))
                    .foregroundStyle(t.accent)

                    Spacer()

                    Text("Add Radio")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(t.label)

                    Spacer()

                    Button {
                        ble.stopScan()
                        ble.startScan()
                    } label: {
                        if scanning {
                            ProgressView()
                                .tint(t.accent)
                                .frame(width: 32, height: 32)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(t.accent)
                                .frame(width: 32, height: 32)
                        }
                    }
                    .disabled(ble.bleState == .connecting || ble.bleState == .connected)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                // State banner
                HStack(spacing: 10) {
                    if scanning || ble.bleState == .connecting || ble.bleState == .connected {
                        Circle()
                            .fill(t.amber)
                            .frame(width: 7, height: 7)
                            .shadow(color: t.amber, radius: 3)
                    } else {
                        Circle()
                            .fill(t.label3)
                            .frame(width: 7, height: 7)
                    }
                    Text(stateLabel)
                        .font(.system(size: 14))
                        .foregroundStyle(t.label2)
                    Spacer()
                    if !ble.discoveredDevices.isEmpty {
                        Text("\(ble.discoveredDevices.count) found")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(t.label3)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)

                if ble.bleUnavailable {
                    BLEUnavailableView()
                } else if ble.discoveredDevices.isEmpty && !scanning {
                    // Empty state
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 48, weight: .thin))
                            .foregroundStyle(t.label3)
                        Text("No radios found")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(t.label)
                        Text("Make sure kv4p HT is powered on and within range.")
                            .font(.system(size: 14))
                            .foregroundStyle(t.label2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Scan for Radios") {
                            ble.startScan()
                        }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(t.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 40)
                        .padding(.top, 8)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(ble.discoveredDevices.enumerated()), id: \.element.id) { idx, device in
                                DeviceRow(
                                    device: device,
                                    isConnecting: ble.bleState == .connecting || ble.bleState == .connected,
                                    isLast: idx == ble.discoveredDevices.count - 1
                                ) {
                                    ble.stopScan()
                                    ble.connect(device)
                                }
                            }
                        }
                        .background(t.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                    }
                }

                // Disconnect row (when already connected)
                if ble.bleState == .ready || ble.bleState == .connected {
                    Button {
                        ble.disconnect()
                    } label: {
                        Text("Disconnect")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(t.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(t.redSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            if ble.bleState == .idle { ble.startScan() }
        }
        .onChange(of: ble.bleState) { _, state in
            if state == .ready { dismiss() }
        }
    }
}

// MARK: - Device row

private struct DeviceRow: View {
    @Environment(\.theme) var t
    var device: DiscoveredDevice
    var isConnecting: Bool
    var isLast: Bool
    var onTap: () -> Void

    private var rssiIcon: String {
        switch device.rssi {
        case ..<(-80): return "wifi.exclamationmark"
        case ..<(-65): return "wifi"
        default:       return "wifi"
        }
    }

    private var rssiColor: Color {
        switch device.rssi {
        case ..<(-80): return t.amber
        case ..<(-65): return t.label2
        default:       return t.green
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(t.accentSoft)
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(t.accent)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 16.5, weight: .semibold))
                            .foregroundStyle(t.label)
                        Text(device.id.uuidString.prefix(8).uppercased())
                            .font(.system(size: 12.5, design: .monospaced))
                            .foregroundStyle(t.label3)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Image(systemName: rssiIcon)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(rssiColor)
                        Text("\(device.rssi) dBm")
                            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(t.label3)
                    }

                    if isConnecting {
                        ProgressView().tint(t.accent)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(t.label3)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 62)
            }
            .buttonStyle(.plain)
            .disabled(isConnecting)

            if !isLast {
                Divider().padding(.leading, 70).background(t.sep)
            }
        }
    }
}

// MARK: - BLE unavailable

private struct BLEUnavailableView: View {
    @Environment(\.theme) var t

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "bluetooth.slash")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(t.red)
            Text("Bluetooth Unavailable")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(t.label)
            Text("Enable Bluetooth in Settings to connect to kv4p HT.")
                .font(.system(size: 14))
                .foregroundStyle(t.label2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
    }
}
