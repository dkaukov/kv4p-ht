import Foundation
import SwiftUI
import CoreLocation

// MARK: - Data Models

enum VoiceMode: String, CaseIterable {
    case vfo, scan
    var label: String {
        switch self {
        case .vfo:  return "VFO"
        case .scan: return "Scan"
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
    var themeMode: AppThemeMode = .system {
        didSet { if !isInitializing { UserDefaults.standard.set(themeMode.rawValue, forKey: Self.themeModeKey) } }
    }
    // Resolved by ContentView (which has access to the system color scheme);
    // nested views read this via the `.theme` environment value.
    var theme: AppTheme = .dark

    // ── Radio
    // Desired/applied radio state. UI writes go through this controller's
    // setters (via helpers like sendRadioState); BLE is transport only.
    let radio: RadioModuleController
    let ble: BLEManager
    @ObservationIgnored private var isApplyingDeviceStateToUI = false

    // ── Location
    let locationManager = LocationManager()
    var repeaterFetchState: RepeaterFetchState = .idle
    var repeaterSearchDistance: Int = 25  // miles
    var repeaterSearchBand: Int = 4      // 4=2m, 16=70cm

    // ── Voice
    var voiceMode: VoiceMode = .vfo
    // Desired/applied radio squelch level (0 = monitor). Mirrored from
    // firmware state and sent through RadioModuleController on user changes.
    var squelch: UInt8 = 3 {
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                UserDefaults.standard.set(Int(squelch), forKey: Self.squelchKey)
                ble.setRxAudioMuted(effectiveRxMuted)
                radio.setSquelch(squelch)
            }
        }
    }
    // Desired VFO channel config; survives without a memory match. Seeded
    // from firmware-applied state on connect and from memory/repeater tunes.
    var vfoOffset: Float = 0       // MHz, 0 = simplex
    var vfoToneIndex: UInt8 = 0    // CTCSS index, 0 = off
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
    let aprs = APRSController()
    var aprsFilter: String = "All"
    var selectedEntry: APRSEntry? = nil
    var aprsSymbol: String = "[" {
        didSet { if !isInitializing { saveAprsSettings() } }
    }
    var aprsBeaconEnabled: Bool = false {
        didSet {
            if !isInitializing {
                saveAprsSettings()
                aprs.updateBeaconTimer()
            }
        }
    }
    var aprsBeaconIntervalMin: Int = 15 {
        didSet {
            if !isInitializing {
                saveAprsSettings()
                aprs.updateBeaconTimer()
            }
        }
    }
    var aprsBeaconFrequency: String = "144.3900" {
        didSet {
            if !isInitializing {
                saveAprsSettings()
                ble.setRxAudioMuted(effectiveRxMuted)
            }
        }
    }
    var aprsPositionApprox: Bool = false {
        didSet { if !isInitializing { saveAprsSettings() } }
    }
    var silenceRxOnAprsFreq: Bool = false {
        didSet {
            if !isInitializing {
                saveAprsSettings()
                ble.setRxAudioMuted(effectiveRxMuted)
            }
        }
    }

    // ── Recordings
    var recordings: [Recording] = []

    // ── Captions
    var captionLines: [CaptionLine] = []
    let speechManager = SpeechManager()
    @ObservationIgnored private var wasSquelched = true

    // ── Settings
    var callsign: String = "" {
        didSet { if !isInitializing { saveAprsSettings() } }
    }
    var aprsSSID: String = "" {
        didSet { if !isInitializing { saveAprsSettings() } }
    }
    var txPower: String = "High" {
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                radio.setHighPower(isHighPower)
            }
        }
    }
    var filterPreemphasis: Bool = true {
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                radio.setFilters(emphasis: filterPreemphasis, highpass: filterHighPass, lowpass: filterLowPass)
            }
        }
    }
    var filterHighPass: Bool = true {
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                radio.setFilters(emphasis: filterPreemphasis, highpass: filterHighPass, lowpass: filterLowPass)
            }
        }
    }
    var filterLowPass: Bool = false {
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                radio.setFilters(emphasis: filterPreemphasis, highpass: filterHighPass, lowpass: filterLowPass)
            }
        }
    }
    var liveCaptions: Bool = true
    var saveTranscripts: Bool = true
    var stickyPTT: Bool = false
    var bandwidth: UInt8 = 0 {  // 0=wide 25kHz, 1=narrow 12.5kHz
        didSet {
            if !isInitializing && !isApplyingDeviceStateToUI {
                radio.setBandwidth(bandwidth == 0 ? DRA818_25K : DRA818_12K5)
            }
        }
    }
    var reduceMotion: Bool = false
    var captionLanguage: String = "English (US)"

    // ── Init
    init() {
        let radio = RadioModuleController()
        self.radio = radio
        self.ble = BLEManager(radio: radio)
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
        loadAprsSettings()
        if let raw = UserDefaults.standard.string(forKey: Self.themeModeKey),
           let mode = AppThemeMode(rawValue: raw) {
            themeMode = mode
        }
        if let s = UserDefaults.standard.object(forKey: Self.squelchKey) as? Int {
            squelch = UInt8(clamping: s)
        }
        isInitializing = false
        configureSpeechManager()

        aprs.store = self
        ble.onAx25Frame = { [weak self] data in
            DispatchQueue.main.async { self?.aprs.handleAx25Frame(data) }
        }
        // Controller seeds desired state from firmware on HELLO; copy the
        // applied firmware config into the UI settings so the next user
        // action doesn't overwrite firmware state with stale UI defaults.
        ble.onTransportReady = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hydrateUISettingsFromAppliedState()
                self.ble.setRxAudioMuted(self.effectiveRxMuted)
                // Fire any message retries that came due while disconnected.
                self.aprs.processDueRetries()
            }
        }
        // Keep UI controls in sync with the firmware-applied radio config.
        ble.onDeviceState = { [weak self] _ in
            guard let self else { return }
            self.hydrateUISettingsFromAppliedState()
            self.ble.setRxAudioMuted(self.effectiveRxMuted)
        }
        aprs.updateBeaconTimer()
    }

    private static let themeModeKey = "themeMode"
    private static let aprsSettingsKey = "aprsSettings"
    private static let squelchKey = "squelchLevel"

    private struct APRSSettings: Codable {
        var callsign: String
        var ssid: String
        var symbol: String
        var beaconEnabled: Bool
        var beaconIntervalMin: Int
        var beaconFrequency: String
        var positionApprox: Bool
        var silenceRxOnAprsFreq: Bool = false
    }

    private func loadAprsSettings() {
        guard let data = UserDefaults.standard.data(forKey: Self.aprsSettingsKey),
              let s = try? JSONDecoder().decode(APRSSettings.self, from: data) else { return }
        callsign = s.callsign
        aprsSSID = s.ssid
        aprsSymbol = s.symbol
        aprsBeaconEnabled = s.beaconEnabled
        aprsBeaconIntervalMin = s.beaconIntervalMin
        aprsBeaconFrequency = s.beaconFrequency
        aprsPositionApprox = s.positionApprox
        silenceRxOnAprsFreq = s.silenceRxOnAprsFreq
    }

    private func saveAprsSettings() {
        let s = APRSSettings(
            callsign: callsign, ssid: aprsSSID, symbol: aprsSymbol,
            beaconEnabled: aprsBeaconEnabled, beaconIntervalMin: aprsBeaconIntervalMin,
            beaconFrequency: aprsBeaconFrequency, positionApprox: aprsPositionApprox,
            silenceRxOnAprsFreq: silenceRxOnAprsFreq)
        guard let data = try? JSONEncoder().encode(s) else { return }
        UserDefaults.standard.set(data, forKey: Self.aprsSettingsKey)
    }

    private func hydrateUISettingsFromAppliedState() {
        guard let ds = radio.deviceState else { return }
        isApplyingDeviceStateToUI = true
        defer { isApplyingDeviceStateToUI = false }
        squelch = ds.squelch
        bandwidth = ds.bw == DRA818_25K ? 0 : 1
        txPower = (!radio.hasHighLowPowerSwitch || (ds.flags & HOST_STATE_HIGH_POWER) != 0) ? "High" : "Low"
        filterPreemphasis = (ds.flags & HOST_STATE_FILTER_PRE) != 0
        filterHighPass = (ds.flags & HOST_STATE_FILTER_HIGH) != 0
        // NB: do NOT force the DRA818 low-pass filter on here. It sits on the
        // analog audio output that feeds both the phone audio stream and the
        // ESP32's AFSK demodulator, and enabling it distorts the 2200 Hz space
        // tone enough to break AX.25/APRS decode. It cleans up listening audio
        // but kills packet RX; leave it user-controlled (default off).
        filterLowPass = (ds.flags & HOST_STATE_FILTER_LOW) != 0
        vfoOffset = ds.freqTx - ds.freqRx
        vfoToneIndex = ds.ctcssTx
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
    var isHighPower: Bool { txPower == "High" }

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

    // Applied TX offset from firmware state; preserves split TX/RX config
    // that has no matching memory.
    var currentTxOffset: Float {
        guard let ds = ble.deviceState else { return 0 }
        return ds.freqTx - ds.freqRx
    }

    var currentOffsetString: String {
        let offset = currentTxOffset
        if abs(offset) < 0.0005 { return "Simplex" }
        return offset > 0 ? String(format: "+%.3f", offset) : String(format: "%.3f", offset)
    }

    // Applied TX tone from firmware state.
    var currentToneString: String {
        guard let ds = ble.deviceState, let hz = ctcssToneHz(for: ds.ctcssTx) else { return "Off" }
        return String(format: "PL %.1f", hz)
    }

    var rxMode: RadioRxState {
        guard let ds = ble.deviceState else { return .idle }
        switch ds.mode {
        case 0: return .tx
        case 1: return isSquelched ? .idle : .rx
        default: return .idle
        }
    }

    func memory(for freq: Float) -> Memory? {
        memories.first { abs($0.freq - freq) < 0.001 }
    }

    var activeMemoryId: UUID? {
        memory(for: currentFreq)?.id
    }

    // Applied squelch state reported by firmware. This drives RX/IDLE status,
    // caption transitions, and local audio muting.
    var isSquelched: Bool {
        guard let ds = ble.deviceState else { return true }
        return (ds.flags & DEVICE_STATE_SQUELCHED) != 0
    }

    // True when the user has opted to silence RX audio while tuned to their
    // configured APRS frequency (so packet bursts aren't heard as noise).
    var isOnAprsFreq: Bool {
        guard silenceRxOnAprsFreq,
              aprsBeaconFrequency != "Current",
              let aprsFreq = Float(aprsBeaconFrequency) else { return false }
        return abs(currentFreq - aprsFreq) < 0.0005
    }

    var effectiveRxMuted: Bool {
        isSquelched || isOnAprsFreq
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
        applyMemory(list[scanIndex])
    }

    func updateMemory(_ memory: Memory) {
        guard let idx = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        memories[idx] = memory
    }

    func deleteMemory(id: UUID) {
        memories.removeAll { $0.id == id }
    }

    // User-intent helper: pushes the current UI settings + VFO channel
    // config (and optional freq/PTT change) into the controller's desired
    // state as one batch. The controller decides if a DesiredState frame
    // actually goes out. Offset and tone come from the VFO fields — tuning
    // a memory or repeater seeds them first via applyMemory/tune(toRepeater:).
    // simplexOverride: transmit on the RX frequency with no tone, without
    // touching the VFO fields (APRS frequency-switch beacons are simplex).
    func sendRadioState(freq: Float? = nil, ptt: Bool = false, simplexOverride: Bool = false) {
        let rxFreq = freq ?? currentFreq
        radio.beginUpdate()
        radio.setTxFrequency(rxFreq + (simplexOverride ? 0 : vfoOffset))
        radio.setRxFrequency(rxFreq)
        radio.setSquelch(squelch)
        radio.setBandwidth(bandwidth == 0 ? DRA818_25K : DRA818_12K5)
        radio.setTxTone(simplexOverride ? 0 : vfoToneIndex)
        radio.setFilters(emphasis: filterPreemphasis, highpass: filterHighPass, lowpass: filterLowPass)
        radio.setHighPower(isHighPower)
        if ptt { radio.pttDown() } else { radio.pttUp() }
        radio.endUpdate()
    }

    func applyMemory(_ mem: Memory) {
        vfoOffset = mem.offset
        vfoToneIndex = ctcssIndex(for: mem.plTone)
        sendRadioState(freq: mem.freq)
    }

    func tune(toRepeater rep: Repeater) {
        vfoOffset = rep.offset
        vfoToneIndex = ctcssIndex(for: rep.plTone)
        sendRadioState(freq: rep.freq)
    }

    // Pill-editor entry point: one desired-state push for both fields.
    func setVfoConfig(offset: Float, toneIndex: UInt8) {
        vfoOffset = offset
        vfoToneIndex = toneIndex
        sendRadioState()
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
        case .idle: return "IDLE"
        case .rx:   return "RECEIVING"
        case .tx:   return "TRANSMIT"
        }
    }
}

enum RepeaterFetchState: Equatable {
    case idle, loading, loaded, empty
    case error(String)
}
