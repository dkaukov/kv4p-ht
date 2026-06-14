import Foundation
import Testing
@testable import KV4P_HT

// MARK: - AX.25 frame round-trip

struct AX25Tests {

    @Test func callsignParsing() throws {
        let c = try #require(AX25Callsign(parsing: "n0call-7"))
        #expect(c.base == "N0CALL")
        #expect(c.ssid == 7)
        #expect(c.display == "N0CALL-7")

        let plain = try #require(AX25Callsign(parsing: "WIDE1"))
        #expect(plain.ssid == 0)
        #expect(plain.display == "WIDE1")

        #expect(AX25Callsign(parsing: "TOOLONGCALL") == nil)
        #expect(AX25Callsign(parsing: "N0CALL-16") == nil)
    }

    @Test func callsignWireEncoding() throws {
        // Matches Android Callsign.toAX25: chars << 1, space-padded,
        // SSID byte 0x60 | (ssid << 1), plus last/repeated bits.
        let c = AX25Callsign(base: "KD4Z", ssid: 9)
        let bytes = [UInt8](c.encoded(last: true))
        #expect(bytes == [0x96, 0x88, 0x68, 0xB4, 0x40, 0x40, 0x60 | (9 << 1) | 0x01])
    }

    @Test func frameRoundTrip() throws {
        let src = AX25Callsign(base: "N0CALL", ssid: 9)
        let frame = AX25Frame(source: src, payload: Data(":KC4ABC   :hello{42".utf8))
        let encoded = frame.encodedWithoutFCS()

        // dest(7) + src(7) + 2 digis(14) + ctrl + pid + payload
        #expect(encoded.count == 7 + 7 + 14 + 2 + 19)
        #expect(encoded[28] == 0x03)
        #expect(encoded[29] == 0xF0)

        let decoded = try #require(AX25Frame(decoding: encoded))
        #expect(decoded.source.display == "N0CALL-9")
        #expect(decoded.destination.base == "APKVPA")
        #expect(decoded.digipeaters.map(\.display) == ["WIDE1-1", "WIDE2-1"])
        #expect(decoded.payload == frame.payload)
    }

    @Test func frameNoDigipeaters() throws {
        let src = AX25Callsign(base: "AB1CD", ssid: 0)
        let frame = AX25Frame(destination: AX25Callsign(base: "APRS", ssid: 0),
                              source: src, digipeaters: [], payload: Data(">test".utf8))
        let decoded = try #require(AX25Frame(decoding: frame.encodedWithoutFCS()))
        #expect(decoded.digipeaters.isEmpty)
        #expect(decoded.source.display == "AB1CD")
    }

    @Test func rejectsBadControlPid() {
        var data = AX25Frame(source: AX25Callsign(base: "N0CALL", ssid: 0),
                             digipeaters: [], payload: Data("x".utf8)).encodedWithoutFCS()
        data[14] = 0x42  // corrupt control byte
        #expect(AX25Frame(decoding: data) == nil)
    }
}

// MARK: - APRS payload parsing

struct APRSParseTests {

    @Test func compressedPosition() throws {
        // Encode then decode a known position — values from Position.java's
        // own main(): 34.12558, -84.13697.
        let s = compressedPositionString(lat: 34.12558, lon: -84.13697, symbolCode: "o")
        let info = parseAPRSPayload(Data(("=" + s).utf8))
        guard case let .position(lat, lon, table, code, _, _) = info else {
            Issue.record("expected position, got \(info)")
            return
        }
        #expect(abs(lat - 34.12558) < 0.001)
        #expect(abs(lon - (-84.13697)) < 0.001)
        #expect(table == "/")
        #expect(code == "o")
    }

    @Test func compressedExtremes() throws {
        for (lat, lon) in [(89.9, 179.9), (-89.9, -179.9), (0.0, 0.0)] {
            let s = compressedPositionString(lat: lat, lon: lon, symbolCode: "-")
            let info = parseAPRSPayload(Data(("!" + s).utf8))
            guard case let .position(pLat, pLon, _, _, _, _) = info else {
                Issue.record("expected position for \(lat),\(lon)")
                continue
            }
            #expect(abs(pLat - lat) < 0.001)
            #expect(abs(pLon - lon) < 0.001)
        }
    }

    @Test func uncompressedPosition() throws {
        let info = parseAPRSPayload(Data("!3449.94N/08448.56W-test comment".utf8))
        guard case let .position(lat, lon, table, code, comment, _) = info else {
            Issue.record("expected position, got \(info)")
            return
        }
        #expect(abs(lat - 34.832333) < 0.001)
        #expect(abs(lon - (-84.809333)) < 0.001)
        #expect(table == "/")
        #expect(code == "-")
        #expect(comment == "test comment")
    }

    @Test func uncompressedWeather() throws {
        let info = parseAPRSPayload(Data("!3449.94N/08448.56W_203/004g007t079r000h85b10149".utf8))
        guard case let .position(_, _, _, code, _, weather) = info else {
            Issue.record("expected position, got \(info)")
            return
        }
        #expect(code == "_")
        let wx = try #require(weather)
        #expect(wx.temperatureF == 79)
        #expect(wx.windDirDeg == 203)
        #expect(wx.windMph == 4)
        #expect(wx.windGustMph == 7)
        #expect(wx.humidity == 85)
        #expect(wx.pressureMb == 1014.9)
    }

    @Test func directedMessage() throws {
        let info = parseAPRSPayload(Data(":N0CALL   :hello there{42".utf8))
        guard case let .message(to, body, msgNum, isAck, _) = info else {
            Issue.record("expected message, got \(info)")
            return
        }
        #expect(to == "N0CALL")
        #expect(body == "hello there")
        #expect(msgNum == "42")
        #expect(!isAck)
    }

    @Test func thirdPartyUnwrapMessage() throws {
        // Real packet: aprs.fi message to W9VFR-9 gated to RF by W9VFR-1.
        let payload = Data("}W9VFR-4>APFII0,TCPIP,W9VFR-1*::W9VFR-9  :SYN{80F32".utf8)
        let tp = try #require(APRSController.unwrapThirdParty(payload))
        #expect(tp.source == "W9VFR-4")
        #expect(tp.destination == "APFII0")

        guard case let .message(to, body, msgNum, isAck, _) = parseAPRSPayload(tp.info) else {
            Issue.record("expected message, got \(parseAPRSPayload(tp.info))")
            return
        }
        #expect(to == "W9VFR-9")
        #expect(body == "SYN")
        #expect(msgNum == "80F32")
        #expect(!isAck)
    }

    @Test func nonThirdPartyReturnsNil() {
        #expect(APRSController.unwrapThirdParty(Data(":N0CALL   :hi{1".utf8)) == nil)
        #expect(APRSController.unwrapThirdParty(Data("}garbage-no-colon".utf8)) == nil)
    }

    @Test func ackMessage() throws {
        let info = parseAPRSPayload(Data(":N0CALL-9 :ack42".utf8))
        guard case let .message(to, _, msgNum, isAck, _) = info else {
            Issue.record("expected message, got \(info)")
            return
        }
        #expect(to == "N0CALL-9")
        #expect(msgNum == "42")
        #expect(isAck)
    }

    @Test func timestampedPosition() throws {
        let info = parseAPRSPayload(Data("@092345z3449.94N/08448.56W>moving".utf8))
        guard case let .position(lat, _, _, code, comment, _) = info else {
            Issue.record("expected position, got \(info)")
            return
        }
        #expect(abs(lat - 34.832333) < 0.001)
        #expect(code == ">")
        #expect(comment == "moving")
    }

    @Test func positionlessWeather() throws {
        let info = parseAPRSPayload(Data("_10090556c220s004g005t077r000p000P000h50b09900wRSW".utf8))
        guard case let .weather(wx, _) = info else {
            Issue.record("expected weather, got \(info)")
            return
        }
        #expect(wx.temperatureF == 77)
        #expect(wx.humidity == 50)
    }

    @Test func unknownDtiFallsThroughToRaw() {
        let info = parseAPRSPayload(Data(">status text here".utf8))
        guard case let .raw(text) = info else {
            Issue.record("expected raw")
            return
        }
        #expect(text.hasPrefix(">"))
    }

    @Test func messagePayloadBuilder() {
        #expect(messagePayload(to: "N1AA", text: "hi", msgNum: "7")
                == ":N1AA     :hi{7")
        #expect(messagePayload(to: "KC4ABC-12", text: "test", msgNum: nil)
                == ":KC4ABC-12:test")
        // 67-char limit including msgNum suffix
        let long = String(repeating: "x", count: 80)
        let built = messagePayload(to: "N1AA", text: long, msgNum: "123")
        #expect(built.count == 1 + 9 + 1 + 67)
    }
}

// MARK: - RX pipeline / persistence

struct APRSPipelineTests {

    // Tests run in parallel; isolate each controller's UserDefaults so the
    // legacy-migration blob can't leak between tests via .standard.
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test-" + UUID().uuidString)!
    }

    private func makeController(_ persistence: APRSPersistence,
                                defaults: UserDefaults? = nil) -> APRSController {
        APRSController(persistence: persistence, defaults: defaults ?? freshDefaults())
    }

    private func frameBytes(from: String, payload: String) -> Data {
        AX25Frame(destination: AX25Callsign(base: "APKVPA", ssid: 0),
                  source: AX25Callsign(parsing: from)!,
                  digipeaters: [], payload: Data(payload.utf8))
            .encodedWithoutFCS()
    }

    @Test func duplicateDirectedMessageAppendsOnce() {
        let controller = makeController(APRSPersistence(inMemory: true))
        let frame = frameBytes(from: "N0CALL-9", payload: ":KC4ABC   :hello{42")
        controller.handleAx25Frame(frame)
        controller.handleAx25Frame(frame)   // sender retry
        #expect(controller.entries.count == 1)
    }

    @Test func historySurvivesRestart() {
        let persistence = APRSPersistence(inMemory: true)
        let first = makeController(persistence)
        first.handleAx25Frame(frameBytes(from: "N0CALL-9", payload: ":KC4ABC   :hello{42"))
        #expect(first.entries.count == 1)

        // Same store, fresh controller = app relaunch.
        let second = makeController(persistence)
        #expect(second.entries.count == 1)
        #expect(second.entries.first?.text == "hello")
        #expect(second.entries.first?.msgNum == "42")
    }

    @Test func messageDedupeSurvivesRestart() {
        let persistence = APRSPersistence(inMemory: true)
        let frame = frameBytes(from: "N0CALL-9", payload: ":KC4ABC   :hello{42")
        makeController(persistence).handleAx25Frame(frame)

        let relaunched = makeController(persistence)
        relaunched.handleAx25Frame(frame)   // retry after relaunch
        #expect(relaunched.entries.count == 1)
    }

    @Test func shortWindowDoesNotSuppressDistinctPackets() {
        let controller = makeController(APRSPersistence(inMemory: true))
        controller.handleAx25Frame(frameBytes(from: "N0CALL-9", payload: "!3449.94N/08448.56W-a"))
        controller.handleAx25Frame(frameBytes(from: "N0CALL-9", payload: "!3449.94N/08448.56W-b"))
        #expect(controller.entries.count == 2)
    }

    @Test func ackStatePersistsAcrossReload() {
        let persistence = APRSPersistence(inMemory: true)
        var outgoing = APRSEntry(fromCallsign: "KC4ABC", toCallsign: "N0CALL",
                                 kind: .message, text: "hi", timestamp: Date(), msgNum: "7")
        outgoing.isOutgoing = true
        persistence.insertEntry(outgoing, frameHash: nil)
        persistence.markEntryAcknowledged(id: outgoing.id)

        let reloaded = persistence.loadEntries(max: 10)
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.wasAcknowledged == true)
    }

    @Test func legacyUserDefaultsBlobMigrates() throws {
        let defaults = freshDefaults()
        let entry = APRSEntry(fromCallsign: "N0CALL", toCallsign: "KC4ABC",
                              kind: .message, text: "old history", timestamp: Date())
        defaults.set(try JSONEncoder().encode([entry]), forKey: "aprsEntries")

        let controller = makeController(APRSPersistence(inMemory: true), defaults: defaults)
        #expect(controller.entries.contains { $0.text == "old history" })
        #expect(defaults.data(forKey: "aprsEntries") == nil)
    }

    // MARK: - Message retry (decay algorithm)

    @Test func retryIntervalDecaysAndCaps() {
        #expect(APRSController.retryInterval(forAttempt: 0) == 8)
        #expect(APRSController.retryInterval(forAttempt: 1) == 16)
        #expect(APRSController.retryInterval(forAttempt: 2) == 32)
        #expect(APRSController.retryInterval(forAttempt: 6) == 512)
        #expect(APRSController.retryInterval(forAttempt: 30) == 20 * 60)  // capped
    }

    @Test func retryStateAdvancesThenGivesUp() {
        let now = Date()
        // Mid-sequence: schedule the next retry.
        let mid = APRSController.nextRetryState(retryCount: 0, now: now)
        #expect(mid.retryCount == 1)
        #expect(mid.nextRetryAt == now.addingTimeInterval(16))
        // Final attempt exhausts the budget → undelivered (nil).
        let last = APRSController.nextRetryState(retryCount: APRSController.maxRetries - 1, now: now)
        #expect(last.retryCount == APRSController.maxRetries)
        #expect(last.nextRetryAt == nil)
    }

    @Test func ackClearsPendingRetryAcrossReload() {
        let persistence = APRSPersistence(inMemory: true)
        var outgoing = APRSEntry(fromCallsign: "KC4ABC", toCallsign: "N0CALL",
                                 kind: .message, text: "hi", timestamp: Date(), msgNum: "7")
        outgoing.nextRetryAt = Date().addingTimeInterval(8)
        outgoing.isOutgoing = true
        persistence.insertEntry(outgoing, frameHash: nil)
        persistence.markEntryAcknowledged(id: outgoing.id)

        let e = persistence.loadEntries(max: 10).first
        #expect(e?.wasAcknowledged == true)
        #expect(e?.nextRetryAt == nil)
        #expect(e?.isAwaitingAck == false)
    }

    @Test func retryStatePersistsAcrossReload() {
        let persistence = APRSPersistence(inMemory: true)
        var outgoing = APRSEntry(fromCallsign: "KC4ABC", toCallsign: "N0CALL",
                                 kind: .message, text: "hi", timestamp: Date(), msgNum: "7")
        outgoing.isOutgoing = true
        let due = Date().addingTimeInterval(64)
        persistence.insertEntry(outgoing, frameHash: nil)
        persistence.updateEntryRetry(id: outgoing.id, retryCount: 3, nextRetryAt: due)

        let e = persistence.loadEntries(max: 10).first
        #expect(e?.retryCount == 3)
        #expect(e?.nextRetryAt?.timeIntervalSince1970 == due.timeIntervalSince1970)
        #expect(e?.isAwaitingAck == true)
    }
}
