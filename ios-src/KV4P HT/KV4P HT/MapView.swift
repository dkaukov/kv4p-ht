import SwiftUI
import MapKit

// MARK: - Map Tab

struct APRSMapView: View {
    @Environment(\.theme) var t
    @Bindable var store: RadioStore
    @State private var position: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 35.994, longitude: -78.898),
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
        ))
    )
    @State private var selectedEntry: APRSEntry? = nil

    // Latest position-bearing entry per station callsign.
    private var stations: [MapStation] {
        var latest: [String: APRSEntry] = [:]
        for entry in store.aprs.entries where entry.lat != nil && entry.lon != nil && !entry.isOutgoing {
            let key = entry.kind == .object ? (entry.objName ?? entry.callsign) : entry.callsign
            if let existing = latest[key], existing.timestamp > entry.timestamp { continue }
            latest[key] = entry
        }
        return latest.map { key, entry in
            let kind: StationKind
            let color: String
            if entry.kind == .weather || entry.weather != nil {
                kind = .weather; color = "green"
            } else if entry.symbolCode == ">" || entry.symbolCode == "k" || entry.symbolCode == "j" {
                kind = .mobile; color = "amber"
            } else {
                kind = .fixed; color = "accent"
            }
            return MapStation(callsign: key, lat: entry.lat!, lon: entry.lon!,
                              kind: kind, color: color, entry: entry)
        }
    }

    var body: some View {
        ZStack {
            Map(position: $position) {
                UserAnnotation()
                ForEach(stations) { station in
                    Annotation(station.callsign, coordinate: station.coordinate) {
                        Button {
                            selectedEntry = station.entry
                        } label: {
                            StationPin(station: station, isSelected: false)
                        }
                        .buttonStyle(.plain)
                        .environment(\.theme, store.theme)
                    }
                }
            }
            .ignoresSafeArea()

            VStack {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "map")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(t.label)
                        Text("APRS Map")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(t.label)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 13))

                    Spacer()

                    HeaderIconBtn(systemImage: "location.fill")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer()

                if stations.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "map")
                            .font(.system(size: 28))
                            .foregroundStyle(t.label2)
                        Text("No station positions heard yet")
                            .font(.system(size: 15))
                            .foregroundStyle(t.label2)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
        .environment(\.theme, store.theme)
        .sheet(item: $selectedEntry) { entry in
            NavigationStack {
                APRSDetailView(store: store, entry: entry) { _ in }
            }
            .environment(\.theme, store.theme)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Map data models

enum StationKind { case fixed, weather, mobile }

struct MapStation: Identifiable {
    var callsign: String
    var lat: Double
    var lon: Double
    var kind: StationKind
    var color: String  // theme token name
    var entry: APRSEntry? = nil

    var id: String { callsign }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

// MARK: - Station pin annotation

struct StationPin: View {
    @Environment(\.theme) var t
    var station: MapStation
    var isSelected: Bool

    private var pinColor: Color {
        switch station.color {
        case "green": return t.green
        case "amber": return t.amber
        case "red":   return t.red
        default:      return t.accent
        }
    }
    private var icon: String {
        switch station.kind {
        case .weather: return "cloud.sun"
        case .mobile:  return "car"
        default:       return "antenna.radiowaves.left.and.right"
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(pinColor)
                Text(station.callsign)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(t.label)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(t.isDark ? Color(hex: "1C1C1E").opacity(0.92) : Color.white.opacity(0.96))
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            )
            Circle()
                .fill(pinColor)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle().stroke(.white, lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
        }
        .scaleEffect(isSelected ? 1.15 : 1.0)
        .animation(.spring(response: 0.2), value: isSelected)
    }
}

// MARK: - Bottom sheet card

struct BottomSheetCard: View {
    @Environment(\.theme) var t
    var station: MapStation
    var totalStations: Int
    var moving: Int

    private var stationColor: Color {
        switch station.color {
        case "green": return t.green
        case "amber": return t.amber
        default:      return t.accent
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 3)
                .fill(t.label3)
                .frame(width: 36, height: 5)
                .padding(.top, 12)
                .padding(.bottom, 12)

            HStack(spacing: 10) {
                Circle()
                    .fill(stationColor.opacity(0.13))
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: station.kind == .mobile ? "car" : "antenna.radiowaves.left.and.right")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(stationColor)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(station.callsign)
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(t.label)
                    Text(station.callsign)
                        .font(.system(size: 13))
                        .foregroundStyle(t.label2)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(t.label2)
                    .frame(width: 34, height: 34)
                    .background(t.fill)
                    .clipShape(Circle())
            }
            .padding(.horizontal, 16)

            Divider()
                .padding(.horizontal, 0)
                .padding(.top, 12)
                .background(t.sep)

            HStack(spacing: 18) {
                StatTile(value: "\(totalStations)", label: "Stations")
                StatTile(value: "\(totalStations)", label: "Within 25mi")
                StatTile(value: "\(moving)", label: "Moving")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(t.hairline, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }
}

struct StatTile: View {
    @Environment(\.theme) var t
    var value: String
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(t.label)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(t.label2)
        }
    }
}
