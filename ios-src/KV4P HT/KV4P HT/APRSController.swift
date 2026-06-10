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
    // Digipeater that repeated our outgoing packet (nil = not heard yet).
    var heardViaDigi: String? = nil
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
    // Digipeats arrive within seconds of TX; window is generous for slow nets.
    private static let heardViaDigiTTL: TimeInterval = 120
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
        let isDuplicate = dedupeCache[dedupeKey].map {
            now.timeIntervalSince($0) < Self.dedupeTTL
        } ?? false
        dedupeCache = dedupeCache.filter { now.timeIntervalSince($0.value) < Self.dedupeTTL }
        dedupeCache[dedupeKey] = now

        let info = parseAPRSPayload(frame.payload)
        let from = frame.source.display
        let to = frame.destination.display

        // Our own packet repeated back by a digipeater — don't show it as a
        // received entry, mark the matching outgoing entry as heard instead.
        if let me = myCallsign, frame.source.display == me.display {
            markHeardViaDigi(info, frame: frame)
            return
        }

        // Duplicates (digipeated copies, sender retries) aren't shown again,
        // but a retry of a directed message means our ack was lost — re-ack.
        if isDuplicate {
            if case let .message(target, _, msgNum, isAck, isRej) = info,
               !isAck, !isRej, !target.hasPrefix("BLN"),
               isAddressedToMe(target), let num = msgNum {
                scheduleAck(to: from, msgNum: num)
            }
            return
        }

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
                scheduleAck(to: from, msgNum: num)
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

    // A digipeated copy of our own packet means we were heard on RF. Mark the
    // newest matching outgoing entry; repeats from further digis are no-ops
    // because already-heard entries are skipped.
    private func markHeardViaDigi(_ info: APRSInfo, frame: AX25Frame) {
        let digi = frame.digipeaters.first(where: \.hasBeenRepeated)?.display
            ?? "digipeater"
        let cutoff = Date().addingTimeInterval(-Self.heardViaDigiTTL)
        for i in entries.indices.reversed() {
            let e = entries[i]
            guard e.isOutgoing, e.heardViaDigi == nil, e.timestamp > cutoff
            else { continue }
            switch info {
            case let .message(target, _, msgNum, _, _):
                guard e.kind == .message || e.kind == .bulletin,
                      callsignsMatch(e.toCallsign, target),
                      msgNum.map { msgNumsMatch(e.msgNum, $0) } ?? (e.msgNum == nil)
                else { continue }
            case .position:
                guard e.kind == .position else { continue }
            default:
                break
            }
            entries[i].heardViaDigi = digi
            return
        }
    }

    private func markAcknowledged(msgNum: String, by callsign: String, rejected: Bool) {
        guard !rejected else { return }
        for i in entries.indices.reversed()
        where entries[i].isOutgoing && !entries[i].wasAcknowledged
            && msgNumsMatch(entries[i].msgNum, msgNum)
            && callsignsMatch(entries[i].toCallsign, callsign) {
            entries[i].wasAcknowledged = true
            return
        }
    }

    // Exact display match, or same base callsign (acks may come back with a
    // different SSID than the one we addressed).
    private func callsignsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        func base(_ s: String) -> Substring { s.split(separator: "-", maxSplits: 1).first ?? Substring(s) }
        return base(a) == base(b)
    }

    // String equality after trimming, or numeric equality ("012" acks "12").
    private func msgNumsMatch(_ a: String?, _ b: String) -> Bool {
        guard let a = a?.trimmingCharacters(in: .whitespaces) else { return false }
        let b = b.trimmingCharacters(in: .whitespaces)
        if a == b { return true }
        if let ai = Int(a), let bi = Int(b) { return ai == bi }
        return false
    }

    // MARK: - TX

    private func canTransmit() -> Bool {
        guard let store else { return false }
        return store.ble.bleState == .ready && myCallsign != nil
    }

    @discardableResult
    private func transmitPayload(_ payload: String) -> Bool {
        guard let store, let me = myCallsign else { return false }
        // Firmware gates AX.25 TX on the TX_ALLOWED desired-state flag, which
        // RadioModuleController keeps set after HELLO — no refresh needed.
        let frame = AX25Frame(source: me, payload: Data(payload.utf8))
        store.ble.sendAx25Frame(frame.encodedWithoutFCS())
        return true
    }

    // Delay before acking (matches Android) so we don't key up while
    // digipeated copies of the message are still on the air.
    private func scheduleAck(to: String, msgNum: String) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.sendAck(to: to, msgNum: msgNum)
        }
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
            store.sendRadioState(freq: freq, simplexOverride: true)
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
