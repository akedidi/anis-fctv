import Foundation

/// Result of `/api/stream/detail` — mirrors `PPManager.hlsInject`: optional `HlsInjectManager.actionSimpleInject`,
/// otherwise `viaRB` / plain URL with `calcRBHeaders`-class headers plus `rb-session` in the player.
struct RbliveResolvedPlayback: Sendable {
    let url: URL
    /// Merged with `rb-session` and browser defaults in the player.
    let extraHTTPHeaders: [String: String]

    init(url: URL, extraHTTPHeaders: [String: String] = [:]) {
        self.url = url
        self.extraHTTPHeaders = extraHTTPHeaders
    }
}

/// High-level access to live schedules, match detail, and stream resolution — mirrors `MatchRepository` on Android.
enum RbliveMatchRepository {

    private static let matchDetailBSCodes = [102, 103, 104, 105, 106, 107]
    private static let liveListBSCode = 100

    /// Concrete sport types that return a full-day (+ next-day) schedule.
    /// `sportType=0` only yields a truncated "hot" slice (~50 rows, morning cutoff).
    private static let scheduleListSports: [Sport] = Sport.allSports.filter { $0 != .other }

    static func fetchLiveMatches(language: AppLanguage, sport: Sport) async throws -> [LiveMatch] {
        // All / Golf / Others need the merged per-sport schedule — not sportType=0.
        let needsFanOut = sport == .undefined || sport == .golf || sport == .other
        if needsFanOut {
            let merged = try await fetchMergedSchedule(language: language)
            if sport == .golf {
                return merged.filter { $0.matchesGolfSectionHeuristic() || $0.sport == .golf }
            }
            if sport == .other {
                return merged.filter { RbliveSportLanguage.belongsInOthersTab($0.sport) }
            }
            return merged
        }
        return try await fetchLiveMatchesForSportType(
            language: language,
            sportType: RbliveSportLanguage.sportTypeValue(sport)
        )
    }

    /// Fan-out `/api/match/live` per sport and merge by match id (full day / tomorrow).
    private static func fetchMergedSchedule(language: AppLanguage) async throws -> [LiveMatch] {
        fputs(
            "[rblive] fetchMergedSchedule sports=\(scheduleListSports.count) language=\(RbliveSportLanguage.languageValue(language))\n",
            stderr
        )
        let rows: [[LiveMatch]] = await withTaskGroup(of: [LiveMatch].self, returning: [[LiveMatch]].self) { group in
            for s in scheduleListSports {
                let st = RbliveSportLanguage.sportTypeValue(s)
                group.addTask {
                    do {
                        return try await fetchLiveMatchesForSportType(language: language, sportType: st)
                    } catch {
                        fputs(
                            "[rblive] fetchMergedSchedule sportType=\(st) failed: \(error.localizedDescription)\n",
                            stderr
                        )
                        return []
                    }
                }
            }
            var collected: [[LiveMatch]] = []
            for await batch in group {
                collected.append(batch)
            }
            return collected
        }

        var byId: [String: LiveMatch] = [:]
        for batch in rows {
            for match in batch {
                if let existing = byId[match.id] {
                    // Prefer the row that already carries stream servers.
                    if match.streams.count > existing.streams.count {
                        byId[match.id] = match
                    }
                } else {
                    byId[match.id] = match
                }
            }
        }
        let out = Array(byId.values)
        var bySport: [String: Int] = [:]
        var byStatus: [String: Int] = [:]
        for m in out {
            bySport[m.sport.rawValue, default: 0] += 1
            byStatus[m.status.rawValue, default: 0] += 1
        }
        let sportSummary = bySport.keys.sorted().map { "\($0)=\(bySport[$0]!)" }.joined(separator: " ")
        let statusSummary = byStatus.keys.sorted().map { "\($0)=\(byStatus[$0]!)" }.joined(separator: " ")
        fputs("[rblive] fetchMergedSchedule ok total=\(out.count) \(sportSummary) | \(statusSummary)\n", stderr)
        if out.isEmpty {
            throw RbliveAPIError.missingSignature(liveListBSCode)
        }
        return out
    }

    private static func fetchLiveMatchesForSportType(language: AppLanguage, sportType st: Int32) async throws -> [LiveMatch] {
        let lang = RbliveSportLanguage.languageValue(language)
        fputs("[rblive] fetchLiveMatches sportType=\(st) language=\(lang) → /api/common/bs + /api/match/live\n", stderr)

        let bsBytes = try await RbliveHTTPClient.shared.getBodySignature(
            codes: [liveListBSCode],
            sportType: st,
            matchId: nil,
            stream: true,
            cachePriority: false
        )
        let bsData = try RbliveProtobuf.pbResponseDataField(bsBytes)
        let kv = try RbliveProtobuf.parseBodySignatureKV(bsData)
        guard let version = kv[Int32(liveListBSCode)], !version.isEmpty else {
            throw RbliveAPIError.missingSignature(liveListBSCode)
        }
        let path6 = RbliveDigest.pathPrefix6(fromSignedQuery: "language=\(lang)&sportType=\(st)&stream=true")
        let liveBytes = try await RbliveHTTPClient.shared.getMatchLive(
            pathParams6: path6,
            versionToken: version,
            language: lang,
            sportType: st,
            stream: true
        )
        let liveData = try RbliveProtobuf.pbResponseDataField(liveBytes)
        let (matchChunks, streamChunks) = RbliveProtobuf.splitMatchLive(liveData)

        var parsedStreams: [(mid: UInt64, row: (name: String, fullName: String, url: String?, streamId: Int64, siteType: Int32, matchId: UInt64?, originalInfoWire: Data?))] = []
        for ch in streamChunks {
            let row = RbliveProtobuf.parseStreamRow(ch)
            guard let mid = row.matchId else { continue }
            parsedStreams.append((mid, row))
        }

        var out: [LiveMatch] = []
        var skipped = 0
        for ch in matchChunks {
            guard let pm = RbliveProtobuf.parseDataMatch(ch) else {
                skipped += 1
                continue
            }
            let streams = parsedStreams
                .filter { $0.mid == pm.matchId }
                .map { pm.makeStreamServer(from: $0.row) }
            let live = pm.toLiveMatch(streams: streams)
            Self.debugLogClockIfNeeded(live, statusCode: pm.statusCode)
            out.append(live)
        }
        if skipped > 0 {
            fputs("[rblive] fetchLiveMatches skipped \(skipped)/\(matchChunks.count) unparsed rows\n", stderr)
        }
        var bySport: [String: Int] = [:]
        for m in out { bySport[m.sport.rawValue, default: 0] += 1 }
        let summary = bySport.keys.sorted().map { "\($0)=\(bySport[$0]!)" }.joined(separator: " ")
        fputs("[rblive] fetchLiveMatches ok total=\(out.count) sportType=\(st) \(summary)\n", stderr)
        return out
    }

    /// Fetches `/api/match/detail` and returns a `LiveMatch` with stream rows (playback URLs usually require `/api/stream/detail`).
    static func fetchMatchDetail(matchId: UInt64, sport: Sport, language: AppLanguage) async throws -> LiveMatch {
        let lang = RbliveSportLanguage.languageValue(language)
        let st = RbliveSportLanguage.sportTypeValue(sport)

        let bsBytes = try await RbliveHTTPClient.shared.getBodySignature(
            codes: matchDetailBSCodes,
            sportType: st,
            matchId: matchId,
            stream: true,
            cachePriority: false
        )
        let bsData = try RbliveProtobuf.pbResponseDataField(bsBytes)
        let kv = try RbliveProtobuf.parseBodySignatureKV(bsData)
        guard let version = kv[102], !version.isEmpty else {
            throw RbliveAPIError.missingSignature(102)
        }
        let path6 = RbliveDigest.pathPrefix6(fromSignedQuery: "matchId=\(matchId)&language=\(lang)&sportType=\(st)&stream=true")
        let detailBytes = try await RbliveHTTPClient.shared.getMatchDetail(
            pathParams6: path6,
            versionToken: version,
            matchId: matchId,
            language: lang,
            sportType: st,
            stream: true
        )
        let detailData = try RbliveProtobuf.pbResponseDataField(detailBytes)
        let (matchChunk, streamChunks) = RbliveProtobuf.splitMatchDetail(detailData)
        guard let matchChunk, let pm = RbliveProtobuf.parseDataMatch(matchChunk) else {
            throw RbliveAPIError.invalidProtobuf("PBMatchDetailResp.match")
        }
        if let raw = ProcessInfo.processInfo.environment["FCTV_DEBUG_MATCH_HEX"] {
            let ids = Set(
                raw.split(separator: ",").compactMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            )
            if ids.contains(matchId) {
                let hex = matchChunk.prefix(min(900, matchChunk.count)).map { String(format: "%02x", $0) }.joined(separator: " ")
                fputs("[debug match \(matchId) chunk] len=\(matchChunk.count) hex900=\(hex)\n", stderr)
            }
        }
        let servers: [StreamServer] = streamChunks.map { ch in
            pm.makeStreamServer(from: RbliveProtobuf.parseStreamRow(ch))
        }
        return pm.toLiveMatch(streams: servers)
    }

    /// Fetches `/api/match/lineup` — starting XI + bench for both sides.
    static func fetchMatchLineup(matchId: UInt64, sport: Sport, language: AppLanguage) async throws -> MatchLineup {
        let lang = RbliveSportLanguage.languageValue(language)
        let st = RbliveSportLanguage.sportTypeValue(sport)

        let bsBytes = try await RbliveHTTPClient.shared.getBodySignature(
            codes: matchDetailBSCodes,
            sportType: st,
            matchId: matchId,
            stream: true,
            cachePriority: false
        )
        let bsData = try RbliveProtobuf.pbResponseDataField(bsBytes)
        let kv = try RbliveProtobuf.parseBodySignatureKV(bsData)
        guard let version = kv[102], !version.isEmpty else {
            throw RbliveAPIError.missingSignature(102)
        }
        let path6 = RbliveDigest.pathPrefix6(fromSignedQuery: "matchId=\(matchId)&language=\(lang)&sportType=\(st)")
        let lineupBytes = try await RbliveHTTPClient.shared.getMatchLineup(
            pathParams6: path6,
            versionToken: version,
            matchId: matchId,
            language: lang,
            sportType: st
        )
        let lineupData = try RbliveProtobuf.pbResponseDataField(lineupBytes)
        return RbliveProtobuf.parseMatchLineup(lineupData)
    }

    /// Fetches `/api/match/event` — full timeline (goals, cards, subs, periods).
    static func fetchMatchEvents(matchId: UInt64, sport: Sport, language: AppLanguage) async throws -> [MatchHighlight] {
        let lang = RbliveSportLanguage.languageValue(language)
        let st = RbliveSportLanguage.sportTypeValue(sport)

        let bsBytes = try await RbliveHTTPClient.shared.getBodySignature(
            codes: matchDetailBSCodes,
            sportType: st,
            matchId: matchId,
            stream: true,
            cachePriority: false
        )
        let bsData = try RbliveProtobuf.pbResponseDataField(bsBytes)
        let kv = try RbliveProtobuf.parseBodySignatureKV(bsData)
        guard let version = kv[102], !version.isEmpty else {
            throw RbliveAPIError.missingSignature(102)
        }
        let path6 = RbliveDigest.pathPrefix6(fromSignedQuery: "matchId=\(matchId)&language=\(lang)&sportType=\(st)")
        let eventBytes = try await RbliveHTTPClient.shared.getMatchEvent(
            pathParams6: path6,
            versionToken: version,
            matchId: matchId,
            language: lang,
            sportType: st
        )
        let eventData = try RbliveProtobuf.pbResponseDataField(eventBytes)
        return RbliveProtobuf.parseMatchEvents(eventData)
    }

    static func resolveStreamPlaybackURL(
        matchId: UInt64,
        sport: Sport,
        stream: StreamServer,
        language: AppLanguage = .default
    ) async throws -> RbliveResolvedPlayback {
        let rbSessionEarly = await RbliveHTTPClient.shared.lastSessionHeader() ?? ""
        let rbUAEarly = await RbliveHTTPClient.shared.rbPlaybackUserAgent()
        if let direct = stream.playbackURL {
            var hdr = await MainActor.run {
                RbliveHlsInjectEngine.calcRBHeaders(rbUserAgent: rbUAEarly)
            }
            if !rbSessionEarly.isEmpty { hdr["rb-session"] = rbSessionEarly }
            return RbliveResolvedPlayback(url: direct, extraHTTPHeaders: hdr)
        }
        guard let sid = stream.backendStreamId else {
            throw RbliveAPIError.missingStreamURL
        }
        let site = stream.backendSiteType ?? 0
        let lang = RbliveSportLanguage.languageValue(language)
        let st = RbliveSportLanguage.sportTypeValue(sport)
        fputs("[rblive] resolveStream matchId=\(matchId) sportType=\(st) streamId=\(sid) siteType=\(site) name=\(stream.name)\n", stderr)

        let bsBytes = try await RbliveHTTPClient.shared.getBodySignature(
            codes: matchDetailBSCodes,
            sportType: st,
            matchId: matchId,
            stream: true,
            cachePriority: false
        )
        let bsData = try RbliveProtobuf.pbResponseDataField(bsBytes)
        let kv = try RbliveProtobuf.parseBodySignatureKV(bsData)
        guard let version = kv[102], !version.isEmpty else {
            throw RbliveAPIError.missingSignature(102)
        }
        let path6 = RbliveDigest.pathPrefix6(fromSignedQuery: "matchId=\(matchId)&language=\(lang)&sportType=\(st)&stream=true")

        let continent = RbliveGeoParameters.streamDetailContinent()
        let country = RbliveGeoParameters.streamDetailCountryCode()

        let siteCandidates: [Int32] = {
            var s = [site]
            if site != 0 { s.append(0) }
            return s
        }()
        /// Web/Android vary this query flag; `snd` alone can miss the 2nd provider on some matches.
        let digitCandidates = ["snd", "trd", ""]
        let withOriginalCandidates = [true, false]
        var lastBytes: Data?
        var lastProtobufError: Error?
        for siteTry in siteCandidates {
            for digit in digitCandidates {
                for withOriginal in withOriginalCandidates {
                    let bytes: Data
                    do {
                        bytes = try await RbliveHTTPClient.shared.getStreamDetailSigned(
                            pathParams6: path6,
                            versionToken: version,
                            matchId: matchId,
                            sportType: st,
                            streamId: sid,
                            siteType: siteTry,
                        continent: continent,
                        country: country,
                            digit: digit,
                            withOriginal: withOriginal
                        )
                    } catch {
                        continue
                    }
                    lastBytes = bytes
                    let text = String(decoding: bytes, as: UTF8.self)
                    if text.contains("Stream Not Found") {
                        if ProcessInfo.processInfo.environment["FCTV_DEBUG_API"] == "1" {
                            fputs("[rblive] stream/detail miss siteType=\(siteTry) digit=\(digit.isEmpty ? "(empty)" : digit) withOriginal=\(withOriginal) → Stream Not Found\n", stderr)
                        }
                        continue
                    }
                    let inner: Data
                    do {
                        inner = try RbliveProtobuf.pbResponseDataField(bytes)
                    } catch {
                        lastProtobufError = error
                        continue
                    }
                    guard let streamMsg = extractFirstLengthField(inner, fieldNumber: 2)
                        ?? extractFirstLengthField(inner, fieldNumber: 1)
                    else {
                        continue
                    }
                    do {
                        fputs("[rblive] stream/detail HIT siteType=\(siteTry) digit=\(digit.isEmpty ? "(empty)" : digit) withOriginal=\(withOriginal)\n", stderr)
                        return try await finishResolveStream(streamMsg: streamMsg)
                    } catch {
                        lastProtobufError = error
                        fputs("[rblive] finishResolve fail siteType=\(siteTry) digit=\(digit.isEmpty ? "(empty)" : digit): \(error.localizedDescription)\n", stderr)
                        continue
                    }
                }
            }
        }
        // Exhausted candidates — drop any cached rb-session so the next attempt is a cold resolve.
        await RbliveHTTPClient.shared.clearSession()
        if let e = lastProtobufError {
            throw e
        }
        if let b = lastBytes {
            fputs("[rblive] stream/detail last response (\(b.count) B): \(String(decoding: b, as: UTF8.self))\n", stderr)
        }
        throw RbliveAPIError.missingStreamURL
    }

    /// Parses `/api/stream/detail` inner `PBDataStream` and builds playback URL + headers.
    /// Prefer viaRB (ROT47 field 4 + token) over bare `original_info`: cleartext `play.*.top`
    /// playlists often return HTTP 200 while `.ts` segments require CDN auth (401/302 loop).
    private static func finishResolveStream(streamMsg: Data) async throws -> RbliveResolvedPlayback {
        let row = RbliveProtobuf.parseStreamRow(streamMsg)
        let rbSession = await RbliveHTTPClient.shared.lastSessionHeader() ?? ""
        let rbUA = await RbliveHTTPClient.shared.rbPlaybackUserAgent()
        fputs("[rblive] finishResolve streamId=\(row.streamId) siteType=\(row.siteType) urlLen=\(row.url?.count ?? 0) originalInfo=\(row.originalInfoWire?.count ?? 0)B\n", stderr)

        func applyRbSession(_ hdr: inout [String: String]) {
            if !rbSession.isEmpty { hdr["rb-session"] = rbSession }
        }

        func rbHeaders() async -> [String: String] {
            var hdr = await MainActor.run {
                RbliveHlsInjectEngine.calcRBHeaders(rbUserAgent: rbUA)
            }
            applyRbSession(&hdr)
            return hdr
        }

        // 1) Plain HTTP(S) already in field 4
        if let s = row.url, let u = RbliveProtobuf.firstHTTPURL(in: s) {
            fputs("[rblive] finishResolve plain field4 url=\(u.absoluteString.prefix(120))…\n", stderr)
            return RbliveResolvedPlayback(url: u, extraHTTPHeaders: await rbHeaders())
        }

        // 2) viaRB: classic ROT47 decode + signPlayUrl (CDN auth path).
        // API often omits `rb-session`; Android falls back to device id for the token.
        if let s = row.url, !s.isEmpty {
            do {
                let sessionForToken = rbSession.isEmpty
                    ? await RbliveHTTPClient.shared.stableDeviceId()
                    : rbSession
                let signed = try RbliveStreamCrypto.signPlayUrlWithRbSession(
                    playUrl: s,
                    rbSession: sessionForToken
                )
                fputs(
                    "[rblive] finishResolve viaRB signed session=\(rbSession.isEmpty ? "deviceId" : "rb-session") url=\(signed.prefix(140))…\n",
                    stderr
                )
                if let u = URL(string: signed) {
                    return RbliveResolvedPlayback(url: u, extraHTTPHeaders: await rbHeaders())
                }
            } catch {
                fputs("[rblive] finishResolve viaRB fail: \(error.localizedDescription)\n", stderr)
                if let decoded = RbliveStreamCrypto.decodeStreamUrl(s), let u = URL(string: decoded) {
                    fputs("[rblive] finishResolve viaRB unsigned fallback\n", stderr)
                    return RbliveResolvedPlayback(url: u, extraHTTPHeaders: await rbHeaders())
                }
            }
        }

        // 3) original_info AES fallback (may lack segment auth)
        if let wire = row.originalInfoWire, !wire.isEmpty,
           let decoded = try? RbliveStreamCrypto.decryptOriginalInfoWire(wire),
           !decoded.url.isEmpty {
            fputs("[rblive] original_info decrypted url=\(decoded.url.prefix(120))… headers=\(decoded.headers.count)\n", stderr)
            let injectOn = await MainActor.run { RbliveHlsInjectEngine.injectEnabled }
            if injectOn {
                let inj = await MainActor.run {
                    RbliveHlsInjectEngine.actionSimpleInject(
                        type: .playlistSimpleInject,
                        url: decoded.url,
                        srcHeaders: decoded.headers,
                        rbUserAgent: rbUA
                    )
                }
                if let inj, let u = URL(string: inj.url) {
                    var hdr = inj.headers
                    applyRbSession(&hdr)
                    return RbliveResolvedPlayback(url: u, extraHTTPHeaders: hdr)
                }
            }
            let trimmed = decoded.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = RbliveProtobuf.firstHTTPURL(in: decoded.url) ?? URL(string: trimmed), !trimmed.isEmpty {
                var hdr = await rbHeaders()
                for (k, v) in decoded.headers {
                    hdr[k.lowercased()] = v
                }
                return RbliveResolvedPlayback(url: u, extraHTTPHeaders: hdr)
            }
        }

        throw RbliveAPIError.missingStreamURL
    }

    private static func extractFirstLengthField(_ message: Data, fieldNumber: Int) -> Data? {
        var c = RbliveProtoCursor(message)
        while !c.isAtEnd {
            guard let tag = c.readTag() else { break }
            let field = tag >> 3
            let wire = UInt8(tag & 7)
            if field == UInt32(fieldNumber), wire == 2 {
                return c.readLengthDelimited()
            }
            var m = c
            m.skipField(wireType: wire)
            c = m
        }
        return nil
    }

    /// Debug: `SIMCTL_CHILD_FCTV_DEBUG_MATCH_CLOCK=1`
    static func debugLogClockIfNeeded(_ match: LiveMatch, statusCode: Int32) {
        guard ProcessInfo.processInfo.environment["FCTV_DEBUG_MATCH_CLOCK"] == "1" else { return }
        fputs(
            "[match-clock] id=\(match.id) status=\(statusCode) kickoff=\(match.timeLabel) clock=\(match.liveClock ?? "<nil>") name=\(match.displayName)\n",
            stderr
        )
    }
}

private extension RbliveParsedMatch {
    func makeStreamServer(from row: (
        name: String,
        fullName: String,
        url: String?,
        streamId: Int64,
        siteType: Int32,
        matchId: UInt64?,
        originalInfoWire: Data?
    )) -> StreamServer {
        let label = row.name.isEmpty ? row.fullName : row.name
        let hint = CountryHelper.infer(fromStreamName: "\(label) \(row.fullName)", matchRegion: region)
        // Stable id across live-list → detail refresh (UUID broke first-open autoplay matching).
        let stableId: String = {
            if row.streamId != 0 { return "sid-\(row.streamId)" }
            return "sid-0-\(row.siteType)-\(label)"
        }()
        return StreamServer(
            id: stableId,
            name: row.name,
            fullName: row.fullName,
            playbackURL: RbliveProtobuf.firstHTTPURL(in: row.url ?? ""),
            resolution: "",
            language: "",
            country: hint.label,
            countryCode: hint.code,
            backendStreamId: row.streamId,
            originalInfoWire: row.originalInfoWire,
            backendSiteType: row.siteType
        )
    }

    func toLiveMatch(streams: [StreamServer]) -> LiveMatch {
        let status = Self.mapStatus(statusCode)
        let sport = RbliveSportLanguage.sport(from: sportType)
        let regionHint = CountryHelper.infer(fromStreamName: "", matchRegion: region)
        let homeFlag = homeLogoURL == nil
            ? CountryHelper.infer(fromStreamName: "", matchRegion: homeName).code.flatMap { CountryHelper.flagEmoji(for: $0) }
            : nil
        let awayFlag = awayLogoURL == nil
            ? CountryHelper.infer(fromStreamName: "", matchRegion: awayName).code.flatMap { CountryHelper.flagEmoji(for: $0) }
            : nil
        let home = Contender(name: homeName, logoURL: homeLogoURL, flag: homeFlag)
        let away = Contender(name: awayName, logoURL: awayLogoURL, flag: awayFlag)
        let hs: Int? = homeScore.map { Int($0) }
        let ascore: Int? = awayScore.map { Int($0) }
        let leagueFlag = regionHint.code.flatMap { CountryHelper.flagEmoji(for: $0) }
        return LiveMatch(
            id: String(matchId),
            sport: sport,
            leagueName: leagueName,
            leagueLogoURL: leagueLogoURL ?? regionLogoURL,
            leagueFlag: leagueFlag,
            region: region,
            contenders: [home, away],
            homeScore: hs,
            awayScore: ascore,
            status: status,
            startDate: startDate,
            liveClock: liveClock,
            hot: hot,
            streams: streams
        )
    }

    static func mapStatus(_ code: Int32) -> MatchStatus {
        if code == 10_000 { return .finished }
        if code == 0 { return .scheduled }
        if code >= 10_000 { return .finished }
        if code == 10 { return .secondHalf }
        if code >= 100 && code < 200 { return .secondHalf }
        if code >= 200 && code < 300 { return .secondHalf }
        if code >= 300 && code < 400 { return .secondHalf }
        if code >= 1_200 && code < 1_400 { return .secondHalf }
        return .secondHalf
    }
}
