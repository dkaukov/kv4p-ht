import Foundation
import CoreLocation

// MARK: - APRS entry model

enum APRSPacketKind: String, Codable {
    case message, bulletin, weather, position, object, raw
    var label: String {
        switch self {
        case .message:  return "Message"
        case .bulletin: return "Bulletin"
        case .weather:  return "Weather"
        case .position: return "Position"
        case .object:   return "Object"
        case .raw:      return "Other"
        }
    }
}

struct APRSEntry: Identifiable, Codable {
    var id = UUID()
    var fromCallsign: String
    var toCallsign: String
    var kind: APRSPacketKind
    var text: String
    var timestamp: Date
    var lat: Double?
    var lon: Double?
    var symbolTable: String?
    var symbolCode: String?
    var objName: String?
    var msgNum: String?
    var wasAcknowledged: Bool = false
    var isOutgoing: Bool = false
    var weather: APRSWeather?

    var callsign: String { isOutgoing && kind == .message ? toCallsign : fromCallsign }

    var time: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(timestamp) ? .none : .short
        return f.string(from: timestamp)
    }

    func distanceMi(from location: CLLocation?) -> Double? {
        guard let lat, let lon, let location else { return nil }
        let meters = location.distance(from: CLLocation(latitude: lat, longitude: lon))
        return meters / 1609.344
    }
}

// MARK: - Controller

@Observable
class APRSController {
    @ObservationIgnored weak var store: RadioStore?

    private static let entriesKey = "aprsEntries"
    private static let msgNumKey = "aprsMessageNumber"
    private static let maxEntries = 500
    private static let dedupeTTL: TimeInterval = 28
    private static let maxMessageNum = 99999

    private var isLoading = true
    var entries: [APRSEntry] = [] {
        didSet { if !isLoading { saveEntries() } }
    }

    @ObservationIgnored private var dedupeCache: [String: Date] = [:]
    @ObservationIgnored private var beaconTimer: Timer?
    @ObservationIgnored private var messageNumber: Int

    init() {
        messageNumber = UserDefaults.standard.object(forKey: Self.msgNumKey) as? Int
            ?? Int.random(in: 0...Self.maxMessageNum)
        if let data = UserDefaults.standard.data(forKey: Self.entriesKey),
           let decoded = try? JSONDecoder().decode([APRSEntry].self, from: data) {
            entries = decoded
        }
        isLoading = false
    }

    private func saveEntries() {
        let snapshot = entries
        DispatchQueue.global(qos: .background).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: Self.entriesKey)
        }
    }

    private func append(_ entry: APRSEntry) {
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
    }

    func clearAll() {
        entries.removeAll()
    }

    // MARK: - My station

    private var myCallsign: AX25Callsign? {
        guard let store, !store.callsign.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        let base = store.callsign.trimmingCharacters(in: .whitespaces).uppercased()
        let ssidDigits = store.aprsSSID.filter(\.isNumber)
        let ssid = UInt8(ssidDigits).map { min($0, 15) } ?? 0
        return AX25Callsign(base: base, ssid: ssid)
    }

    private func isAddressedToMe(_ target: String) -> Bool {
        guard let me = myCallsign else { return false }
        return target == me.display || target == me.base
    }

    // MARK: - RX

    func handleAx25Frame(_ data: Data) {
        guard let frame = AX25Frame(decoding: data) else { return }

        let dedupeKey = frame.source.display + "|" + frame.destination.display + "|"
            + frame.payload.base64EncodedString()
        let now = Date()
        if let then = dedupeCache[dedupeKey], now.timeIntervalSince(then) < Self.dedupeTTL {
            return
        }
        dedupeCache = dedupeCache.filter { now.timeIntervalSince($0.value) < Self.dedupeTTL }
        dedupeCache[dedupeKey] = now

        let info = parseAPRSPayload(frame.payload)
        let from = frame.source.display
        let to = frame.destination.display

        switch info {
        case let .position(lat, lon, table, code, comment, weather):
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: weather != nil ? .weather : .position,
                text: weather?.summary ?? comment,
                timestamp: now, lat: lat, lon: lon,
                symbolTable: String(table), symbolCode: String(code),
                weather: weather))

        case let .message(target, body, msgNum, isAck, isRej):
            if isAck || isRej {
                if isAddressedToMe(target), let num = msgNum {
                    markAcknowledged(msgNum: num, by: from, rejected: isRej)
                }
                return
            }
            let kind: APRSPacketKind = target.hasPrefix("BLN") ? .bulletin : .message
            append(APRSEntry(
                fromCallsign: from, toCallsign: target,
                kind: kind, text: body, timestamp: now, msgNum: msgNum))
            // Auto-ack directed messages that carry a message number.
            if kind == .message, isAddressedToMe(target), let num = msgNum {
                sendAck(to: from, msgNum: num)
            }

        case let .object(name, lat, lon, comment):
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: .object, text: comment.isEmpty ? name : "\(name): \(comment)",
                timestamp: now, lat: lat, lon: lon, objName: name))

        case let .weather(wx, comment):
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: .weather, text: wx.summary.isEmpty ? comment : wx.summary,
                timestamp: now, weather: wx))

        case let .raw(text):
            guard !text.isEmpty else { return }
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: .raw, text: text, timestamp: now))
        }
    }

    private func markAcknowledged(msgNum: String, by callsign: String, rejected: Bool) {
        guard !rejected else { return }
        for i in entries.indices.reversed()
        where entries[i].isOutgoing && entries[i].msgNum == msgNum
            && entries[i].toCallsign == callsign && !entries[i].wasAcknowledged {
            entries[i].wasAcknowledged = true
            return
        }
    }

    // MARK: - TX

    private func canTransmit() -> Bool {
        guard let store else { return false }
        return store.ble.bleState == .ready && myCallsign != nil
    }

    @discardableResult
    private func transmitPayload(_ payload: String) -> Bool {
        guard let store, let me = myCallsign else { return false }
        // Firmware gates AX.25 TX on the global TX_ALLOWED desired-state flag,
        // and other flows (scan, post-HELLO auto state) clear it — refresh first.
        store.sendRadioState(txAllowed: true)
        let frame = AX25Frame(source: me, payload: Data(payload.utf8))
        store.ble.sendAx25Frame(frame.encodedWithoutFCS())
        return true
    }

    private func sendAck(to: String, msgNum: String) {
        guard canTransmit() else { return }
        transmitPayload(messagePayload(to: to, text: "ack" + msgNum, msgNum: nil))
    }

    // Returns true if the message was sent.
    @discardableResult
    func sendMessage(to: String?, text: String) -> Bool {
        guard canTransmit() else { return false }
        let outText = text
            .replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "~", with: " ")
            .replacingOccurrences(of: "{", with: " ")
        let target = (to?.trimmingCharacters(in: .whitespaces).uppercased()).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "BLN1CQ"

        if messageNumber > Self.maxMessageNum { messageNumber = 0 }
        let num = String(messageNumber)
        messageNumber += 1
        UserDefaults.standard.set(messageNumber, forKey: Self.msgNumKey)

        guard transmitPayload(messagePayload(to: target, text: outText, msgNum: num))
        else { return false }
        append(APRSEntry(
            fromCallsign: myCallsign?.display ?? "", toCallsign: target,
            kind: target.hasPrefix("BLN") ? .bulletin : .message,
            text: outText, timestamp: Date(), msgNum: num, isOutgoing: true))
        return true
    }

    // MARK: - Position beacon

    enum BeaconResult {
        case sent, noLocation, notReady
    }

    func sendPositionBeacon() async -> BeaconResult {
        guard let store, canTransmit() else { return .notReady }
        guard let location = store.locationManager.location else {
            store.locationManager.requestLocation()
            return .noLocation
        }
        var lat = location.coordinate.latitude
        var lon = location.coordinate.longitude
        if store.aprsPositionApprox {
            lat = (lat * 100).rounded() / 100
            lon = (lon * 100).rounded() / 100
        }
        let symbol = store.aprsSymbol.first ?? "["
        let payload = "=" + compressedPositionString(lat: lat, lon: lon, symbolCode: symbol)

        let beaconFreq = Float(store.aprsBeaconFrequency)
        if let freq = beaconFreq, store.aprsBeaconFrequency != "Current" {
            // Frequency-switch beacon: tune, settle, send, wait out TX, restore.
            let originalFreq = store.currentFreq
            store.sendRadioState(freq: freq, txAllowed: true)
            try? await Task.sleep(for: .milliseconds(500))
            transmitPayload(payload)
            try? await Task.sleep(for: .seconds(4))
            store.sendRadioState(freq: originalFreq)
        } else {
            transmitPayload(payload)
        }

        append(APRSEntry(
            fromCallsign: myCallsign?.display ?? "", toCallsign: KV4P_HT_VENDOR_TOCALL,
            kind: .position, text: "Position beacon",
            timestamp: Date(), lat: lat, lon: lon,
            symbolTable: "/", symbolCode: String(symbol), isOutgoing: true))
        return .sent
    }

    // MARK: - Beacon timer

    func updateBeaconTimer() {
        beaconTimer?.invalidate()
        beaconTimer = nil
        guard let store, store.aprsBeaconEnabled else { return }
        let interval = TimeInterval(max(1, store.aprsBeaconIntervalMin)) * 60
        beaconTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let store = self.store,
                      store.aprsBeaconEnabled, !store.isScanning else { return }
                _ = await self.sendPositionBeacon()
            }
        }
    }
}
