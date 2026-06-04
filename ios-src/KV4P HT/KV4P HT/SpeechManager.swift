import Speech
import AVFoundation

@MainActor
class SpeechManager {
    private var recognizer: SFSpeechRecognizer?
    private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentTask: SFSpeechRecognitionTask?
    private var segmentTimer: Timer?
    private var isRecognizing = false
    // Thread-safe reference for feeding samples from BLE queue
    nonisolated(unsafe) private var activeRequest: SFSpeechAudioBufferRecognitionRequest?

    private let audioFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!

    private static let rollingRestartSeconds: TimeInterval = 55
    private static let hamVocab = [
        "CQ", "QSO", "QTH", "QSL", "QRZ", "QRM", "QRN", "QRP", "QRO",
        "73", "88", "roger", "copy", "over", "out", "break", "breaker",
        "mayday", "pan-pan", "wilco", "affirmative", "negative",
        "alpha", "bravo", "charlie", "delta", "echo", "foxtrot",
        "golf", "hotel", "india", "juliet", "kilo", "lima", "mike",
        "november", "oscar", "papa", "quebec", "romeo", "sierra",
        "tango", "uniform", "victor", "whiskey", "x-ray", "yankee", "zulu",
        "simplex", "repeater", "duplex", "squelch", "kerchunk",
        "ham", "amateur", "frequency", "megahertz", "kilohertz"
    ]

    var onPartialResult: ((String) -> Void)?
    var onSegmentFinalized: (() -> Void)?
    var onRollingRestart: (() -> Void)?

    func configure(language: String) {
        let localeId = Self.mapLanguage(language)
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
    }

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func startSegment() {
        guard let recognizer, recognizer.isAvailable else { return }
        endSegment()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = Self.hamVocab
        currentRequest = request
        activeRequest = request

        currentTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                Task { @MainActor in
                    self.onPartialResult?(text)
                }
                if result.isFinal {
                    Task { @MainActor in
                        self.finalizeCurrentSegment()
                    }
                }
            } else if error != nil {
                Task { @MainActor in
                    self.finalizeCurrentSegment()
                }
            }
        }

        isRecognizing = true

        segmentTimer?.invalidate()
        segmentTimer = Timer.scheduledTimer(
            withTimeInterval: Self.rollingRestartSeconds,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rollingRestart()
            }
        }
    }

    nonisolated func feedSamples(_ samples: [Float], count: Int) {
        guard count > 0 else { return }
        let fmt = audioFormat
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(count)) else { return }
        pcmBuffer.frameLength = AVAudioFrameCount(count)
        if let channelData = pcmBuffer.floatChannelData {
            samples.withUnsafeBufferPointer { src in
                channelData[0].update(from: src.baseAddress!, count: count)
            }
        }
        activeRequest?.append(pcmBuffer)
    }

    func endSegment() {
        segmentTimer?.invalidate()
        segmentTimer = nil
        activeRequest = nil
        guard isRecognizing else { return }
        currentRequest?.endAudio()
        currentRequest = nil
        currentTask?.cancel()
        currentTask = nil
        isRecognizing = false
        onSegmentFinalized?()
    }

    func stopAll() {
        activeRequest = nil
        endSegment()
        recognizer = nil
    }

    private func rollingRestart() {
        guard isRecognizing else { return }
        activeRequest = nil
        currentRequest?.endAudio()
        currentRequest = nil
        currentTask?.cancel()
        currentTask = nil
        isRecognizing = false
        onSegmentFinalized?()
        onRollingRestart?()
        startSegment()
    }

    private func finalizeCurrentSegment() {
        segmentTimer?.invalidate()
        segmentTimer = nil
        activeRequest = nil
        currentRequest = nil
        currentTask = nil
        isRecognizing = false
        onSegmentFinalized?()
    }

    private static func mapLanguage(_ language: String) -> String {
        switch language {
        case "English (US)": return "en-US"
        case "English (UK)": return "en-GB"
        case "English (AU)": return "en-AU"
        case "Spanish":      return "es-ES"
        case "French":       return "fr-FR"
        case "German":       return "de-DE"
        case "Japanese":     return "ja-JP"
        case "Portuguese":   return "pt-BR"
        default:             return "en-US"
        }
    }
}
