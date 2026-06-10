import Foundation

// APRS payload (information field) parsing and building, ported from the
// Android app's parser package (Parser.parseBody, PositionParser,
// MessagePacket, ObjectField, WeatherParser, Position.toCompressedString).
// Scope: position, message/ack, object, weather. MIC-E, NMEA, telemetry and
// third-party packets fall through to .raw.

struct APRSWeather: Codable, Equatable {
    var temperatureF: Int?
    var windMph: Int?
    var windDirDeg: Int?
    var windGustMph: Int?
    var humidity: Int?
    var pressureMb: Double?
    var rainLastHourIn: Double?

    var summary: String {
        var parts: [String] = []
        if let t = temperatureF { parts.append("\(t)°F") }
        if let h = humidity { parts.append("\(h)% RH") }
        if let w = windMph {
            if let d = windDirDeg { parts.append("wind \(w) mph @ \(d)°") }
            else { parts.append("wind \(w) mph") }
        }
        if let g = windGustMph { parts.append("gust \(g)") }
        if let p = pressureMb { parts.append(String(format: "%.1f mb", p)) }
        if let r = rainLastHourIn, r > 0 { parts.append(String(format: "%.2f\" rain/hr", r)) }
        return parts.joined(separator: " · ")
    }
}

enum APRSInfo {
    case position(lat: Double, lon: Double, symbolTable: Character, symbolCode: Character,
                  comment: String, weather: APRSWeather?)
    case message(to: String, body: String, msgNum: String?, isAck: Bool, isRej: Bool)
    case object(name: String, lat: Double?, lon: Double?, comment: String)
    case weather(APRSWeather, comment: String)
    case raw(String)
}

func parseAPRSPayload(_ info: Data) -> APRSInfo {
    guard let text = String(data: info, encoding: .utf8)
            ?? String(data: info, encoding: .isoLatin1),
          let dti = text.first else {
        return .raw("")
    }
    let chars = Array(text)

    switch dti {
    case "!", "=":
        return parsePositionPayload(chars, cursor: 1) ?? .raw(text)
    case "/", "@":
        // 7-char timestamp (e.g. 092345z) between DTI and position
        guard chars.count > 8 else { return .raw(text) }
        return parsePositionPayload(chars, cursor: 8) ?? .raw(text)
    case ":":
        return parseMessagePayload(text) ?? .raw(text)
    case ";":
        return parseObjectPayload(chars, text: text) ?? .raw(text)
    case "_", "#", "*":
        let wx = parseWeatherReport(String(chars.dropFirst()))
        return .weather(wx, comment: "")
    default:
        return .raw(text)
    }
}

// MARK: - Position

private func parsePositionPayload(_ chars: [Character], cursor: Int) -> APRSInfo? {
    guard chars.count > cursor else { return nil }
    let first = chars[cursor]

    if isCompressedSymbolTable(first) {
        return parseCompressedPosition(chars, cursor: cursor)
    } else if first.isNumber {
        return parseUncompressedPosition(chars, cursor: cursor)
    }
    return nil
}

private func isCompressedSymbolTable(_ c: Character) -> Bool {
    c == "/" || c == "\\" || ("A"..."Z").contains(c) || ("a"..."j").contains(c)
}

// 13 chars: table + 4×base91 lat + 4×base91 lon + code + csT
private func parseCompressedPosition(_ chars: [Character], cursor: Int) -> APRSInfo? {
    guard chars.count >= cursor + 13 else { return nil }
    var vals = [Int]()
    for i in 1...8 {
        guard let ascii = chars[cursor + i].asciiValue, ascii >= 0x21, ascii <= 0x7b else { return nil }
        vals.append(Int(ascii) - 33)
    }
    let lat = 90.0 - Double(vals[0] * 91 * 91 * 91 + vals[1] * 91 * 91 + vals[2] * 91 + vals[3]) / 380926.0
    let lon = -180.0 + Double(vals[4] * 91 * 91 * 91 + vals[5] * 91 * 91 + vals[6] * 91 + vals[7]) / 190463.0
    let table = chars[cursor]
    let code = chars[cursor + 9]
    let rest = String(chars.dropFirst(cursor + 13))
    if code == "_" {
        return .position(lat: lat, lon: lon, symbolTable: table, symbolCode: code,
                         comment: "", weather: parseWeatherReport(rest))
    }
    return .position(lat: lat, lon: lon, symbolTable: table, symbolCode: code,
                     comment: rest.trimmingCharacters(in: .whitespaces), weather: nil)
}

// 19 chars: ddmm.mmN T dddmm.mmE C
private func parseUncompressedPosition(_ chars: [Character], cursor: Int) -> APRSInfo? {
    guard chars.count >= cursor + 19 else { return nil }
    var buf = Array(chars[cursor..<(cursor + 19)])

    // Position ambiguity: spaces replaced with mid-range digits (per Android)
    if buf[2] == " " { buf[2] = "3"; buf[3] = "0"; buf[5] = "0"; buf[6] = "0" }
    if buf[3] == " " { buf[3] = "5"; buf[5] = "0"; buf[6] = "0" }
    if buf[5] == " " { buf[5] = "5"; buf[6] = "0" }
    if buf[6] == " " { buf[6] = "5" }
    if buf[12] == " " { buf[12] = "3"; buf[13] = "0"; buf[15] = "0"; buf[16] = "0" }
    if buf[13] == " " { buf[13] = "5"; buf[15] = "0"; buf[16] = "0" }
    if buf[15] == " " { buf[15] = "5"; buf[16] = "0" }
    if buf[16] == " " { buf[16] = "5" }

    guard var lat = parseDegMin(buf, cursor: 0, degSize: 2),
          var lon = parseDegMin(buf, cursor: 9, degSize: 3) else { return nil }
    let latH = buf[7], lonH = buf[17]
    switch latH {
    case "S", "s": lat = -lat
    case "N", "n": break
    default: return nil
    }
    switch lonH {
    case "W", "w": lon = -lon
    case "E", "e": break
    default: return nil
    }
    let table = buf[8]
    let code = buf[18]
    let rest = String(chars.dropFirst(cursor + 19))
    if code == "_" {
        return .position(lat: lat, lon: lon, symbolTable: table, symbolCode: code,
                         comment: "", weather: parseWeatherReport(rest))
    }
    return .position(lat: lat, lon: lon, symbolTable: table, symbolCode: code,
                     comment: rest.trimmingCharacters(in: .whitespaces), weather: nil)
}

// ddmm.mm → decimal degrees
private func parseDegMin(_ buf: [Character], cursor: Int, degSize: Int) -> Double? {
    var deg = 0.0
    for i in 0..<degSize {
        guard let d = buf[cursor + i].wholeNumberValue, buf[cursor + i].isNumber else { return nil }
        deg = deg * 10 + Double(d)
    }
    // Minutes field is always 5 chars: "mm.mm"
    var minutes = 0.0
    var factor = 10.0
    var i = 0
    while cursor + degSize + i < buf.count && i < 5 {
        let c = buf[cursor + degSize + i]
        if i == 2 {
            guard c == "." else { return nil }
            i += 1
            continue
        }
        guard let d = c.wholeNumberValue, c.isNumber else { return nil }
        minutes += factor * Double(d)
        factor *= 0.1
        i += 1
    }
    guard minutes < 60.0 else { return nil }
    let result = deg + minutes / 60.0
    if degSize == 2 && result > 90.01 { return nil }
    if degSize == 3 && result > 180.01 { return nil }
    return (result * 100000).rounded() / 100000
}

// MARK: - Message

private func parseMessagePayload(_ text: String) -> APRSInfo? {
    // ":ADDRESSEE:body{msgnum"  — addressee padded to 9 chars
    guard text.count >= 11 else { return nil }
    let chars = Array(text)
    guard chars[10] == ":" else { return nil }
    let to = String(chars[1..<10]).trimmingCharacters(in: .whitespaces).uppercased()
    var body = String(chars.dropFirst(11))
    var msgNum: String? = nil
    if let braceIdx = body.lastIndex(of: "{") {
        msgNum = String(body[body.index(after: braceIdx)...])
        body = String(body[..<braceIdx])
    }
    let lc = body.lowercased()
    if lc.hasPrefix("ack"), body.count > 3 {
        return .message(to: to, body: "ack", msgNum: String(body.dropFirst(3)), isAck: true, isRej: false)
    }
    if lc.hasPrefix("rej"), body.count > 3 {
        return .message(to: to, body: "rej", msgNum: String(body.dropFirst(3)), isAck: false, isRej: true)
    }
    return .message(to: to, body: body, msgNum: msgNum, isAck: false, isRej: false)
}

// MARK: - Object

private func parseObjectPayload(_ chars: [Character], text: String) -> APRSInfo? {
    // ";NAME_____*DDHHMMz<position><comment>" — name 9 chars, position at 17
    guard chars.count > 29 else { return nil }
    let name = String(chars[1..<10]).trimmingCharacters(in: .whitespaces)
    var lat: Double? = nil
    var lon: Double? = nil
    var comment = ""
    if case let .position(pLat, pLon, _, _, pComment, _)? = parsePositionPayload(chars, cursor: 17) {
        lat = pLat
        lon = pLon
        comment = pComment
    }
    return .object(name: name, lat: lat, lon: lon, comment: comment)
}

// MARK: - Weather

// Subset of Android's WeatherParser regex patterns.
private func parseWeatherReport(_ report: String) -> APRSWeather {
    var wx = APRSWeather()
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: report, range: NSRange(report.startIndex..., in: report))
        else { return nil }
        return (1..<m.numberOfRanges).map {
            Range(m.range(at: $0), in: report).map { String(report[$0]) } ?? ""
        }
    }
    if let g = firstMatch("(?:^|_)(\\d{3})/(\\d{3})") {
        wx.windDirDeg = Int(g[0])
        wx.windMph = Int(g[1])
    }
    if let g = firstMatch("g(\\d{3})") { wx.windGustMph = Int(g[0]) }
    if let g = firstMatch("t(-?\\d{2,3})") { wx.temperatureF = Int(g[0]) }
    if let g = firstMatch("r(\\d{3})") { wx.rainLastHourIn = Double(g[0]).map { $0 / 100.0 } }
    if let g = firstMatch("h(\\d{2})") {
        var hum = Int(g[0]) ?? 0
        if hum == 0 { hum = 100 }
        wx.humidity = hum
    }
    if let g = firstMatch("b(\\d{5})") { wx.pressureMb = Double(g[0]).map { $0 / 10.0 } }
    return wx
}

// MARK: - Builders (TX)

// Mirrors Position.toCompressedString: "/YYYYXXXX$ sT" (base-91).
// Returned string does NOT include the leading DTI.
func compressedPositionString(lat: Double, lon: Double,
                              symbolTable: Character = "/",
                              symbolCode: Character) -> String {
    let latR = (lat * 100000).rounded() / 100000
    let lonR = (lon * 100000).rounded() / 100000
    var latBase = Int((380926 * (90 - latR)).rounded())
    var lonBase = Int((190463 * (180 + lonR)).rounded())
    var out = String(symbolTable)
    var latChars = [Character]()
    var lonChars = [Character]()
    for div in [91 * 91 * 91, 91 * 91, 91, 1] {
        latChars.append(Character(UnicodeScalar(latBase / div + 33)!))
        latBase %= div
        lonChars.append(Character(UnicodeScalar(lonBase / div + 33)!))
        lonBase %= div
    }
    out += String(latChars) + String(lonChars) + String(symbolCode) + " sT"
    return out
}

// Mirrors MessagePacket.createMessagePayload.
func messagePayload(to recipient: String, text: String, msgNum: String?) -> String {
    let padded = recipient.padding(toLength: 9, withPad: " ", startingAt: 0)
    var idSuffix = ""
    if let num = msgNum?.trimmingCharacters(in: .whitespaces), !num.isEmpty {
        idSuffix = "{" + String(num.prefix(5))
    }
    let maxText = 67 - idSuffix.count
    let body = String(text.prefix(maxText))
    return ":" + padded + ":" + body + idSuffix
}
