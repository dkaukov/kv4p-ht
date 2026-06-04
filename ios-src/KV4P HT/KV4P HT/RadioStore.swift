import Foundation
import SwiftUI

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

struct Memory: Identifiable {
    let id = UUID()
    var name: String
    var group: String
    var freq: Float
    var offset: Float      // MHz, 0 = simplex
    var plTone: Float      // Hz, 0 = no tone
    var squelch: UInt8
    var isRepeater: Bool
    var notes: String = ""

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

    // ── Voice
    var voiceMode: VoiceMode = .simplex
    var captionsEnabled: Bool = false
    var isRecording: Bool = false
    var activeScanIndex: Int = 1  // index in scanChannels currently active

    // ── Memories / Repeaters
    var memories: [Memory] = []
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
    var reduceMotion: Bool = false
    var captionLanguage: String = "English (US)"

    // ── Derived helpers
    var isHighPower: Bool { txPower != "1 W" }

    var currentFreqString: String {
        if let ds = ble.deviceState {
            return String(format: "%.3f", ds.freqRx)
        }
        return "146.520"
    }

    var signalLevel: Int {
        guard let ds = ble.deviceState else { return 0 }
        // RSSI 0-255 → 0-9 bars
        return min(9, Int(ds.rssi) / 28)
    }

    var rxMode: RadioRxState {
        guard let ds = ble.deviceState else { return .idle }
        switch ds.mode {
        case 0: return .tx
        case 1: return .rx
        default: return .idle
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

// PTT is sent via ble.sendDesiredState(freq:squelch:ptt:txAllowed:)
