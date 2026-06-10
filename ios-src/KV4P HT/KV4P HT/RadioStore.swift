import Foundation
import SwiftUI
import CoreLocation

// MARK: - Data Models

enum VoiceMode: String, CaseIterable {
    case simplex, repeater, scan
    var label: String {
        switch self {
        case .simplex:  return "Simplex"
        case .repeater: return "Repeater"
        case .scan:     return "Scan"
        }
    }
}

struct Memory: Identifiable, Codable {
    var id = UUID()
    var name: String
    var group: String
    var freq: Float
    var offset: Float      // MHz, 0 = simplex
    var plTone: Float      // Hz, 0 = no tone
    var squelch: UInt8
    var isRepeater: Bool
    var notes: String = ""
    var scanEnabled: Bool = true

    var freqString: String { String(format: "%.3f", freq) }
    var offsetString: String {
        if offset == 0 { return "Simplex" }
        return offset > 0 ? String(format: "+%.3f", offset) : String(format: "%.3f", offset)
    }
    var toneString: String { plTone == 0 ? "Off" : String(format: "PL %.1f", plTone) }
    var metaString: String {
        if isRepeater { return "Repeater · \(offsetString) · \(toneString)" }
        return "Simplex · \(notes.isEmpty ? "Simplex" : notes)"
    }

}

extension Memory {
    // Custom decode so memories saved before scanEnabled existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        group = try c.decode(String.self, forKey: .group)
        freq = try c.decode(Float.self, forKey: .freq)
        offset = try c.decode(Float.self, forKey: .offset)
        plTone = try c.decode(Float.self, forKey: .plTone)
        squelch = try c.decode(UInt8.self, forKey: .squelch)
        isRepeater = try c.decode(Bool.self, forKey: .isRepeater)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        scanEnabled = try c.decodeIfPresent(Bool.self, forKey: .scanEnabled) ?? true
    }
}

struct Repeater: Identifiable {
    let id = UUID()
    var name: String
    var callsign: String
    var freq: Float
    var offset: Float
    var plTone: Float
    var distanceMi: Float
    var location: String

    var freqString: String { String(format: "%.3f", freq) }
    var offsetString: String { offset > 0 ? String(format: "+%.1f", offset) : String(format: "%.1f", offset) }

}

enum APRSPacketKind: String {
    case message, bulletin, weather, position
    var label: String {
        switch self {
        case .message:  return "Message"
        case .bulletin: return "Bulletin"
        case .weather:  return "Weather"
        case .position: return "Position"
        }
    }
}

struct APRSPacket: Identifiable {
    let id = UUID()
    var callsign: String
    var kind: APRSPacketKind
    var text: String
    var time: String
    var distanceMi: Float
    var isNew: Bool = false

}

struct CaptionLine: Identifiable {
    let id = UUID()
    var callsign: String
    var time: String
    var text: String
    var active: Bool = false
}

struct Recording: Identifiable {
    let id = UUID()
    var label: String
    var callsign: String
    var freq: Float
    var duration: String
    var date: String
    var hasTranscript: Bool
    var isPlaying: Bool = false
    var progress: Float = 0

    var freqString: String { String(format: "%.3f", freq) }

}

// MARK: - Radio Store

@Observable
class RadioStore {
    // ── Appearance
    var themeMode: AppThemeMode = .dark
    var theme: AppTheme { AppTheme.forMode(themeMode) }

    // ── BLE
    let ble = BLEManager()

    // ── Location
    let locationManager = LocationManager()
    var repeaterFetchState: RepeaterFetchState = .idle
    var repeaterSearchDistance: Int = 25  // miles
    var repeaterSearchBand: Int = 4      // 4=2m, 16=70cm

    // ── Voice
    var voiceMode: VoiceMode = .simplex
    var squelch: UInt8 = 3
    var captionsEnabled: Bool = false
    var isRecording: Bool = false
    var isScanning: Bool = false
    var scanIndex: Int = 0
    var scanPaused: Bool = false
    @ObservationIgnored private var scanTimer: Timer?

    // ── Memories / Repeaters
    private static let memoriesKey = "savedMemories"
    private var isInitializing = true
    var memories: [Memory] = [] {
        didSet {
            if !isInitializing { saveMemories() }
        }
    }
    var repeaters: [Repeater] = []
    var activeRepeaterId: UUID? = nil

    // ── APRS
    var aprsPackets: [APRSPacket] = []
    var aprsFilter: String = "All"
    var selectedPacket: APRSPacket? = nil

    // ── Recordings
    var recordings: [Recording] = []

    // ── Captions
    var captionLines: [CaptionLine] = []
    let speechManager = SpeechManager()
    @ObservationIgnored private var wasSquelched = true

    // ── Settings
    var callsign: String = ""
    var aprsSSID: String = ""
    var txPower: String = "1 W"
    var filterPreemphasis: Bool = true
    var filterHighPass: Bool = true
    var filterLowPass: Bool = false
    var liveCaptions: Bool = true
    var saveTranscripts: Bool = true
    var stickyPTT: Bool = false
    var bandwidth: UInt8 = 0  // 0=wide 25kHz, 1=narrow 12.5kHz
    var reduceMotion: Bool = false
    var captionLanguage: String = "English (US)"

    // ── Init
    init() {
        if let data = UserDefaults.standard.data(forKey: Self.memoriesKey),
           let decoded = try? JSONDecoder().decode([Memory].self, from: data) {
            memories = decoded
        } else {
            memories = [
                Memory(name: "Simplex", group: "Calling", freq: 146.52,
                       offset: 0, plTone: 0, squelch: 2,
                       isRepeater: false, notes: "National calling frequency")
            ]
        }
        isInitializing = false
        configureSpeechManager()
    }

    private func configureSpeechManager() {
        speechManager.configure(language: captionLanguage)

        speechManager.onPartialResult = { [weak self] text in
            guard let self else { return }
            if let idx = self.captionLines.lastIndex(where: { $0.active }) {
                self.captionLines[idx].text = text
            }
        }

        speechManager.onSegmentFinalized = { [weak self] in
            guard let self else { return }
            for i in self.captionLines.indices where self.captionLines[i].active {
                self.captionLines[i].active = false
            }
            self.captionLines.removeAll { $0.text.isEmpty && !$0.active }
            if self.captionLines.count > 100 {
                self.captionLines.removeFirst(self.captionLines.count - 100)
            }
        }

        speechManager.onRollingRestart = { [weak self] in
            self?.appendNewCaptionLine()
        }
    }

    private func appendNewCaptionLine() {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        captionLines.append(CaptionLine(
            callsign: "RX",
            time: formatter.string(from: Date()),
            text: "",
            active: true
        ))
    }

    // ── Derived helpers
    var isHighPower: Bool { txPower != "1 W" }

    var currentFreq: Float {
        ble.deviceState?.freqRx ?? 146.52
    }

    var currentFreqString: String {
        String(format: "%.3f", currentFreq)
    }

    var signalLevel: Int {
        guard let ds = ble.deviceState, ds.rssi > 0 else { return 0 }
        let result = 9.73 * log(0.0297 * Double(ds.rssi)) - 1.88
        return max(1, min(9, Int(result.rounded())))
    }

    var rawRSSI: UInt8 {
        ble.deviceState?.rssi ?? 0
    }

    var rxMode: RadioRxState {
        guard let ds = ble.deviceState else { return .idle }
        switch ds.mode {
        case 0: return .tx
        case 1: return .rx
        default: return .idle
        }
    }

    func memory(for freq: Float) -> Memory? {
        memories.first { abs($0.freq - freq) < 0.001 }
    }

    var activeMemoryId: UUID? {
        memory(for: currentFreq)?.id
    }

    var isSquelched: Bool {
        guard let ds = ble.deviceState else { return true }
        return (ds.flags & DEVICE_STATE_SQUELCHED) != 0
    }

    func checkSquelchTransition() {
        let sq = isSquelched
        defer { wasSquelched = sq }
        guard liveCaptions else { return }

        if wasSquelched && !sq {
            appendNewCaptionLine()
            speechManager.startSegment()
        } else if !wasSquelched && sq {
            speechManager.endSegment()
        }
    }

    func setupAudioSampleHook() {
        ble.setAudioSampleHook { [weak self] samples, count in
            guard let self, self.liveCaptions else { return }
            self.speechManager.feedSamples(samples, count: count)
        }
    }

    // Backgrounding keeps audio + BLE running; only UI-side work pauses
    // (speech recognition burns CPU and is unreliable in background).
    func enterBackground() {
        ble.setAudioSampleHook(nil)
        speechManager.endSegment()
        wasSquelched = true
    }

    func enterForeground() {
        setupAudioSampleHook()
        ble.recoverAudioIfNeeded()
    }

    var scanList: [Memory] { memories.filter(\.scanEnabled) }

    func startScan() {
        guard !scanList.isEmpty else { return }
        isScanning = true
        scanPaused = false
        scanIndex = 0
        tuneToScanIndex()
        scheduleScanTick()
    }

    func stopScan() {
        isScanning = false
        scanPaused = false
        scanTimer?.invalidate()
        scanTimer = nil
    }

    private func scheduleScanTick() {
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.scanTick() }
        }
    }

    private func scanTick() {
        let list = scanList
        guard isScanning, !list.isEmpty else { return }

        if !isSquelched {
            scanPaused = true
            return
        }

        if scanPaused {
            scanPaused = false
        }

        scanIndex = (scanIndex + 1) % list.count
        tuneToScanIndex()
    }

    private func tuneToScanIndex() {
        let list = scanList
        guard scanIndex < list.count else { return }
        let mem = list[scanIndex]
        sendRadioState(freq: mem.freq, ptt: false, txAllowed: false)
    }

    func updateMemory(_ memory: Memory) {
        guard let idx = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        memories[idx] = memory
    }

    func deleteMemory(id: UUID) {
        memories.removeAll { $0.id == id }
    }

    func sendRadioState(freq: Float? = nil, ptt: Bool = false, txAllowed: Bool = true) {
        let rxFreq = freq ?? currentFreq
        let mem = memory(for: rxFreq)
        let txFreq = mem.map { rxFreq + $0.offset } ?? rxFreq
        let tone = mem.map { ctcssIndex(for: $0.plTone) } ?? 0
        ble.sendDesiredState(
            freqTx: txFreq, freqRx: rxFreq, squelch: squelch,
            ptt: ptt, txAllowed: txAllowed, highPower: isHighPower,
            bw: bandwidth, ctcssTx: tone, ctcssRx: 0,
            filterPre: filterPreemphasis, filterHigh: filterHighPass, filterLow: filterLowPass
        )
    }

    // MARK: - RepeaterBook

    func fetchNearbyRepeaters() {
        guard let loc = locationManager.location else {
            locationManager.requestLocation()
            return
        }
        repeaterFetchState = .loading
        let lat = loc.coordinate.latitude
        let lon = loc.coordinate.longitude
        let dist = repeaterSearchDistance
        let band = repeaterSearchBand
        let urlStr = "https://www.repeaterbook.com/repeaters/prox_result.php?city=&lat=\(lat)&long=\(lon)&distance=\(dist)&Dunit=m&band%5B%5D=\(band)&features%5B%5D=FM&use%5B%5D=OPEN&status_id=1"

        Task {
            do {
                let repeaters = try await fetchRepeaterBookHTML(urlStr)
                await MainActor.run {
                    self.repeaters = repeaters
                    self.repeaterFetchState = repeaters.isEmpty ? .empty : .loaded
                }
            } catch {
                await MainActor.run {
                    self.repeaterFetchState = .error(error.localizedDescription)
                }
            }
        }
    }

    nonisolated private func fetchRepeaterBookHTML(_ urlString: String) async throws -> [Repeater] {
        guard let url = URL(string: urlString) else { return [] }
        var request = URLRequest(url: url)
        request.setValue("KV4P-HT/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return [] }
        return parseRepeaterBookHTML(html)
    }

    nonisolated private func parseRepeaterBookHTML(_ html: String) -> [Repeater] {
        var results: [Repeater] = []
        let rowPattern = try! NSRegularExpression(pattern: "<tr[^>]*>(.*?)</tr>", options: .dotMatchesLineSeparators)
        let cellPattern = try! NSRegularExpression(pattern: "<td[^>]*>(.*?)</td>", options: .dotMatchesLineSeparators)
        let tagPattern = try! NSRegularExpression(pattern: "<[^>]+>", options: [])

        let rowMatches = rowPattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for rowMatch in rowMatches {
            guard let rowRange = Range(rowMatch.range(at: 1), in: html) else { continue }
            let rowHTML = String(html[rowRange])
            let cellMatches = cellPattern.matches(in: rowHTML, range: NSRange(rowHTML.startIndex..., in: rowHTML))
            guard cellMatches.count >= 10 else { continue }

            func cellText(_ idx: Int) -> String {
                guard idx < cellMatches.count,
                      let r = Range(cellMatches[idx].range(at: 1), in: rowHTML) else { return "" }
                let raw = String(rowHTML[r])
                return tagPattern.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let freq = Float(cellText(1)) else { continue }

            let offsetStr = cellText(2).replacingOccurrences(of: " MHz", with: "")
            let offset = Float(offsetStr) ?? 0
            let toneStr = cellText(3)
            let tone = Float(toneStr) ?? 0
            let callsign = cellText(4)
            let city = cellText(5)
            let state = cellText(6)
            let location = state.isEmpty ? city : "\(city), \(state)"
            let miles = Float(cellText(9)) ?? 0

            results.append(Repeater(
                name: "\(callsign) · \(city)",
                callsign: callsign,
                freq: freq,
                offset: offset,
                plTone: tone,
                distanceMi: miles,
                location: location
            ))
        }
        return results
    }

    func importRepeater(_ rep: Repeater, group: String) {
        let mem = Memory(
            name: rep.name,
            group: group,
            freq: rep.freq,
            offset: rep.offset,
            plTone: rep.plTone,
            squelch: 2,
            isRepeater: rep.offset != 0
        )
        memories.append(mem)
    }

    func importAllRepeaters(group: String) {
        for rep in repeaters {
            importRepeater(rep, group: group)
        }
    }

    private func saveMemories() {
        let mems = memories
        DispatchQueue.global(qos: .background).async {
            guard let data = try? JSONEncoder().encode(mems) else { return }
            UserDefaults.standard.set(data, forKey: Self.memoriesKey)
        }
    }
}

enum RadioRxState {
    case idle, rx, tx
    var label: String {
        switch self {
        case .idle: return "MONITOR"
        case .rx:   return "RECEIVING"
        case .tx:   return "TRANSMIT"
        }
    }
}

enum RepeaterFetchState: Equatable {
    case idle, loading, loaded, empty
    case error(String)
}

// PTT is sent via ble.sendDesiredState(freq:squelch:ptt:txAllowed:)
