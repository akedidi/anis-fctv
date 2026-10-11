import Foundation

/// Lists `/api/match/live` (all sports), picks **live** matches with streams (Android-style),
/// resolves `/api/stream/detail`, then on **macOS** runs **AVPlayer** until real playback (time advances),
/// optionally opens a preview window. Use `--http-only` for the previous GET-only check.
@main
enum PlaybackProbeMain {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("playback-probe error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() async throws {
        await MainActor.run {
            PlaybackProbeEnv.applyInjectFromEnvironment()
        }

        var providerIndex = 0
        var language = AppLanguage.default
        var listOnly = false
        var listDetail = false
        var listAll = false
        var findSubstring: String?
        /// When set, `/api/match/live` is requested with this `sportType` (e.g. `golf` → PBSportType 5) instead of all sports.
        var listSportFilter: Sport?
        var matchIndexInLiveList = 0
        var httpOnly = false
        var noWindow = false
        var noScan = false
        var previewSec: Double = 25
        var attemptTimeout: TimeInterval = 45
        /// When set, skip the live list and hit `/api/match/detail` for this id (e.g. Sinner `2163266` + `--sport tennis`).
        var probeMatchId: UInt64?
        var probeSport: Sport = .tennis

        var args = Array(CommandLine.arguments.dropFirst())
        while args.first == "--" {
            args.removeFirst()
        }
        while let a = args.first {
            args.removeFirst()
            switch a {
            case "--help", "-h":
                print(helpText)
                return
            case "--list":
                listOnly = true
            case "--list-detail":
                listDetail = true
            case "--list-all":
                listAll = true
            case "--find":
                guard let v = args.first, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ProbeError("expected non-empty substring after --find")
                }
                args.removeFirst()
                findSubstring = v
            case "--live-sport":
                guard let v = args.first else { throw ProbeError("expected Sport.rawValue after --live-sport (e.g. golf)") }
                args.removeFirst()
                guard let s = Sport(rawValue: v.lowercased()) else {
                    throw ProbeError("unknown sport \(v)")
                }
                listSportFilter = s
            case "--http-only":
                httpOnly = true
            case "--no-window":
                noWindow = true
            case "--no-scan":
                noScan = true
            case "--preview-sec":
                guard let v = args.first, let d = Double(v), d >= 0 else {
                    throw ProbeError("expected non-negative number after --preview-sec")
                }
                args.removeFirst()
                previewSec = d
            case "--attempt-timeout":
                guard let v = args.first, let t = Double(v), t > 2 else {
                    throw ProbeError("expected seconds > 2 after --attempt-timeout")
                }
                args.removeFirst()
                attemptTimeout = t
            case "--provider-index":
                guard let v = args.first, let i = Int(v), i >= 0 else {
                    throw ProbeError("expected non-negative integer after --provider-index")
                }
                args.removeFirst()
                providerIndex = i
            case "--live-match-index":
                guard let v = args.first, let i = Int(v), i >= 0 else {
                    throw ProbeError("expected non-negative integer after --live-match-index")
                }
                args.removeFirst()
                matchIndexInLiveList = i
            case "--lang":
                guard let code = args.first else { throw ProbeError("expected language id after --lang") }
                args.removeFirst()
                guard let lang = AppLanguage.all.first(where: { $0.id == code }) else {
                    throw ProbeError("unknown language id \(code)")
                }
                language = lang
            case "--match-id":
                guard let v = args.first, let id = UInt64(v), id > 0 else {
                    throw ProbeError("expected positive integer after --match-id")
                }
                args.removeFirst()
                probeMatchId = id
            case "--sport":
                guard let v = args.first else { throw ProbeError("expected sport rawValue after --sport (e.g. tennis)") }
                args.removeFirst()
                guard let s = Sport(rawValue: v.lowercased()) else {
                    throw ProbeError("unknown sport \(v); use Sport.rawValue (tennis, football, …)")
                }
                probeSport = s
            default:
                throw ProbeError("unknown argument: \(a)\n\(helpText)")
            }
        }

        if let mid = probeMatchId {
            try await runFixedMatchIdProbe(
                matchId: mid,
                sport: probeSport,
                language: language,
                listOnly: listOnly,
                listDetail: listDetail,
                httpOnly: httpOnly,
                noScan: noScan,
                noWindow: noWindow,
                providerIndex: providerIndex,
                previewSec: previewSec,
                attemptTimeout: attemptTimeout
            )
            return
        }

        fputs("[probe] fetch /api/match/live (stream=true, sport=\(listSportFilter?.rawValue ?? "all"))…\n", stderr)
        let all = try await RbliveMatchRepository.fetchLiveMatches(language: language, sport: listSportFilter ?? .undefined)
        let live = all.filter { $0.status.isLive && !$0.streams.isEmpty }
        fputs("[probe] total=\(all.count) liveWithStreams=\(live.count)\n", stderr)

        if let raw = findSubstring?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let needle = raw.lowercased()
            func haystack(_ m: LiveMatch) -> String {
                let bits = [m.leagueName, m.displayName] + m.contenders.map(\.name)
                return bits.joined(separator: " ").lowercased()
            }
            let hits = all.filter { haystack($0).contains(needle) }
            fputs("[probe] --find \"\(raw)\" → \(hits.count) row(s) in full list\n", stderr)
            for (i, m) in hits.enumerated() {
                let names = m.contenders.prefix(2).map(\.name).joined(separator: " vs ")
                let liveMark = m.status.isLive ? "live" : "notLive"
                print("[\(i)] id=\(m.id) sport=\(m.sport.rawValue) status=\(liveMark) streams=\(m.streams.count) league=\(m.leagueName) \(names)")
            }
            if hits.isEmpty {
                return
            }
            if listDetail {
                for m in hits.prefix(20) {
                    guard let mid = UInt64(m.id) else { continue }
                    do {
                        let d = try await RbliveMatchRepository.fetchMatchDetail(matchId: mid, sport: m.sport, language: language)
                        print("detail id=\(d.id) sport=\(d.sport.rawValue) \(d.displayName) streams=\(d.streams.count)")
                    } catch {
                        fputs("[probe] detail fail id=\(m.id): \(error.localizedDescription)\n", stderr)
                    }
                }
                return
            }
            if httpOnly {
                for m in hits where m.status.isLive && !m.streams.isEmpty {
                    guard let mid = UInt64(m.id) else { continue }
                    fputs("[probe] try stream http-only id=\(mid) sport=\(m.sport.rawValue)…\n", stderr)
                    do {
                        let detail = try await RbliveMatchRepository.fetchMatchDetail(matchId: mid, sport: m.sport, language: language)
                        guard providerIndex < detail.streams.count else { continue }
                        try await httpProbeResolveAndFetch(
                            detail: detail,
                            providerIndex: providerIndex,
                            language: language,
                            choiceLog: "find-\(raw)"
                        )
                        return
                    } catch {
                        fputs("[probe] skip id=\(mid): \(error.localizedDescription)\n", stderr)
                    }
                }
                throw ProbeError("--find + --http-only: no playable live stream among hits (detail or stream/detail failed)")
            }
            return
        }

        if listAll {
            for (i, m) in all.prefix(120).enumerated() {
                let names = m.contenders.prefix(2).map(\.name).joined(separator: " vs ")
                let liveMark = m.status.isLive ? "live" : "notLive"
                print("[\(i)] id=\(m.id) sport=\(m.sport.rawValue) status=\(liveMark) streams=\(m.streams.count) league=\(m.leagueName) \(names)")
            }
            return
        }

        if listDetail {
            for (i, m) in live.prefix(30).enumerated() {
                guard let mid = UInt64(m.id) else { continue }
                let d = try await RbliveMatchRepository.fetchMatchDetail(matchId: mid, sport: m.sport, language: language)
                print("[\(i)] id=\(d.id) sport=\(d.sport.rawValue) \(d.displayName) streams=\(d.streams.count)")
            }
            return
        }

        if listOnly {
            for (i, m) in live.prefix(30).enumerated() {
                let names = m.contenders.prefix(2).map(\.name).joined(separator: " vs ")
                print("[\(i)] id=\(m.id) sport=\(m.sport.rawValue) \(names) streams=\(m.streams.count)")
            }
            return
        }

        guard !live.isEmpty else {
            throw ProbeError("no in-progress match with streams (Android-style filter: status.isLive && streams non-empty)")
        }

        if httpOnly {
            try await runHttpOnly(
                live: live,
                matchIndex: matchIndexInLiveList,
                providerIndex: providerIndex,
                language: language
            )
            return
        }

        #if os(macOS)
            try await runMacAvPlayback(
                live: live,
                matchIndex: matchIndexInLiveList,
                providerIndex: providerIndex,
                noScan: noScan,
                noWindow: noWindow,
                previewSec: previewSec,
                attemptTimeout: attemptTimeout,
                language: language
            )
        #else
            throw ProbeError("AV playback probe requires macOS. Use --http-only on this platform.")
        #endif
    }

    /// Probe a known numeric id (e.g. Sinner `2163266`) without requiring the match in `/api/match/live`.
    private static func runFixedMatchIdProbe(
        matchId: UInt64,
        sport: Sport,
        language: AppLanguage,
        listOnly: Bool,
        listDetail: Bool,
        httpOnly: Bool,
        noScan: Bool,
        noWindow: Bool,
        providerIndex: Int,
        previewSec: Double,
        attemptTimeout: TimeInterval
    ) async throws {
        fputs("[probe] fixed matchId=\(matchId) sport=\(sport.rawValue) → /api/match/detail…\n", stderr)
        let detail = try await RbliveMatchRepository.fetchMatchDetail(matchId: matchId, sport: sport, language: language)

        if listOnly {
            let names = detail.contenders.prefix(2).map(\.name).joined(separator: " vs ")
            print("[0] id=\(detail.id) sport=\(detail.sport.rawValue) \(names) streams=\(detail.streams.count)")
            return
        }
        if listDetail {
            print("[0] id=\(detail.id) sport=\(detail.sport.rawValue) \(detail.displayName) streams=\(detail.streams.count)")
            return
        }
        guard !detail.streams.isEmpty else {
            throw ProbeError("match \(matchId) has no streams (wrong sport? try --sport tennis)")
        }

        if httpOnly {
            try await httpProbeResolveAndFetch(
                detail: detail,
                providerIndex: providerIndex,
                language: language,
                choiceLog: "fixed matchId=\(matchId)"
            )
            return
        }

        #if os(macOS)
            _ = noScan
            try await tryMacPlaybackFromDetail(
                detail: detail,
                providerIndex: providerIndex,
                noWindow: noWindow,
                previewSec: previewSec,
                attemptTimeout: attemptTimeout,
                language: language
            )
        #else
            throw ProbeError("AV playback probe requires macOS. Use --http-only on this platform.")
        #endif
    }

    private static func httpProbeResolveAndFetch(
        detail: LiveMatch,
        providerIndex: Int,
        language: AppLanguage,
        choiceLog: String
    ) async throws {
        guard let mid = UInt64(detail.id) else { throw ProbeError("bad match id \(detail.id)") }
        guard providerIndex < detail.streams.count else {
            throw ProbeError("provider-index \(providerIndex) out of range (0..<\(detail.streams.count))")
        }
        let stream = detail.streams[providerIndex]

        let label = detail.contenders.prefix(2).map(\.name).joined(separator: " vs ")
        fputs("[probe] \(choiceLog) id=\(detail.id) \(label) provider[\(providerIndex)]=\(stream.name)\n", stderr)

        let resolved = try await RbliveMatchRepository.resolveStreamPlaybackURL(
            matchId: mid,
            sport: detail.sport,
            stream: stream,
            language: language
        )
        fputs("[probe] resolved URL: \(resolved.url.absoluteString)\n", stderr)

        var req = URLRequest(url: resolved.url)
        req.httpMethod = "GET"
        for (k, v) in resolved.extraHTTPHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ProbeError("non-HTTP response") }
        guard (200 ... 299).contains(http.statusCode) else {
            throw ProbeError("HTTP \(http.statusCode)")
        }
        let head = String(data: data.prefix(512), encoding: .utf8) ?? ""
        let okM3U = head.contains("#EXTM3U") || resolved.url.pathExtension.lowercased() == "m3u8"
        if !okM3U {
            fputs("[probe] warning: body may not be HLS (first bytes): \(head.prefix(200))\n", stderr)
        }
        print("PLAYBACK_PROBE_OK match=\(detail.id) provider_index=\(providerIndex) http=\(http.statusCode) bytes=\(data.count) hls_like=\(okM3U)")

        // Optional: exercise native loopback proxy + CSL retries (≥1 min beyond live window ~45s).
        if ProcessInfo.processInfo.environment["FCTV_LOCAL_HLS_SOAK"] == "1" {
            let sec = Int(ProcessInfo.processInfo.environment["FCTV_LOCAL_HLS_SOAK_SEC"] ?? "") ?? 70
            try await soakLocalHlsProxy(resolved: resolved, seconds: max(60, sec))
        }
    }

    /// Poll rewritten playlist + last segment through `RbliveLocalHlsServer` (native IPA path).
    private static func soakLocalHlsProxy(resolved: RbliveResolvedPlayback, seconds: Int) async throws {
        var hdrs = resolved.extraHTTPHeaders
        if hdrs["Referer"] == nil, hdrs["referer"] == nil {
            hdrs["Referer"] = UserDefaults.standard.string(forKey: "fctv.rblive.http_referer")
                ?? "https://www.fctv33.com/"
        }
        if hdrs["User-Agent"] == nil, hdrs["user-agent"] == nil {
            hdrs["User-Agent"] = "rbapp/--dg-77-ios/unknown"
        }
        let playable = try RbliveLocalHlsServer.shared.playableURL(for: resolved.url, extraHeaders: hdrs)
        fputs("[soak] local \(playable.absoluteString)\n", stderr)
        let session = URLSession(configuration: .ephemeral)
        var fails = 0
        let steps = max(1, seconds / 5)
        for i in 0 ..< steps {
            let (pdata, presp) = try await session.data(from: playable)
            let pst = (presp as? HTTPURLResponse)?.statusCode ?? -1
            let text = String(data: pdata, encoding: .utf8) ?? ""
            let lines = text.split(whereSeparator: \.isNewline).map(String.init)
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            var segOK = false
            if let last = lines.last, let u = URL(string: last) {
                do {
                    let (sdata, sresp) = try await session.data(from: u)
                    let sst = (sresp as? HTTPURLResponse)?.statusCode ?? -1
                    segOK = sst == 200 && sdata.count > 500
                    fputs(
                        "[soak] t=\((i + 1) * 5)s playlist=\(pst)/\(pdata.count) segs=\(lines.count) last=\(sst)/\(sdata.count) sync=\(sdata.first == 0x47)\n",
                        stderr
                    )
                } catch {
                    fputs("[soak] t=\((i + 1) * 5)s seg ERR \(error.localizedDescription)\n", stderr)
                }
            } else {
                fputs("[soak] t=\((i + 1) * 5)s playlist=\(pst) no seg lines\n", stderr)
            }
            if pst != 200 || !segOK { fails += 1 }
            if i + 1 < steps {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        print(fails == 0 ? "LOCAL_HLS_SOAK_OK" : "LOCAL_HLS_SOAK_FAIL fails=\(fails)")
        if fails > 0 { throw ProbeError("local HLS soak failed (\(fails) bad polls)") }
    }

    private static func runHttpOnly(
        live: [LiveMatch],
        matchIndex: Int,
        providerIndex: Int,
        language: AppLanguage
    ) async throws {
        guard matchIndex < live.count else {
            throw ProbeError("live-match-index \(matchIndex) out of range (0..<\(live.count))")
        }
        let summary = live[matchIndex]
        guard let mid = UInt64(summary.id) else { throw ProbeError("bad match id \(summary.id)") }
        fputs("[probe] fetch /api/match/detail for stream ids (match \(summary.id))…\n", stderr)
        let detail = try await RbliveMatchRepository.fetchMatchDetail(matchId: mid, sport: summary.sport, language: language)
        try await httpProbeResolveAndFetch(
            detail: detail,
            providerIndex: providerIndex,
            language: language,
            choiceLog: "chosen live #\(matchIndex)"
        )
    }

    #if os(macOS)
        private static func runMacAvPlayback(
            live: [LiveMatch],
            matchIndex: Int,
            providerIndex: Int,
            noScan: Bool,
            noWindow: Bool,
            previewSec: TimeInterval,
            attemptTimeout: TimeInterval,
            language: AppLanguage
        ) async throws {
            if noScan {
                try await tryOneMacPlayback(
                    live: live,
                    matchIndex: matchIndex,
                    providerIndex: providerIndex,
                    noWindow: noWindow,
                    previewSec: previewSec,
                    attemptTimeout: attemptTimeout,
                    language: language
                )
                return
            }

            let envRaw = ProcessInfo.processInfo.environment["FCTV_STINJ_ENABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let stinjFromEnv = envRaw == "1" || envRaw == "true" || envRaw == "yes"
            let passes = stinjFromEnv ? [0] : [0, 1]

            for pass in passes {
                if pass == 1 {
                    await MainActor.run { PlaybackProbeEnv.forceStinjEnabled() }
                    fputs("[probe] second pass: STINJ forced ON (retry all streams)\n", stderr)
                }

                for mi in 0 ..< live.count {
                    let summary = live[mi]
                    guard let mid = UInt64(summary.id) else { continue }
                    let detail: LiveMatch
                    do {
                        detail = try await RbliveMatchRepository.fetchMatchDetail(
                            matchId: mid,
                            sport: summary.sport,
                            language: language
                        )
                    } catch {
                        fputs("[probe] detail skip match[\(mi)] id=\(summary.id): \(error.localizedDescription)\n", stderr)
                        continue
                    }
                    for (pi, stream) in detail.streams.enumerated() {
                        do {
                            let resolved = try await RbliveMatchRepository.resolveStreamPlaybackURL(
                                matchId: mid,
                                sport: detail.sport,
                                stream: stream,
                                language: language
                            )
                            fputs("[probe] try AV match[\(mi)] id=\(detail.id) provider[\(pi)]=\(stream.name)\n", stderr)
                            let ok = try await MainActor.run {
                                let (player, loader) = PlaybackProbeMacPlayback.makePlayer(resolved: resolved)
                                // Must retain loader: resourceLoader delegate is weak.
                                let retainLoader = loader
                                defer {
                                    _ = retainLoader
                                    player.pause()
                                    player.replaceCurrentItem(with: nil)
                                }
                                player.play()
                                try PlaybackProbeMacPlayback.waitUntilPlaying(player: player, timeout: attemptTimeout)
                                return true
                            }
                            if ok {
                                let label = detail.contenders.prefix(2).map(\.name).joined(separator: " vs ")
                                fputs("[probe] AV playback OK — match[\(mi)] \(label) provider[\(pi)]\n", stderr)
                                if !noWindow, previewSec > 0 {
                                    await MainActor.run {
                                        let (player2, loader2) = PlaybackProbeMacPlayback.makePlayer(resolved: resolved)
                                        let retainLoader2 = loader2
                                        PlaybackProbeMacPlayback.showPreviewWindow(player: player2, seconds: previewSec)
                                        player2.pause()
                                        player2.replaceCurrentItem(with: nil)
                                        _ = retainLoader2
                                    }
                                }
                                print("PLAYBACK_PROBE_OK match=\(detail.id) provider_index=\(pi) av_playback=1 pass=\(pass)")
                                return
                            }
                        } catch {
                            fputs("[probe] AV fail match[\(mi)] provider[\(pi)]: \(error.localizedDescription)\n", stderr)
                        }
                    }
                }
            }

            throw ProbeError("no live stream reached AV playback (try FCTV_STINJ_ENABLE=1 or different network)")
        }

        private static func tryMacPlaybackFromDetail(
            detail: LiveMatch,
            providerIndex: Int,
            noWindow: Bool,
            previewSec: TimeInterval,
            attemptTimeout: TimeInterval,
            language: AppLanguage
        ) async throws {
            guard let mid = UInt64(detail.id) else { throw ProbeError("bad match id \(detail.id)") }
            guard providerIndex < detail.streams.count else {
                throw ProbeError("provider-index \(providerIndex) out of range (0..<\(detail.streams.count))")
            }
            let stream = detail.streams[providerIndex]

            let resolved = try await RbliveMatchRepository.resolveStreamPlaybackURL(
                matchId: mid,
                sport: detail.sport,
                stream: stream,
                language: language
            )
            fputs("[probe] resolved URL: \(resolved.url.absoluteString)\n", stderr)

            try await MainActor.run {
                let (player, loader) = PlaybackProbeMacPlayback.makePlayer(resolved: resolved)
                // Must retain loader: resourceLoader delegate is weak.
                let retainLoader = loader
                defer {
                    _ = retainLoader
                    player.pause()
                    player.replaceCurrentItem(with: nil)
                }
                player.play()
                try PlaybackProbeMacPlayback.waitUntilPlaying(player: player, timeout: attemptTimeout)
            }

            if !noWindow, previewSec > 0 {
                await MainActor.run {
                    let (player2, loader2) = PlaybackProbeMacPlayback.makePlayer(resolved: resolved)
                    let retainLoader2 = loader2
                    PlaybackProbeMacPlayback.showPreviewWindow(player: player2, seconds: previewSec)
                    player2.pause()
                    player2.replaceCurrentItem(with: nil)
                    _ = retainLoader2
                }
            }
            print("PLAYBACK_PROBE_OK match=\(detail.id) provider_index=\(providerIndex) av_playback=1")
        }

        private static func tryOneMacPlayback(
            live: [LiveMatch],
            matchIndex: Int,
            providerIndex: Int,
            noWindow: Bool,
            previewSec: TimeInterval,
            attemptTimeout: TimeInterval,
            language: AppLanguage
        ) async throws {
            guard matchIndex < live.count else {
                throw ProbeError("live-match-index \(matchIndex) out of range (0..<\(live.count))")
            }
            let summary = live[matchIndex]
            guard let mid = UInt64(summary.id) else { throw ProbeError("bad match id \(summary.id)") }
            fputs("[probe] fetch /api/match/detail for stream ids (match \(summary.id))…\n", stderr)
            let detail = try await RbliveMatchRepository.fetchMatchDetail(matchId: mid, sport: summary.sport, language: language)
            try await tryMacPlaybackFromDetail(
                detail: detail,
                providerIndex: providerIndex,
                noWindow: noWindow,
                previewSec: previewSec,
                attemptTimeout: attemptTimeout,
                language: language
            )
        }
    #endif

    private static let helpText = """
    playback-probe — liste les matchs live, résout un flux, vérifie la lecture AV (macOS) ou HTTP.

    Options:
      --list                  Affiche jusqu’à 30 matchs live (ids / sport / streams; noms souvent vides côté API live).
      --list-all              Liste jusqu’à 120 lignes brutes (tous statuts / y compris 0 stream).
      --find SUB              Filtre la liste complète (ligue, noms, display). Avec `--http-only`, essaie le 1er hit live avec streams.
      --list-detail           Idem + appel `/api/match/detail` par ligne pour afficher les noms (plus lent).
      --live-sport SLUG       Filtre `sportType` pour la liste (`golf`, `tennis`, …). Défaut: tous les sports.
      --sport SLUG            Avec --match-id : `Sport.rawValue` (défaut tennis si omis côté code: fixer --sport tennis).
      --live-match-index N    Index dans la liste live (défaut 0).
      --provider-index M      Index du provider (défaut 0).
      --lang CODE             ex. en, fr (défaut en).
      --http-only             GET sur la playlist uniquement (pas d’AVPlayer).
      --no-scan               N’essaie que le couple (live-match-index, provider-index).
      --no-window             Après succès AV, ne pas ouvrir de fenêtre de prévisualisation.
      --preview-sec N         Durée fenêtre prévisualisation (défaut 25, 0 = skip).
      --attempt-timeout SEC   Timeout par tentative AV (défaut 45).
      --help

    Environnement:
      FCTV_STINJ_ENABLE=1     Active l’inject STINJ (UserDefaults, comme l’app iOS).

    Défaut (macOS): scan automatique de tous les matchs live × tous les providers jusqu’à lecture AV réussie,
    puis fenêtre de prévisualisation. Sans STINJ dans l’environnement, une 2e passe force STINJ si la 1re échoue.

    Exemples:
      FCTV_STINJ_ENABLE=1 swift run playback-probe -- --list
      swift run playback-probe
      swift run playback-probe -- --find "PGA" --list-detail
      swift run playback-probe -- --find "PGA" --http-only
      swift run playback-probe -- --no-scan --live-match-index 0 --provider-index 1
    """
}

private struct ProbeError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
