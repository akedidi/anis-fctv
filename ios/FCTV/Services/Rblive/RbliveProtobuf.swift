import CryptoKit
import Foundation

// MARK: - MD5 (Java `MessageDigestUtils.md5` compatible: UTF-8 input, lowercase hex)

enum RbliveDigest {
    static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func pathPrefix6(fromSignedQuery signed: String) -> String {
        let hex = md5Hex(signed)
        return String(hex.prefix(6))
    }
}

// MARK: - Minimal protobuf wire reader (lite runtime subset)

struct RbliveProtoCursor {
    private(set) var data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) { self.data = data }

    var isAtEnd: Bool { offset >= data.count }

    mutating func readTag() -> UInt32? {
        guard let v = readVarint32() else { return nil }
        return v
    }

    mutating func readVarint32() -> UInt32? {
        guard let v = readVarint64() else { return nil }
        return UInt32(truncatingIfNeeded: v)
    }

    mutating func readVarint64() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var pos = offset
        while pos < data.count {
            let byte = data[pos]
            pos += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                offset = pos
                return value
            }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    mutating func readLengthDelimited() -> Data? {
        guard let len64 = readVarint64(), len64 <= UInt64(data.count - offset) else { return nil }
        let len = Int(len64)
        let slice = data.subdata(in: offset ..< (offset + len))
        offset += len
        return slice
    }

    mutating func skipField(wireType: UInt8) {
        switch wireType {
        case 0:
            _ = readVarint64()
        case 1:
            offset += 8
        case 2:
            guard let len = readVarint64() else { return }
            offset += Int(len)
        case 5:
            offset += 4
        default:
            break
        }
    }
}

enum RbliveProtobuf {
    /// Unwraps `PBResponse`-style envelopes: primary payload is field **10** (used by match live / detail / bs).
    /// Some endpoints (e.g. stream detail) may expose the nested payload on field **2** instead.
    static func pbResponseDataField(_ response: Data) throws -> Data {
        var c = RbliveProtoCursor(response)
        var field10: Data?
        var field2: Data?
        var field1: Data?
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            if wire == 2, let payload = c.readLengthDelimited() {
                if field == 10 { field10 = payload }
                else if field == 2, field2 == nil { field2 = payload }
                else if field == 1, field1 == nil { field1 = payload }
                continue
            }
            var mut = c
            mut.skipField(wireType: wire)
            c = mut
        }
        if let field10, !field10.isEmpty { return field10 }
        if let field2, !field2.isEmpty { return field2 }
        if let field1, !field1.isEmpty { return field1 }
        throw RbliveAPIError.invalidProtobuf("PBResponse.data missing")
    }

    /// Parses `PBBodySignatureResp.kv` map<int32,string> (field 1 entries).
    static func parseBodySignatureKV(_ data: Data) throws -> [Int32: String] {
        var out: [Int32: String] = [:]
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            guard field == 1, wire == 2, let entry = c.readLengthDelimited() else {
                var m = c
                m.skipField(wireType: wire)
                c = m
                continue
            }
            if let (k, v) = parseMapInt32StringEntry(entry) {
                out[k] = v
            }
        }
        return out
    }

    private static func parseMapInt32StringEntry(_ entry: Data) -> (Int32, String)? {
        var key: Int32?
        var value: String?
        var c = RbliveProtoCursor(entry)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            if field == 1, wire == 0, let v = c.readVarint32() {
                key = Int32(bitPattern: v)
            } else if field == 2, wire == 2, let bytes = c.readLengthDelimited() {
                value = String(data: bytes, encoding: .utf8)
            } else {
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        if let key, let value { return (key, value) }
        return nil
    }

    /// `PBMatchLiveResp`: repeated `match` (1) and `stream` (2) as raw submessages.
    static func splitMatchLive(_ data: Data) -> (matches: [Data], streams: [Data]) {
        var matches: [Data] = []
        var streams: [Data] = []
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            guard wire == 2, let chunk = c.readLengthDelimited() else {
                var m = c
                m.skipField(wireType: wire)
                c = m
                continue
            }
            if field == 1 { matches.append(chunk) }
            else if field == 2 { streams.append(chunk) }
        }
        return (matches, streams)
    }

    /// `PBMatchDetailResp`: single `match` (1), repeated `stream` (2).
    static func splitMatchDetail(_ data: Data) -> (match: Data?, streams: [Data]) {
        var matchData: Data?
        var streams: [Data] = []
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            guard wire == 2, let chunk = c.readLengthDelimited() else {
                var m = c
                m.skipField(wireType: wire)
                c = m
                continue
            }
            if field == 1 { matchData = chunk }
            else if field == 2 { streams.append(chunk) }
        }
        return (matchData, streams)
    }

    /// `PBDataStream` scan for list/detail rows (Android 323 / proto):
    /// field 1=`streamId`, 2=`sportType`, 3=`name`, 4=`url`, 5=`streamStatus`,
    /// 8=`priority` or name/url string, 9=`siteType`, 10=`fullName`, 15=fallback name,
    /// 50=`matchId`, 100=`original_info` encrypted blob.
    static func parseStreamRow(_ data: Data) -> (
        name: String,
        fullName: String,
        url: String?,
        streamId: Int64,
        siteType: Int32,
        matchId: UInt64?,
        originalInfoWire: Data?
    ) {
        var name = ""
        var fullName = ""
        var url: String?
        var streamId: Int64 = 0
        var siteType: Int32 = 0
        var matchId: UInt64?
        var originalInfoWire: Data?
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            switch (field, wire) {
            case (1, 0):
                if let v = c.readVarint64() { streamId = Int64(bitPattern: v) }
            case (3, 2):
                if let bytes = c.readLengthDelimited() {
                    let s = String(data: bytes, encoding: .utf8) ?? ""
                    if !s.isEmpty, s != "Success", s != "OK" { name = s }
                }
            case (4, 2):
                if let bytes = c.readLengthDelimited() {
                    url = String(data: bytes, encoding: .utf8) ?? ""
                }
            case (8, 2):
                if let bytes = c.readLengthDelimited() {
                    let s = String(data: bytes, encoding: .utf8) ?? ""
                    if s.lowercased().hasPrefix("http") {
                        if url == nil || url?.isEmpty == true { url = s }
                    } else if !s.isEmpty, fullName.isEmpty {
                        fullName = s
                    }
                }
            case (8, 0):
                _ = c.readVarint32() // priority
            case (9, 0):
                if let v = c.readVarint32() { siteType = Int32(bitPattern: v) }
            case (10, 2):
                if let bytes = c.readLengthDelimited() {
                    let s = String(data: bytes, encoding: .utf8) ?? ""
                    if !s.isEmpty { fullName = s }
                }
            case (15, 2):
                if let bytes = c.readLengthDelimited() {
                    let s = String(data: bytes, encoding: .utf8) ?? ""
                    if name.isEmpty, !s.isEmpty { name = s }
                }
            case (50, 0):
                matchId = c.readVarint64()
            case (100, 2):
                originalInfoWire = c.readLengthDelimited()
            default:
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        name = sanitizeDisplayLabel(name)
        fullName = sanitizeDisplayLabel(fullName)
        if name.isEmpty, !fullName.isEmpty { name = fullName }
        return (name, fullName, url, streamId, siteType, matchId, originalInfoWire)
    }

    /// `PBDataStreamOriginalInfo`: `url` (4), `headers` map (20).
    static func parseDataStreamOriginalInfo(_ data: Data) throws -> RbliveDecodedStreamOriginal {
        var url = ""
        var headers: [String: String] = [:]
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            if field == 4, wire == 2, let bytes = c.readLengthDelimited() {
                url = String(data: bytes, encoding: .utf8) ?? ""
            } else if field == 20, wire == 2, let entry = c.readLengthDelimited() {
                if let (k, v) = parseMapStringStringEntry(entry) {
                    headers[k] = v
                }
            } else {
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        return RbliveDecodedStreamOriginal(url: url, headers: headers)
    }

    private static func parseMapStringStringEntry(_ entry: Data) -> (String, String)? {
        var key: String?
        var value: String?
        var c = RbliveProtoCursor(entry)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            if field == 1, wire == 2, let b = c.readLengthDelimited() {
                key = String(data: b, encoding: .utf8)
            } else if field == 2, wire == 2, let b = c.readLengthDelimited() {
                value = String(data: b, encoding: .utf8)
            } else {
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        if let key, let value { return (key, value) }
        return nil
    }

    /// Collects all length-delimited UTF-8 strings in a protobuf submessage (order preserved).
    private static func collectUTF8StringsFromMessage(_ data: Data) -> [String] {
        var out: [String] = []
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let wire = UInt8(tag & 7)
            if wire == 2, let bytes = c.readLengthDelimited(), let s = String(data: bytes, encoding: .utf8), !s.isEmpty {
                out.append(s)
            } else {
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        return out
    }

    /// Picks a player-like label (not a URL, reasonable length).
    private static func pickPlayerLabel(from strings: [String]) -> String? {
        for s in strings {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.contains("://") { continue }
            if t.count < 2 || t.count > 64 { continue }
            return t
        }
        return nil
    }

    /// Best-effort team/player parse (`PBDataTeam`): name + logo URL (field 4 / http strings).
    static func parseTeamBlob(_ data: Data) -> (name: String, logoURL: URL?) {
        var name = ""
        var logo: String?
        var strings: [String] = []
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            switch (field, wire) {
            case (2, 2), (4, 2):
                if let bytes = c.readLengthDelimited(), let s = String(data: bytes, encoding: .utf8) {
                    strings.append(s)
                    if s.lowercased().hasPrefix("http") {
                        if logo == nil { logo = s }
                    } else if name.isEmpty, s.count > 1, s.count <= 80 {
                        name = s
                    }
                }
            case (3, 2):
                if let bytes = c.readLengthDelimited() {
                    if let mapName = parseMapStringValue(bytes), !mapName.isEmpty {
                        if name.isEmpty { name = mapName }
                    } else if let s = String(data: bytes, encoding: .utf8) {
                        strings.append(s)
                        if s.lowercased().hasPrefix("http"), logo == nil {
                            logo = s
                        } else if name.isEmpty, s.count > 1 {
                            name = s
                        }
                    }
                }
            case (10, 2), (20, 2):
                if let nested = c.readLengthDelimited() {
                    let t = parseTeamBlob(nested)
                    if name.isEmpty, !t.name.isEmpty { name = t.name }
                    if logo == nil, let u = t.logoURL { logo = u.absoluteString }
                }
            default:
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        if name.isEmpty, let label = pickPlayerLabel(from: strings) { name = label }
        if logo == nil {
            logo = strings.first(where: {
                $0.lowercased().hasPrefix("http") && ($0.contains("logo") || $0.contains("team") || $0.contains("aelogo"))
            }) ?? strings.first(where: { $0.lowercased().hasPrefix("http") })
        }
        return (name, normalizeLogoURL(logo))
    }

    /// Competition blob (match field 10). Live API often packs `name` inside nested field 3
    /// (looks like UTF-8 but starts with protobuf tags e.g. `0x08`); logo is usually a top-level http string.
    static func parseCompetitionBlob(_ data: Data) -> (name: String, logoURL: URL?) {
        var fieldStrings: [Int: [String]] = [:]
        var logo: String?
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = Int(tag >> 3)
            let wire = UInt8(tag & 7)
            if wire == 2, let bytes = c.readLengthDelimited() {
                // Always harvest nested printable strings — field 3 is frequently a sub-message.
                let nested = extractPrintableStrings(from: bytes, depth: 0)
                for s in nested {
                    if s.lowercased().hasPrefix("http") {
                        if logo == nil { logo = s }
                    } else if isPlausibleCompetitionName(s) {
                        fieldStrings[field, default: []].append(s)
                    }
                }
                if let s = String(data: bytes, encoding: .utf8) {
                    let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.lowercased().hasPrefix("http") {
                        if logo == nil { logo = cleaned }
                    } else if isPlausibleCompetitionName(cleaned) {
                        fieldStrings[field, default: []].append(cleaned)
                    }
                }
            } else {
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }

        // Prefer field 3 (canonical name), then other text fields, then longest label.
        let preferredFields = [3, 2, 15, 5, 10, 4, 1]
        var name = ""
        for f in preferredFields {
            if let raw = fieldStrings[f]?.max(by: { $0.count < $1.count }) {
                name = raw
                break
            }
        }
        if name.isEmpty {
            name = fieldStrings.values.flatMap { $0 }.max(by: { $0.count < $1.count }) ?? ""
        }
        name = sanitizeDisplayLabel(name)
        // Relative logo filename in field 4 (e.g. `<hash>.png!w80`) when no absolute URL was present.
        if logo == nil {
            let relCandidates = (fieldStrings[4] ?? []) + (fieldStrings[5] ?? [])
            if let rel = relCandidates.first(where: {
                $0.localizedCaseInsensitiveContains(".png")
                    || $0.localizedCaseInsensitiveContains(".jpg")
                    || ($0.count >= 32 && $0.range(of: #"^[0-9a-fA-F.]+$"#, options: .regularExpression) != nil)
            }) {
                var file = rel
                if let bang = file.firstIndex(of: "!") { file = String(file[..<bang]) }
                if !file.contains("/") {
                    logo = "https://\(preferredLogosHost)/aelogo/competition/\(file)"
                } else if !file.lowercased().hasPrefix("http") {
                    logo = file.hasPrefix("/")
                        ? "https://\(preferredLogosHost)\(file)"
                        : "https://\(preferredLogosHost)/\(file)"
                }
            }
        }
        // Don't keep hash-like filenames as the display name.
        if name.localizedCaseInsensitiveContains(".png") || name.localizedCaseInsensitiveContains(".jpg") {
            name = ""
        }
        if ProcessInfo.processInfo.environment["FCTV_DEBUG_COMP"] == "1" {
            let dump = fieldStrings
                .sorted(by: { $0.key < $1.key })
                .map { "f\($0.key)=\($0.value.map { String($0.prefix(60)) }.joined(separator: "|"))" }
                .joined(separator: " ")
            fputs("[comp] name=\(name.isEmpty ? "<empty>" : name) logo=\(logo?.prefix(80) ?? "-") \(dump)\n", stderr)
        }
        return (name, normalizeLogoURL(logo))
    }

    /// True for human-readable competition labels (reject pure ids / paths / control chars).
    private static func isPlausibleCompetitionName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return false }
        if t.lowercased().hasPrefix("http") { return false }
        if t.contains("/") { return false }
        if t.localizedCaseInsensitiveContains(".png") || t.localizedCaseInsensitiveContains(".jpg") { return false }
        if t.range(of: #"^\d+$"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"^[0-9a-fA-F]{16,}$"#, options: .regularExpression) != nil { return false }
        // Reject protobuf-looking blobs that decoded as “UTF-8” with control bytes.
        guard t.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return false }
        // Prefer labels that look like words (at least one letter).
        guard t.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        return true
    }

    /// Strip i18n `$` keys, season prefixes like `2024:` / `24-25:`.
    static func sanitizeDisplayLabel(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("$") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^\d{2,4}(-\d{2,4})?\s*:\s*"#, with: "", options: .regularExpression)
        if s == "Success" || s == "OK" { return "" }
        return s
    }

    private static func extractPrintableStrings(from data: Data, depth: Int) -> [String] {
        guard depth < 4, !data.isEmpty else { return [] }
        var out: [String] = []
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let wire = UInt8(tag & 7)
            if wire == 2, let bytes = c.readLengthDelimited() {
                if let s = String(data: bytes, encoding: .utf8) {
                    let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty,
                       cleaned.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) {
                        out.append(cleaned)
                    }
                }
                // Recurse: localized name maps / nested competition info.
                out.append(contentsOf: extractPrintableStrings(from: bytes, depth: depth + 1))
            } else {
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        return out
    }

    /// Country blob (match field 11).
    static func parseCountryBlob(_ data: Data) -> (name: String, logoURL: URL?) {
        var candidates: [String] = []
        var logo: String?
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let wire = UInt8(tag & 7)
            if wire == 2, let bytes = c.readLengthDelimited(), let s = String(data: bytes, encoding: .utf8) {
                let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                let isYear = cleaned.range(of: #"^\d{4}$"#, options: .regularExpression) != nil
                if cleaned.lowercased().hasPrefix("http") {
                    if logo == nil { logo = cleaned }
                } else if !cleaned.isEmpty, cleaned.count > 1, !cleaned.contains("/"), !isYear,
                          cleaned.unicodeScalars.allSatisfy({ $0.value >= 32 }) {
                    candidates.append(cleaned)
                }
            } else {
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        let name = candidates.max(by: { $0.count < $1.count }) ?? ""
        return (name, normalizeLogoURL(logo))
    }

    /// Working logos CDN (API hosts rotate / Cloudflare-block; this one currently resolves).
    private static let preferredLogosHost = "logos1.ta2mnt200stayr2.cfd"

    /// Rewrite rotating logo hosts and strip image-processor suffixes (`!w80`).
    static func normalizeLogoURL(_ raw: String?) -> URL? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if let bang = s.firstIndex(of: "!") {
            s = String(s[..<bang])
        }
        // Keep path, force preferred host when URL points at any logos*.*.cfd host.
        if let u = URL(string: s), let host = u.host?.lowercased(),
           host.contains("logos"), host.hasSuffix(".cfd"),
           host != preferredLogosHost {
            var comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
            comps?.host = preferredLogosHost
            if let rebuilt = comps?.url { return rebuilt }
        }
        if s.contains("logos") && s.contains(".cfd") == false {
            // relative path fallback
            if s.hasPrefix("/") {
                return URL(string: "https://\(preferredLogosHost)\(s)")
            }
        }
        return URL(string: s)
    }

    /// protobuf map<string,string> entry — value is field 2.
    private static func parseMapStringValue(_ entry: Data) -> String? {
        var value: String?
        var c = RbliveProtoCursor(entry)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            if field == 2, wire == 2, let b = c.readLengthDelimited() {
                value = String(data: b, encoding: .utf8)
            } else {
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        return value
    }

    /// Best-effort `PBDataMatch` parse for list rows.
    static func parseDataMatch(_ data: Data) -> RbliveParsedMatch? {
        var matchId: UInt64?
        var sportType: Int32?
        var matchDateMs: UInt64?
        var statusCode: Int32?
        var leagueName: String?
        var leagueLogoURL: URL?
        var region = ""
        var regionLogoURL: URL?
        var homeName: String?
        var awayName: String?
        var homeLogoURL: URL?
        var awayLogoURL: URL?
        var homeScore: Int32?
        var awayScore: Int32?
        var hot = false
        var teamBlobIndex = 0
        /// Field 5 `gameTime` string when present (legacy / non-football).
        var gameTimeRaw: String?
        /// Field 150 `ftbMatchExtra` — authoritative football timer (kickoff timestamps).
        var ftbExtra: RbliveFtbMatchExtra?

        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            switch (field, wire) {
            case (1, 0):
                matchId = c.readVarint64()
            case (2, 0):
                if let v = c.readVarint32() { sportType = Int32(bitPattern: v) }
            case (3, 0):
                matchDateMs = c.readVarint64()
            case (4, 0):
                if let v = c.readVarint32() { statusCode = Int32(bitPattern: v) }
            case (5, 2):
                // `gameTime` — UTF-8 clock label from API (e.g. `76` / `76'` / `HT`).
                if let bytes = c.readLengthDelimited(),
                   let s = String(data: bytes, encoding: .utf8) {
                    let cleaned = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleaned.isEmpty { gameTimeRaw = cleaned }
                }
            case (10, 2):
                if let inner = c.readLengthDelimited() {
                    let comp = parseCompetitionBlob(inner)
                    if !comp.name.isEmpty { leagueName = comp.name }
                    if leagueLogoURL == nil { leagueLogoURL = comp.logoURL }
                }
            case (11, 2):
                if let inner = c.readLengthDelimited() {
                    let country = parseCountryBlob(inner)
                    if !country.name.isEmpty { region = country.name }
                    if regionLogoURL == nil { regionLogoURL = country.logoURL }
                }
            case (20, 2):
                if let inner = c.readLengthDelimited() {
                    let team = parseTeamBlob(inner)
                    if !team.name.isEmpty { homeName = team.name }
                    if homeLogoURL == nil { homeLogoURL = team.logoURL }
                }
            case (21, 2):
                if let inner = c.readLengthDelimited() {
                    let team = parseTeamBlob(inner)
                    if !team.name.isEmpty { awayName = team.name }
                    if awayLogoURL == nil { awayLogoURL = team.logoURL }
                }
            case (30, 2):
                if let inner = c.readLengthDelimited() {
                    let team = parseTeamBlob(inner)
                    // First blob is often "Home vs Away" title without logos; later blobs are real teams.
                    if team.name.localizedCaseInsensitiveContains(" vs ") {
                        let parts = team.name.components(separatedBy: " vs ")
                        if parts.count >= 2 {
                            let h = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                            let a = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                            if homeName == nil || homeName?.isEmpty == true, !h.isEmpty { homeName = h }
                            if awayName == nil || awayName?.isEmpty == true, !a.isEmpty { awayName = a }
                        }
                        // Prefer nested logo if present on the title blob.
                        if homeLogoURL == nil { homeLogoURL = team.logoURL }
                    } else if !team.name.isEmpty || team.logoURL != nil {
                        if teamBlobIndex == 0 {
                            if !team.name.isEmpty { homeName = team.name }
                            if let u = team.logoURL { homeLogoURL = u }
                            teamBlobIndex = 1
                        } else if teamBlobIndex == 1 {
                            if !team.name.isEmpty { awayName = team.name }
                            if let u = team.logoURL { awayLogoURL = u }
                            teamBlobIndex = 2
                        }
                    }
                }
            case (22, 0):
                if let v = c.readVarint32() { homeScore = Int32(bitPattern: v) }
            case (23, 0):
                if let v = c.readVarint32() { awayScore = Int32(bitPattern: v) }
            case (80, 0):
                if let v = c.readVarint32() { hot = v != 0 }
            case (150, 2):
                // `ftbMatchExtra` — football half kickoff timestamps → accurate `76'`.
                if let bytes = c.readLengthDelimited() {
                    ftbExtra = parseFtbMatchExtra(bytes)
                }
            default:
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }

        // Non-team / "Other" (90) events often omit date or status — don't drop them.
        guard let matchId, let sportType else {
            fputs("[proto] skip match missing id/sportType\n", stderr)
            return nil
        }
        let resolvedStatus = statusCode ?? 0
        let date: Date
        if let matchDateMs, matchDateMs > 0 {
            date = Date(timeIntervalSince1970: Double(matchDateMs) / 1000.0)
        } else {
            date = Date()
        }
        let clock = Self.resolveLiveClock(
            statusCode: resolvedStatus,
            ftbExtra: ftbExtra,
            gameTime: gameTimeRaw
        )
        return RbliveParsedMatch(
            matchId: matchId,
            sportType: sportType,
            startDate: date,
            statusCode: resolvedStatus,
            leagueName: leagueName ?? "",
            leagueLogoURL: leagueLogoURL,
            region: region,
            regionLogoURL: regionLogoURL,
            homeName: homeName ?? "",
            awayName: awayName ?? "",
            homeLogoURL: homeLogoURL,
            awayLogoURL: awayLogoURL,
            homeScore: homeScore,
            awayScore: awayScore,
            hot: hot,
            liveClock: clock
        )
    }

    /// Parse `PBDataMatch.ftbMatchExtra` (field 150) — same layout as fctv33 `FtbMatchExtra`.
    static func parseFtbMatchExtra(_ data: Data) -> RbliveFtbMatchExtra {
        var minuteStatus = ""
        var minute: Int32 = 0
        var firstStartMs: Int64 = 0
        var secondStartMs: Int64 = 0
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            switch (field, wire) {
            case (1, 2):
                if let bytes = c.readLengthDelimited(),
                   let s = String(data: bytes, encoding: .utf8) {
                    minuteStatus = s.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            case (2, 0):
                if let v = c.readVarint32() { minute = Int32(bitPattern: v) }
            case (3, 0):
                if let v = c.readVarint64() { firstStartMs = Int64(bitPattern: v) }
            case (4, 0):
                if let v = c.readVarint64() { secondStartMs = Int64(bitPattern: v) }
            default:
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        return RbliveFtbMatchExtra(
            minute: minute,
            minuteStatus: minuteStatus,
            firstStartMs: firstStartMs,
            secondStartMs: secondStartMs
        )
    }

    /// Server-backed clock only — never invent a green "LIVE" label.
    /// Priority: field 150 timestamps → field 150 minute → field 5 `gameTime`.
    private static func resolveLiveClock(
        statusCode: Int32,
        ftbExtra: RbliveFtbMatchExtra?,
        gameTime: String?
    ) -> String? {
        if statusCode == 0 || statusCode >= 10_000 { return nil }

        if let extra = ftbExtra {
            if let label = extra.formattedClock() { return label }
        }
        if let raw = gameTime?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let upper = raw.uppercased()
            // Ignore useless status words — cells need a real clock.
            if upper == "LIVE" || upper == "SUCCESS" || upper == "OK" { return nil }
            if raw.range(of: #"^\d+$"#, options: .regularExpression) != nil {
                return "\(raw)'"
            }
            return raw
        }
        return nil
    }

    static func extractUTF8StringField(_ message: Data, fieldNumber: Int) -> String? {
        var c = RbliveProtoCursor(message)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            if field == UInt32(fieldNumber), wire == 2, let bytes = c.readLengthDelimited() {
                return String(data: bytes, encoding: .utf8)
            }
            var m = c
            m.skipField(wireType: wire)
            c = m
        }
        return nil
    }

    /// Pulls first `https://` URL from UTF-8 lossy data (some payloads embed URL in binary).
    static func firstHTTPURL(in string: String) -> URL? {
        if let r = string.range(of: #"https://[^\s"']+"#, options: .regularExpression) {
            return URL(string: String(string[r]))
        }
        return nil
    }

    /// `PBMatchLineupResp`: repeated `homeLineup` (1) / `awayLineup` (2) as `PBDataMatchLineup`.
    static func parseMatchLineup(_ data: Data) -> MatchLineup {
        var home: [MatchLineupPlayer] = []
        var away: [MatchLineupPlayer] = []
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            guard wire == 2, let chunk = c.readLengthDelimited() else {
                var m = c
                m.skipField(wireType: wire)
                c = m
                continue
            }
            if let player = parseDataMatchLineup(chunk) {
                if field == 1 { home.append(player) }
                else if field == 2 { away.append(player) }
            }
        }
        return MatchLineup(home: home, away: away)
    }

    /// `PBDataMatchLineup`: player (1), position (2), positionOrder (3), appearance (4), number (5).
    private static func parseDataMatchLineup(_ data: Data) -> MatchLineupPlayer? {
        var playerBlob: Data?
        var position: Int32 = 0
        var positionOrder: Int32 = 999
        var appearance: Int32 = 0
        var number: String?
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            switch (field, wire) {
            case (1, 2):
                playerBlob = c.readLengthDelimited()
            case (2, 0):
                if let v = c.readVarint32() { position = Int32(bitPattern: v) }
            case (3, 0):
                if let v = c.readVarint32() { positionOrder = Int32(bitPattern: v) }
            case (4, 0):
                if let v = c.readVarint32() { appearance = Int32(bitPattern: v) }
            case (5, 2):
                if let bytes = c.readLengthDelimited() {
                    number = String(data: bytes, encoding: .utf8)
                }
            default:
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        guard let playerBlob else { return nil }
        let (playerId, name) = parseDataPlayer(playerBlob)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let idBase = playerId.map(String.init) ?? trimmed
        let shirt = number?.trimmingCharacters(in: .whitespacesAndNewlines)
        return MatchLineupPlayer(
            id: "\(idBase)-\(shirt ?? "")-\(positionOrder)",
            name: trimmed,
            number: (shirt?.isEmpty == false) ? shirt : nil,
            positionLabel: positionLabel(position),
            positionOrder: Int(positionOrder),
            isStarter: appearance == 1
        )
    }

    /// `PBDataPlayer`: playerId (1), name map<int32,string> (3).
    private static func parseDataPlayer(_ data: Data) -> (playerId: UInt64?, name: String) {
        var playerId: UInt64?
        var names: [Int32: String] = [:]
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            if field == 1, wire == 0, let v = c.readVarint64() {
                playerId = v
            } else if field == 3, wire == 2, let entry = c.readLengthDelimited(),
                      let (k, v) = parseMapInt32StringEntry(entry) {
                names[k] = v
            } else {
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        let name = names[1] ?? names[0] ?? names.values.first ?? ""
        return (playerId, name)
    }

    private static func positionLabel(_ position: Int32) -> String {
        switch position {
        case 1: return "FWD"
        case 2: return "MID"
        case 3: return "DEF"
        case 4: return "GK"
        default: return "—"
        }
    }

    /// `PBMatchEventResp`: repeated `event` (1) as `PBDataMatchEvent`.
    /// Returns newest-first rows for the Overview timeline.
    static func parseMatchEvents(_ data: Data) -> [MatchHighlight] {
        var chronological: [MatchHighlight] = []
        var index = 0
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            guard field == 1, wire == 2, let chunk = c.readLengthDelimited() else {
                var m = c
                m.skipField(wireType: wire)
                c = m
                continue
            }
            if let row = parseDataMatchEvent(chunk, index: index) {
                chronological.append(row)
                index += 1
            }
        }
        return chronological.reversed()
    }

    /// `PBDataMatchEvent`: type (3), minute (4), score (5), reason (6), side (7),
    /// scorer (10), assist (11), booked (20), subIn (30), subOut (31).
    private static func parseDataMatchEvent(_ data: Data, index: Int) -> MatchHighlight? {
        var type: Int32 = 0
        var minute = ""
        var score = ""
        var reason = ""
        var side: Int32 = 0
        var scorerBlob: Data?
        var assistBlob: Data?
        var bookedBlob: Data?
        var subInBlob: Data?
        var subOutBlob: Data?

        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            switch (field, wire) {
            case (3, 0):
                if let v = c.readVarint32() { type = Int32(bitPattern: v) }
            case (4, 2):
                if let bytes = c.readLengthDelimited() {
                    minute = String(data: bytes, encoding: .utf8) ?? ""
                }
            case (5, 2):
                if let bytes = c.readLengthDelimited() {
                    score = String(data: bytes, encoding: .utf8) ?? ""
                }
            case (6, 2):
                if let bytes = c.readLengthDelimited() {
                    reason = String(data: bytes, encoding: .utf8) ?? ""
                }
            case (7, 0):
                if let v = c.readVarint32() { side = Int32(bitPattern: v) }
            case (10, 2):
                scorerBlob = c.readLengthDelimited()
            case (11, 2):
                assistBlob = c.readLengthDelimited()
            case (20, 2):
                bookedBlob = c.readLengthDelimited()
            case (30, 2):
                subInBlob = c.readLengthDelimited()
            case (31, 2):
                subOutBlob = c.readLengthDelimited()
            default:
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }

        let scorer = scorerBlob.map { parseDataPlayer($0).name.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let assist = assistBlob.map { parseDataPlayer($0).name.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let booked = bookedBlob.map { parseDataPlayer($0).name.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let subIn = subInBlob.map { parseDataPlayer($0).name.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        let subOut = subOutBlob.map { parseDataPlayer($0).name.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""

        let kind: MatchHighlight.Kind
        let text: String
        switch type {
        case 101:
            kind = .goal
            var t = "Goal"
            if !scorer.isEmpty { t += " — \(scorer)" }
            if !assist.isEmpty { t += " (assist \(assist))" }
            if !score.isEmpty { t += " · \(score)" }
            text = t
        case 102:
            kind = .goal
            var t = "Own goal"
            if !scorer.isEmpty { t += " — \(scorer)" }
            if !score.isEmpty { t += " · \(score)" }
            text = t
        case 103:
            kind = .goal
            var t = "Penalty"
            if !scorer.isEmpty { t += " — \(scorer)" }
            if !score.isEmpty { t += " · \(score)" }
            text = t
        case 105:
            kind = .info
            if !subIn.isEmpty, !subOut.isEmpty {
                text = "Sub — \(subIn) on for \(subOut)"
            } else if !subIn.isEmpty {
                text = "Sub — \(subIn) on"
            } else if !subOut.isEmpty {
                text = "Sub — \(subOut) off"
            } else {
                text = "Substitution"
            }
        case 106:
            kind = .info
            var t = "Yellow card"
            if !booked.isEmpty { t += " — \(booked)" }
            if !reason.isEmpty { t += " · \(reason)" }
            text = t
        case 107:
            kind = .info
            var t = "Red card"
            if !booked.isEmpty { t += " — \(booked)" }
            if !reason.isEmpty { t += " · \(reason)" }
            text = t
        case 108:
            kind = .info
            var t = "Second yellow"
            if !booked.isEmpty { t += " — \(booked)" }
            if !reason.isEmpty { t += " · \(reason)" }
            text = t
        case 10001:
            kind = .status
            text = "Kick-off"
        case 10002:
            kind = .status
            text = "Second half"
        case 10003:
            kind = .status
            text = score.isEmpty ? "Half-time" : "Half-time · \(score)"
        case 10005:
            kind = .status
            text = score.isEmpty ? "Full time" : "Full time · \(score)"
        default:
            return nil
        }

        let id = "ev-\(type)-\(minute)-\(index)-\(side)-\(scorer)-\(booked)-\(subIn)-\(score)"
        return MatchHighlight(id: id, minute: minute, text: text, kind: kind)
    }

    /// Reads `PBResponse.code` (field 2) and `message` (field 3) if present.
    static func parsePBResponseCodeAndMessage(_ data: Data) -> (code: Int32?, message: String?) {
        var code: Int32?
        var message: String?
        var c = RbliveProtoCursor(data)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            switch (field, wire) {
            case (2, 0):
                if let v = c.readVarint32() { code = Int32(bitPattern: v) }
            case (3, 2):
                if let bytes = c.readLengthDelimited() {
                    message = String(data: bytes, encoding: .utf8)
                }
            default:
                var m = c
                m.skipField(wireType: wire)
                c = m
            }
        }
        return (code, message)
    }
}

/// Decrypted `PBDataStreamOriginalInfo` (Android `decodeOriginalInfo`).
struct RbliveDecodedStreamOriginal: Sendable {
    let url: String
    let headers: [String: String]
}

/// Football timer blob (`PBDataMatch` field 150) — kickoff timestamps drive `76'`.
struct RbliveFtbMatchExtra: Sendable {
    let minute: Int32
    let minuteStatus: String
    let firstStartMs: Int64
    let secondStartMs: Int64

    /// Same algorithm as fctv33 `FtbMatchExtra.computedMinute` / `period`.
    func formattedClock(now: Date = Date()) -> String? {
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        if secondStartMs > 0, nowMs >= secondStartMs {
            let elapsed = Int((nowMs - secondStartMs) / 60_000)
            let total = 45 + max(0, elapsed)
            if total > 90 { return "90+'" }
            return "\(total)'"
        }
        if firstStartMs > 0, nowMs >= firstStartMs {
            let elapsed = Int((nowMs - firstStartMs) / 60_000)
            if elapsed > 45, secondStartMs == 0 || nowMs < secondStartMs {
                return "HT"
            }
            let clamped = min(max(elapsed, 0), 45)
            if clamped == 0 { return "1'" }
            return "\(clamped)'"
        }
        // Rare: API still fills discrete minute when timestamps missing.
        if minute > 0, minute <= 130 {
            return "\(minute)'"
        }
        let status = minuteStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !status.isEmpty {
            let upper = status.uppercased()
            if upper == "HT" || upper == "FT" { return upper }
            if looksLikeNumericClock(status) {
                return status.hasSuffix("'") ? status : "\(status)'"
            }
        }
        return nil
    }

    private func looksLikeNumericClock(_ s: String) -> Bool {
        s.range(of: #"^\d{1,3}(\+\d{1,2})?'?$"#, options: .regularExpression) != nil
    }
}

struct RbliveParsedMatch {
    let matchId: UInt64
    let sportType: Int32
    let startDate: Date
    let statusCode: Int32
    let leagueName: String
    let leagueLogoURL: URL?
    let region: String
    let regionLogoURL: URL?
    let homeName: String
    let awayName: String
    let homeLogoURL: URL?
    let awayLogoURL: URL?
    let homeScore: Int32?
    let awayScore: Int32?
    let hot: Bool
    let liveClock: String?
}

enum RbliveAPIError: Error, LocalizedError {
    case http(Int, String?)
    case invalidProtobuf(String)
    case missingSignature(Int)
    case missingStreamURL
    case streamCryptoFailed(String)

    var errorDescription: String? {
        switch self {
        case let .http(code, body): return "HTTP \(code): \(body ?? "")"
        case let .invalidProtobuf(msg): return msg
        case let .missingSignature(code): return "Signature manquante (code \(code))"
        case .missingStreamURL: return "URL de flux indisponible (chiffrement serveur)."
        case let .streamCryptoFailed(msg): return "Flux crypto: \(msg)"
        }
    }
}
