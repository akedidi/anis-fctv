#!/usr/bin/env swift
// Run: swift FCTV/scripts/check-event-flow.swift
//      swift FCTV/scripts/check-event-flow.swift "volleyball/avc-champions-league-2164101/match.html"
//
// Headless sanity check: reachability to the same data host the iOS app uses,
// plus slug parsing aligned with `MatchService.matchID(fromSlugURL:)`.

import Foundation

func matchID(fromSlugURL raw: String) -> String? {
    let withoutQuery = raw.split(separator: "?").first.map(String.init) ?? raw
    let parts = withoutQuery.split(separator: "/").map(String.init)
    guard parts.count >= 2 else { return nil }
    let leagueSlug = parts[parts.count - 2]
    guard let dash = leagueSlug.lastIndex(of: "-") else { return nil }
    let suffix = leagueSlug[leagueSlug.index(after: dash)...]
    guard suffix.allSatisfy(\.isNumber) else { return nil }
    return String(suffix)
}

@discardableResult
func probe(_ urlString: String) -> (status: Int, bytes: Int) {
    guard let url = URL(string: urlString) else { return (-1, 0) }
    var req = URLRequest(url: url)
    req.timeoutInterval = 12
    req.setValue("FCTV-event-check/1.0", forHTTPHeaderField: "User-Agent")
    let sem = DispatchSemaphore(value: 0)
    var status = 0
    var size = 0
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        if let r = resp as? HTTPURLResponse { status = r.statusCode }
        size = data?.count ?? 0
        sem.signal()
    }.resume()
    sem.wait()
    return (status, size)
}

func log(_ m: String, _ t: String) { print("[\(m)] \(t)") }

func main() {
    let arg = CommandLine.arguments.dropFirst().first
        ?? "volleyball/avc-champions-league-2164101/jtekt-vs-nakhon-ratchasima.html"
    print("FCTV upstream check — \(Date())")
    print(String(repeating: "─", count: 56))

    let host = "https://apis-data10.tcllu137fien.ru"
    let bs = probe("\(host)/api/common/bs?code=100&stream=true&cachePriority=false")
    log("BS", "GET /api/common/bs (code=100) → HTTP \(bs.status), \(bs.bytes) B")

    log("URL", "slug: \(arg)")
    guard let id = matchID(fromSlugURL: arg) else {
        log("FAIL", "Could not parse match id from slug (expected …/<league-name>-<digits>/…).")
        exit(1)
    }
    log("ID", "matchId = \(id)")

    let ok = (200 ... 299).contains(bs.status)
    print(String(repeating: "─", count: 56))
    print(ok ? "RESULT: data API reachable; slug parsing OK." : "RESULT: slug OK but BS probe failed (check network / host).")
    exit(ok ? 0 : 2)
}

main()
