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
    // Retry state for outgoing directed messages (APRS decay algorithm).
    var retryCount: Int = 0
    var nextRetryAt: Date? = nil
    var isOutgoing: Bool = false
    var weather: APRSWeather?

    var callsign: String { isOutgoing && kind == .message ? toCallsign : fromCallsign }

    // A directed message still retrying toward an ack.
    var isAwaitingAck: Bool {
        isOutgoing && kind == .message && !wasAcknowledged && nextRetryAt != nil
    }
    // A directed message that exhausted its retries without an ack.
    var isUndelivered: Bool {
        isOutgoing && kind == .message && !wasAcknowledged
            && nextRetryAt == nil && retryCount >= APRSController.maxRetries
    }

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

    private static let legacyEntriesKey = "aprsEntries"
    private static let msgNumKey = "aprsMessageNumber"
    private static let maxEntries = 500
    // Exact-duplicate suppression for digipeated copies of any packet.
    private static let frameDedupeWindow: TimeInterval = 30
    // Directed-message dedupe/re-ack window. Long and restart-proof: a sender
    // retrying an unacked message minutes later (or after we relaunch) must be
    // re-acked without a duplicate visible entry.
    private static let messageDedupeWindow: TimeInterval = 30 * 60
    private static let frameRetention: TimeInterval = 24 * 60 * 60
    // Digipeats arrive within seconds of TX; window is generous for slow nets.
    private static let heardViaDigiTTL: TimeInterval = 120
    private static let maxMessageNum = 99999

    // APRS decay-algorithm retry for unacked directed messages: first retry 8s
    // after send, doubling each time, capped at the 20-min net cycle time, then
    // give up. See https://www.aprs.org/txt/messages101.txt.
    private static let retryBaseInterval: TimeInterval = 8
    private static let retryIntervalCap: TimeInterval = 20 * 60
    static let maxRetries = 7
    private static let retryTickInterval: TimeInterval = 5

    // Interval before the nth retry (0-based): 8, 16, 32, … capped at the cap.
    static func retryInterval(forAttempt n: Int) -> TimeInterval {
        min(retryBaseInterval * pow(2, Double(n)), retryIntervalCap)
    }

    // State after one retransmission: bump the count, schedule the next retry —
    // or stop (nextRetryAt = nil → undelivered) once the limit is reached.
    static func nextRetryState(retryCount: Int, now: Date)
        -> (retryCount: Int, nextRetryAt: Date?) {
        let attempt = retryCount + 1
        let next = attempt >= maxRetries
            ? nil : now.addingTimeInterval(retryInterval(forAttempt: attempt))
        return (attempt, next)
    }

    var entries: [APRSEntry] = []

    @ObservationIgnored private let persistence: APRSPersistence
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var beaconTimer: Timer?
    @ObservationIgnored private var retryTimer: Timer?
    @ObservationIgnored private var messageNumber: Int

    init(persistence: APRSPersistence = APRSPersistence(),
         defaults: UserDefaults = .standard) {
        self.persistence = persistence
        self.defaults = defaults
        messageNumber = defaults.object(forKey: Self.msgNumKey) as? Int
            ?? Int.random(in: 0...Self.maxMessageNum)
        // One-shot migration of the pre-Core Data UserDefaults history blob.
        if let data = defaults.data(forKey: Self.legacyEntriesKey) {
            persistence.migrateLegacyEntries(data)
            defaults.removeObject(forKey: Self.legacyEntriesKey)
        }
        entries = persistence.loadEntries(max: Self.maxEntries)
        startRetryTimer()
    }

    private func append(_ entry: APRSEntry, frameHash: String? = nil) {
        entries.append(entry)
        persistence.insertEntry(entry, frameHash: frameHash)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            persistence.trimEntries(max: Self.maxEntries)
        }
    }

    func clearAll() {
        entries.removeAll()
        persistence.deleteAllEntries()
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

    // RX pipeline: decode identity → persist the frame → classify → side
    // effects. The persistent frame store, not an in-memory cache, decides
    // what counts as a duplicate, so dedupe and re-ack survive app restarts.
    func handleAx25Frame(_ data: Data) {
        guard let frame = AX25Frame(decoding: data) else { return }

        let now = Date()
        var from = frame.source.display
        var to = frame.destination.display
        var info = parseAPRSPayload(frame.payload)

        // Third-party relayed traffic (} DTI): the real originator is the inner
        // packet's source, not the RF-carrying station. Unwrap so the message
        // shows as from the originator and auto-ack targets them, not the
        // gateway. (Ported from Android Parser.java case '}'.)
        if let tp = Self.unwrapThirdParty(frame.payload) {
            from = tp.source
            to = tp.destination
            info = parseAPRSPayload(tp.info)
        }

        let (frameKind, frameMsgNum) = Self.frameIdentity(of: info)

        // Directed messages get the long window: a sender retry means our ack
        // was lost and we must re-ack, even across an app restart. Everything
        // else (positions, bulletins, acks) only needs digipeat suppression.
        var isDirectedMessage = false
        if case let .message(target, _, msgNum, isAck, isRej) = info,
           !isAck, !isRej, !target.hasPrefix("BLN"), msgNum != nil {
            isDirectedMessage = true
        }
        let window = isDirectedMessage ? Self.messageDedupeWindow : Self.frameDedupeWindow
        let isDuplicate = persistence.recentIncomingFrameExists(
            source: from, payload: frame.payload,
            since: now.addingTimeInterval(-window))

        // Persist before any side effects.
        let frameHash = APRSPersistence.frameHash(of: data)
        persistence.insertFrame(
            direction: "in", raw: data, frameHash: frameHash,
            source: from, destination: to, payload: frame.payload,
            kind: frameKind, msgNum: frameMsgNum, timestamp: now)
        persistence.pruneFrames(olderThan: now.addingTimeInterval(-Self.frameRetention))

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
                weather: weather), frameHash: frameHash)

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
                kind: kind, text: body, timestamp: now, msgNum: msgNum),
                frameHash: frameHash)
            // Auto-ack directed messages that carry a message number.
            if kind == .message, isAddressedToMe(target), let num = msgNum {
                scheduleAck(to: from, msgNum: num)
            }

        case let .object(name, lat, lon, comment):
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: .object, text: comment.isEmpty ? name : "\(name): \(comment)",
                timestamp: now, lat: lat, lon: lon, objName: name), frameHash: frameHash)

        case let .weather(wx, comment):
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: .weather, text: wx.summary.isEmpty ? comment : wx.summary,
                timestamp: now, weather: wx), frameHash: frameHash)

        case let .raw(text):
            guard !text.isEmpty else { return }
            append(APRSEntry(
                fromCallsign: from, toCallsign: to,
                kind: .raw, text: text, timestamp: now), frameHash: frameHash)
        }
    }

    // Minimal parsed identity stored alongside the raw frame.
    private static func frameIdentity(of info: APRSInfo) -> (kind: String?, msgNum: String?) {
        switch info {
        case let .message(_, _, msgNum, isAck, isRej):
            return (isAck ? "ack" : isRej ? "rej" : "message", msgNum)
        case .position: return ("position", nil)
        case .object:   return ("object", nil)
        case .weather:  return ("weather", nil)
        case .raw:      return ("raw", nil)
        }
    }

    // Unwraps a third-party relayed payload (DTI '}') into the inner packet's
    // source callsign, destination (tocall), and info field. Inner wire format
    // is TNC2: "SRC>DEST,PATH:infofield". Returns nil if the payload isn't
    // third-party or is malformed.
    static func unwrapThirdParty(_ payload: Data) -> (source: String, destination: String, info: Data)? {
        guard let text = String(data: payload, encoding: .utf8)
                ?? String(data: payload, encoding: .isoLatin1),
              text.first == "}" else { return nil }
        let inner = text.dropFirst()                       // strip '}'
        guard let gt = inner.firstIndex(of: ">") else { return nil }
        let source = String(inner[inner.startIndex..<gt])
        guard !source.isEmpty else { return nil }
        let afterSource = inner[inner.index(after: gt)...]  // "DEST,PATH:info..."
        guard let colon = afterSource.firstIndex(of: ":") else { return nil }
        let header = afterSource[afterSource.startIndex..<colon]  // "DEST,PATH"
        let dest = header.split(separator: ",").first.map(String.init) ?? ""
        // Drop the TNC2 header/info separator colon; the info field keeps its
        // own DTI (e.g. ':' for a message, '!' for a position).
        let infoStr = String(afterSource[afterSource.index(after: colon)...])
        guard !infoStr.isEmpty, let infoData = infoStr.data(using: .utf8)
        else { return nil }
        // Trailing '*' on a digipeated callsign isn't part of the name.
        let cleanDest = dest.hasSuffix("*") ? String(dest.dropLast()) : dest
        return (source.uppercased(), cleanDest.uppercased(), infoData)
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
            persistence.markEntryHeardViaDigi(id: entries[i].id, digi: digi)
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
            entries[i].nextRetryAt = nil   // stop retrying an acked message
            persistence.markEntryAcknowledged(id: entries[i].id)
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
        let raw = frame.encodedWithoutFCS()
        store.ble.sendAx25Frame(raw)
        let info = parseAPRSPayload(frame.payload)
        let (kind, msgNum) = Self.frameIdentity(of: info)
        persistence.insertFrame(
            direction: "out", raw: raw, frameHash: APRSPersistence.frameHash(of: raw),
            source: me.display, destination: frame.destination.display,
            payload: frame.payload, kind: kind, msgNum: msgNum, timestamp: Date())
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
        defaults.set(messageNumber, forKey: Self.msgNumKey)

        guard transmitPayload(messagePayload(to: target, text: outText, msgNum: num))
        else { return false }
        let kind: APRSPacketKind = target.hasPrefix("BLN") ? .bulletin : .message
        // Directed messages start the decay-algorithm retry clock; bulletins
        // are fire-and-forget (no ack expected).
        let nextRetryAt = kind == .message
            ? Date().addingTimeInterval(Self.retryInterval(forAttempt: 0)) : nil
        append(APRSEntry(
            fromCallsign: myCallsign?.display ?? "", toCallsign: target,
            kind: kind, text: outText, timestamp: Date(), msgNum: num,
            nextRetryAt: nextRetryAt, isOutgoing: true))
        return true
    }

    // MARK: - Message retry (decay algorithm)

    private func startRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(
            withTimeInterval: Self.retryTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.processDueRetries() }
        }
    }

    // Retransmits unacked directed messages whose retry is due. A retry is only
    // consumed when actually sent — if BLE is down the message is left pending
    // and picked up on a later tick (or when reconnect kicks this directly).
    func processDueRetries(now: Date = Date()) {
        guard canTransmit() else { return }
        for i in entries.indices {
            let e = entries[i]
            guard e.isOutgoing, e.kind == .message, !e.wasAcknowledged,
                  let due = e.nextRetryAt, due <= now, let num = e.msgNum
            else { continue }
            transmitPayload(messagePayload(to: e.toCallsign, text: e.text, msgNum: num))
            let s = Self.nextRetryState(retryCount: e.retryCount, now: now)
            entries[i].retryCount = s.retryCount
            entries[i].nextRetryAt = s.nextRetryAt
            persistence.updateEntryRetry(
                id: e.id, retryCount: s.retryCount, nextRetryAt: s.nextRetryAt)
        }
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
