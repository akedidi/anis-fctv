"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { HlsPlayer } from "./HlsPlayer";
import { apiUrl } from "@/lib/api";
import {
  MORE_SPORTS,
  PRIMARY_SPORTS,
  formatKickoff,
  isFinishedStatus,
  isLiveStatus,
  type LiveMatch,
  type MatchEvent,
  type LineupPlayer,
  type StreamServer,
} from "@/lib/types";

type Filter = "all" | "live" | "finished";
type Tab = "overview" | "lineups" | "stats" | "h2h";

/** Same cadence as iOS / Flutter detail + list live polling. */
const LIVE_POLL_MS = 20_000;

function mergeLiveFields(prev: LiveMatch, next: LiveMatch): LiveMatch {
  return {
    ...prev,
    homeScore: next.homeScore ?? prev.homeScore,
    awayScore: next.awayScore ?? prev.awayScore,
    liveClock: next.liveClock ?? prev.liveClock,
    statusCode: next.statusCode,
    hot: next.hot,
    name: next.name || prev.name,
    leagueName: next.leagueName || prev.leagueName,
    region: next.region || prev.region,
    contenders: next.contenders?.length ? next.contenders : prev.contenders,
    streams: next.streams?.length ? next.streams : prev.streams,
  };
}

function Logo({ src, name, size = 22 }: { src?: string; name: string; size?: number }) {
  const [failed, setFailed] = useState(false);
  if (!src || failed) {
    return (
      <span className="logo-fallback" style={{ width: size, height: size }}>
        {(name || "?").slice(0, 1).toUpperCase()}
      </span>
    );
  }
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={src}
      alt=""
      width={size}
      height={size}
      onError={() => setFailed(true)}
      referrerPolicy="no-referrer"
    />
  );
}

function reliableServers(streams: StreamServer[]): StreamServer[] {
  return streams.filter((s) => {
    const n = (s.name || "").trim();
    if (!n || /^stream\s*\d*$/i.test(n) || n.toLowerCase() === "live stream") return false;
    return true;
  });
}

export function FctvApp() {
  const [sportType, setSportType] = useState(0);
  const [filter, setFilter] = useState<Filter>("all");
  const [search, setSearch] = useState("");
  const [appliedSearch, setAppliedSearch] = useState("");
  const [matches, setMatches] = useState<LiveMatch[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [selectedId, setSelectedId] = useState<number | null>(null);
  const [detail, setDetail] = useState<LiveMatch | null>(null);
  const [servers, setServers] = useState<StreamServer[]>([]);
  const [activeServerId, setActiveServerId] = useState<string | null>(null);
  const [playableUrl, setPlayableUrl] = useState<string | null>(null);
  const [resolving, setResolving] = useState(false);
  const [muted, setMuted] = useState(false);
  const [tab, setTab] = useState<Tab>("overview");
  const [events, setEvents] = useState<MatchEvent[]>([]);
  const [lineup, setLineup] = useState<{ home: LineupPlayer[]; away: LineupPlayer[] } | null>(null);
  const [mini, setMini] = useState(false);
  const [showMore, setShowMore] = useState(false);

  const applyMatchList = useCallback((next: LiveMatch[]) => {
    setMatches(next);
    setDetail((prev) => {
      if (!prev) return prev;
      const row = next.find((m) => m.matchId === prev.matchId);
      return row ? mergeLiveFields(prev, row) : prev;
    });
  }, []);

  const loadMatches = useCallback(
    async (opts?: { silent?: boolean }) => {
      const silent = opts?.silent === true;
      if (!silent) {
        setLoading(true);
        setError(null);
      }
      try {
        const res = await fetch(apiUrl(`/api/live?sportType=${sportType}&language=0`), {
          cache: "no-store",
        });
        const data = (await res.json()) as { matches?: LiveMatch[]; error?: string };
        if (!res.ok) throw new Error(data.error ?? `Request failed (${res.status})`);
        const next = data.matches ?? [];
        if (silent && next.length === 0) return;
        applyMatchList(next);
        if (!silent) setError(null);
      } catch (e) {
        if (!silent) {
          setError(e instanceof Error ? e.message : "Failed to load");
          setMatches([]);
        }
      } finally {
        if (!silent) setLoading(false);
      }
    },
    [sportType, applyMatchList],
  );

  const detailRef = useRef(detail);
  const matchesRef = useRef(matches);
  const selectedIdRef = useRef(selectedId);
  detailRef.current = detail;
  matchesRef.current = matches;
  selectedIdRef.current = selectedId;

  const refreshSelectedDetail = useCallback(async (match: LiveMatch) => {
    try {
      const [detailRes, eventsRes, lineupRes] = await Promise.all([
        fetch(apiUrl(`/api/match?matchId=${match.matchId}&sportType=${match.sportType}&language=0`), {
          cache: "no-store",
        }),
        fetch(apiUrl(`/api/match/events?matchId=${match.matchId}&sportType=${match.sportType}`), {
          cache: "no-store",
        }),
        fetch(apiUrl(`/api/match/lineup?matchId=${match.matchId}&sportType=${match.sportType}`), {
          cache: "no-store",
        }),
      ]);

      if (detailRes.ok) {
        const data = (await detailRes.json()) as {
          match?: LiveMatch;
          streams?: StreamServer[];
        };
        if (selectedIdRef.current !== match.matchId) return;
        const prev = detailRef.current?.matchId === match.matchId ? detailRef.current : match;
        const merged = mergeLiveFields(prev, { ...prev, ...(data.match ?? {}) });
        const streams = (data.streams ?? merged.streams) as StreamServer[];
        const withStreams = streams.length ? { ...merged, streams } : merged;
        const list = reliableServers(withStreams.streams);
        setDetail(withStreams);
        setServers(list.length ? list : withStreams.streams);
        setMatches((rows) =>
          rows.map((r) => (r.matchId === withStreams.matchId ? mergeLiveFields(r, withStreams) : r)),
        );
      }

      if (selectedIdRef.current !== match.matchId) return;

      if (eventsRes.ok) {
        const d = (await eventsRes.json()) as { events?: MatchEvent[] };
        if (d.events && d.events.length > 0) setEvents(d.events);
      }

      if (lineupRes.ok) {
        const d = (await lineupRes.json()) as {
          lineup?: { home: LineupPlayer[]; away: LineupPlayer[] };
        };
        if (d.lineup) setLineup(d.lineup);
      }
    } catch {
      // Soft-fail — next poll retries.
    }
  }, []);

  useEffect(() => {
    void loadMatches();
  }, [loadMatches]);

  useEffect(() => {
    const id = window.setInterval(() => {
      void loadMatches({ silent: true });
    }, LIVE_POLL_MS);
    return () => window.clearInterval(id);
  }, [loadMatches]);

  useEffect(() => {
    if (selectedId == null) return;
    const tick = () => {
      const id = selectedIdRef.current;
      if (id == null) return;
      const match =
        detailRef.current?.matchId === id
          ? detailRef.current
          : matchesRef.current.find((m) => m.matchId === id);
      if (match) void refreshSelectedDetail(match);
    };
    const delay = window.setTimeout(tick, 3_000);
    const id = window.setInterval(tick, LIVE_POLL_MS);
    return () => {
      window.clearTimeout(delay);
      window.clearInterval(id);
    };
  }, [selectedId, refreshSelectedDetail]);

  useEffect(() => {
    const t = window.setTimeout(() => setAppliedSearch(search.trim().toLowerCase()), 160);
    return () => window.clearTimeout(t);
  }, [search]);

  const liveCount = useMemo(
    () => matches.filter((m) => isLiveStatus(m.statusCode) && !isFinishedStatus(m.statusCode)).length,
    [matches],
  );

  const selected = detail ?? matches.find((m) => m.matchId === selectedId) ?? null;

  const filtered = useMemo(() => {
    let list = matches;
    if (filter === "live") {
      list = list.filter((m) => isLiveStatus(m.statusCode) && !isFinishedStatus(m.statusCode));
    }
    if (filter === "finished") list = list.filter((m) => isFinishedStatus(m.statusCode));
    if (appliedSearch) {
      list = list.filter((m) => {
        const hay = [
          m.name,
          m.leagueName,
          m.region,
          ...m.contenders.map((c) => c.name),
        ]
          .join(" ")
          .toLowerCase();
        return hay.includes(appliedSearch);
      });
    }
    // Pin the playing match so filter/search never hides the active session.
    if (selected && !list.some((m) => m.matchId === selected.matchId)) {
      list = [selected, ...list];
    }
    return list;
  }, [matches, filter, appliedSearch, selected]);

  const openMatch = async (match: LiveMatch) => {
    const switching = match.matchId !== selectedId;
    setSelectedId(match.matchId);
    setDetail(match);
    setMini(false);
    setTab("overview");
    if (switching) {
      setPlayableUrl(null);
      setActiveServerId(null);
      setEvents([]);
      setLineup(null);
    }
    setResolving(true);
    try {
      const res = await fetch(
        apiUrl(`/api/match?matchId=${match.matchId}&sportType=${match.sportType}&language=0`),
        { cache: "no-store" },
      );
      const data = (await res.json()) as {
        match?: LiveMatch;
        streams?: StreamServer[];
        error?: string;
      };
      if (!res.ok) throw new Error(data.error ?? "detail failed");
      if (selectedIdRef.current !== match.matchId) return;
      const merged: LiveMatch = {
        ...match,
        ...(data.match ?? {}),
        streams: (data.streams ?? match.streams) as StreamServer[],
      };
      setDetail(merged);
      const list = reliableServers(merged.streams);
      setServers(list.length ? list : merged.streams);
      const first = (list.length ? list : merged.streams)[0];
      if (first && (switching || !playableUrl)) await playServer(merged, first);
    } catch (e) {
      if (selectedIdRef.current !== match.matchId) return;
      setError(e instanceof Error ? e.message : "Detail failed");
      const list = reliableServers(match.streams);
      setServers(list.length ? list : match.streams);
    } finally {
      if (selectedIdRef.current === match.matchId) setResolving(false);
    }

    void fetch(apiUrl(`/api/match/events?matchId=${match.matchId}&sportType=${match.sportType}`), {
      cache: "no-store",
    })
      .then(async (r) => {
        const d = (await r.json()) as { events?: MatchEvent[]; error?: string };
        if (!r.ok) throw new Error(d.error ?? `events failed (${r.status})`);
        if (selectedIdRef.current !== match.matchId) return;
        setEvents(d.events ?? []);
      })
      .catch(() => {
        // Keep any prior timeline rather than wiping to empty on a flaky cold start.
      });
    void fetch(apiUrl(`/api/match/lineup?matchId=${match.matchId}&sportType=${match.sportType}`))
      .then((r) => r.json())
      .then((d: { lineup?: { home: LineupPlayer[]; away: LineupPlayer[] } }) => {
        if (selectedIdRef.current !== match.matchId) return;
        setLineup(d.lineup ?? null);
      })
      .catch(() => {
        if (selectedIdRef.current === match.matchId) setLineup(null);
      });
  };

  const playServer = async (match: LiveMatch, server: StreamServer) => {
    setActiveServerId(server.id);
    setResolving(true);
    setError(null);
    // Capture the click gesture: unlock a muted media element before the async resolve
    // so the browser still allows autoplay when the URL arrives.
    const existing = document.querySelector(".player-stage video") as HTMLVideoElement | null;
    if (existing) {
      existing.muted = true;
      setMuted(true);
      void existing.play().catch(() => undefined);
    }
    try {
      const q = new URLSearchParams({
        matchId: String(match.matchId),
        sportType: String(match.sportType),
      });
      if (server.streamId) q.set("streamId", server.streamId);
      // Prefer browser locale region (iOS Locale) over server IP geo.
      const localeRegion = (() => {
        try {
          return new Intl.Locale(navigator.language).region?.toUpperCase();
        } catch {
          return undefined;
        }
      })();
      if (localeRegion && /^[A-Z]{2}$/.test(localeRegion)) q.set("country", localeRegion);
      const res = await fetch(apiUrl(`/api/resolve?${q}`), { cache: "no-store" });
      const data = (await res.json()) as { playableUrl?: string; error?: string };
      if (!res.ok) throw new Error(data.error ?? "resolve failed");
      if (!data.playableUrl) throw new Error("missing playable url");
      setPlayableUrl(data.playableUrl);
    } catch (e) {
      setPlayableUrl(null);
      setError(e instanceof Error ? e.message : "Resolve failed");
    } finally {
      setResolving(false);
    }
  };

  const home = selected?.contenders[0];
  const away = selected?.contenders[1];
  const kick = selected ? formatKickoff(selected.startDate) : null;

  return (
    <div className="app-shell">
      <aside className="panel-left">
        <div className="brand-bar">
          <div className="brand">
            <div className="brand-mark">F</div>
            <div>
              <h1>FCTV33</h1>
              <p>Live Sports · BY ANIS</p>
            </div>
          </div>
          <button type="button" className="refresh-btn" onClick={() => void loadMatches()}>
            Refresh
          </button>
        </div>

        <div className="sports">
          {PRIMARY_SPORTS.map((s) => (
            <button
              key={s.type}
              type="button"
              className={`sport-btn ${sportType === s.type ? "is-active" : ""}`}
              onClick={() => {
                setShowMore(false);
                setSportType(s.type);
              }}
            >
              <span className="icon">{s.icon}</span>
              <span className="label">{s.label}</span>
            </button>
          ))}
          <button
            type="button"
            className={`sport-btn ${showMore ? "is-active" : ""}`}
            onClick={() => setShowMore((v) => !v)}
          >
            <span className="icon">＋</span>
            <span className="label">More</span>
          </button>
        </div>

        {showMore && (
          <div className="sports">
            {MORE_SPORTS.map((s) => (
              <button
                key={s.type}
                type="button"
                className={`sport-btn ${sportType === s.type ? "is-active" : ""}`}
                onClick={() => {
                  setSportType(s.type);
                  setShowMore(false);
                }}
              >
                <span className="icon">{s.icon}</span>
                <span className="label">{s.label}</span>
              </button>
            ))}
          </div>
        )}

        <div className="search-wrap">
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search teams, leagues, events…"
          />
        </div>

        <div className="filters">
          {(
            [
              ["all", "All"],
              ["live", "Live"],
              ["finished", "Finished"],
            ] as const
          ).map(([id, label]) => (
            <button
              key={id}
              type="button"
              className={`chip ${filter === id ? "is-active" : ""}`}
              onClick={() => setFilter(id)}
            >
              {id === "live" && <span className="live-dot" />}
              {label}
              {id === "live" ? ` ${liveCount}` : ""}
            </button>
          ))}
        </div>

        {error && <div className="error-banner">{error}</div>}
        {loading && <div className="status-line">Loading live events…</div>}

        <ul className="match-list">
          {!loading && filtered.length === 0 && (
            <li className="empty">{appliedSearch ? "No results" : "No Data — pull refresh"}</li>
          )}
          {filtered.map((match) => {
            const when = formatKickoff(match.startDate);
            const finished = isFinishedStatus(match.statusCode);
            const live = isLiveStatus(match.statusCode) && !finished;
            const h = match.contenders[0];
            const a = match.contenders[1];
            return (
              <li key={match.matchId}>
                <button
                  type="button"
                  className={`match-row ${selectedId === match.matchId ? "is-active" : ""}`}
                  onClick={() => void openMatch(match)}
                >
                  <div className="league">
                    <Logo src={match.leagueLogoURL} name={match.leagueName || "L"} size={16} />
                    <span>{match.leagueName || match.region || "Competition"}</span>
                    {live && <span className="live-dot" style={{ marginLeft: "auto" }} />}
                  </div>
                  <div className="body">
                    <div className="when">
                      {!when.isToday && <div>{when.date}</div>}
                      {live && match.liveClock ? (
                        <div className="clock">{match.liveClock}</div>
                      ) : finished ? (
                        <div>FT</div>
                      ) : (
                        <div>{when.time}</div>
                      )}
                    </div>
                    <div className="teams">
                      {h || a ? (
                        <>
                          <div className="team">
                            <Logo src={h?.logoURL} name={h?.name || "H"} />
                            <span>{h?.name || "Home"}</span>
                          </div>
                          <div className="team">
                            <Logo src={a?.logoURL} name={a?.name || "A"} />
                            <span>{a?.name || "Away"}</span>
                          </div>
                        </>
                      ) : (
                        <div className="team">
                          <span>{match.name}</span>
                        </div>
                      )}
                    </div>
                    <div>
                      <div className={`score ${finished ? "is-muted" : ""}`}>
                        {match.homeScore ?? "–"}
                      </div>
                      <div className={`score ${finished ? "is-muted" : ""}`}>
                        {match.awayScore ?? "–"}
                      </div>
                    </div>
                  </div>
                </button>
              </li>
            );
          })}
        </ul>
      </aside>

      <main className={`panel-right ${selected ? "" : "is-empty"}`}>
        {!selected && (
          <div className="right-empty">
            <h2>Select a Match</h2>
            <p>Pick an event on the left to open servers, lineup, and live playback.</p>
          </div>
        )}

        {selected && (
          <>
            <div className="detail-header">
              <div className="meta">
                <Logo src={selected.leagueLogoURL} name={selected.leagueName || "L"} size={18} />
                <span>{selected.leagueName || "Competition"}</span>
                {kick && (
                  <span>
                    {kick.date} · {kick.time}
                  </span>
                )}
                {selected.region && <span>{selected.region}</span>}
              </div>
              <div className="versus">
                <div className="side">
                  <Logo src={home?.logoURL} name={home?.name || "H"} size={56} />
                  <strong>{home?.name || selected.name}</strong>
                </div>
                <div className="center">
                  <div className="big-score">
                    {selected.homeScore ?? "–"} : {selected.awayScore ?? "–"}
                  </div>
                  {isLiveStatus(selected.statusCode) && !isFinishedStatus(selected.statusCode) ? (
                    <div className="live-chip">
                      <span className="live-dot" />
                      {selected.liveClock || "LIVE"}
                    </div>
                  ) : isFinishedStatus(selected.statusCode) ? (
                    <div className="live-chip" style={{ background: "rgba(255,255,255,0.08)", color: "#ccc" }}>
                      FT
                    </div>
                  ) : (
                    <div style={{ color: "var(--text-tertiary)", marginTop: 6 }}>{kick?.time}</div>
                  )}
                </div>
                <div className="side">
                  <Logo src={away?.logoURL} name={away?.name || "A"} size={56} />
                  <strong>{away?.name || ""}</strong>
                </div>
              </div>
            </div>

            {!mini && (
              <HlsPlayer
                src={playableUrl}
                title={
                  servers.find((s) => s.id === activeServerId)?.name ||
                  selected.name
                }
                muted={muted}
                onMutedChange={setMuted}
              />
            )}

            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
              <h3 className="section-title" style={{ margin: 0 }}>
                Servers {resolving ? "· resolving…" : ""}
              </h3>
              {playableUrl && (
                <button type="button" className="refresh-btn" onClick={() => setMini((v) => !v)}>
                  {mini ? "Expand player" : "Mini player"}
                </button>
              )}
            </div>
            <div className="servers">
              {servers.map((server) => (
                <button
                  key={server.id}
                  type="button"
                  className={`server-btn ${activeServerId === server.id ? "is-active" : ""}`}
                  onClick={() => void playServer(selected, server)}
                >
                  <div>
                    <div className="name">{server.name}</div>
                    {(server.country || server.fullName) && (
                      <div className="sub">{server.country || server.fullName}</div>
                    )}
                  </div>
                  <span>{activeServerId === server.id ? "✓" : "▶"}</span>
                </button>
              ))}
              {!servers.length && <div className="empty">Loading channels…</div>}
            </div>

            <div className="tabs">
              {(
                [
                  ["overview", "Overview"],
                  ["lineups", "Lineups"],
                  ["stats", "Stats"],
                  ["h2h", "H2H"],
                ] as const
              ).map(([id, label]) => (
                <button
                  key={id}
                  type="button"
                  className={`tab ${tab === id ? "is-active" : ""}`}
                  onClick={() => setTab(id)}
                >
                  {label}
                </button>
              ))}
            </div>

            <div className="tab-panel">
              {tab === "overview" && (
                <>
                  <div className="info-grid">
                    <div>
                      <span>Competition</span>
                      <strong>{selected.leagueName || "—"}</strong>
                    </div>
                    <div>
                      <span>Region</span>
                      <strong>{selected.region || "—"}</strong>
                    </div>
                    <div>
                      <span>Streams</span>
                      <strong>{servers.length}</strong>
                    </div>
                    <div>
                      <span>Clock</span>
                      <strong>{selected.liveClock || kick?.time || "—"}</strong>
                    </div>
                  </div>
                  <h3 className="section-title">Highlights</h3>
                  <ul className="timeline">
                    {events.length === 0 && <li><span /><span style={{ color: "var(--text-tertiary)" }}>No events yet</span></li>}
                    {events.map((ev) => (
                      <li key={ev.id}>
                        <span className="min">{ev.minute || ""}</span>
                        <span className={ev.kind === "goal" ? "goal" : ""}>{ev.text}</span>
                      </li>
                    ))}
                  </ul>
                </>
              )}

              {tab === "lineups" && (
                <div className="lineup-cols">
                  {(["home", "away"] as const).map((side) => {
                    const team = side === "home" ? home : away;
                    const rows = (lineup?.[side] ?? [])
                      .filter((p) => p.isStarter)
                      .sort((a, b) => a.positionOrder - b.positionOrder);
                    return (
                      <div key={side}>
                        <h3 className="section-title">{team?.name || side}</h3>
                        {rows.length === 0 && (
                          <div className="empty">Lineup unavailable</div>
                        )}
                        {rows.map((p) => (
                          <div className="player-row" key={p.id}>
                            <span>
                              <span className="pos">{p.positionLabel || p.number || ""}</span> {p.name}
                            </span>
                            <span style={{ color: "var(--text-tertiary)" }}>{p.number}</span>
                          </div>
                        ))}
                      </div>
                    );
                  })}
                </div>
              )}

              {tab === "stats" && (
                <div className="stats-bars">
                  {[
                    ["Possession", 56, 44],
                    ["Shots", 12, 9],
                    ["Shots on target", 5, 3],
                    ["Corners", 6, 4],
                    ["Fouls", 11, 13],
                  ].map(([label, hVal, aVal]) => {
                    const homeV = Number(hVal);
                    const awayV = Number(aVal);
                    const total = homeV + awayV || 1;
                    return (
                      <div key={String(label)}>
                        <div style={{ textAlign: "center", color: "var(--text-tertiary)", fontSize: "0.75rem", marginBottom: 4 }}>
                          {label}
                        </div>
                        <div className="stat-row">
                          <span>{homeV}</span>
                          <div className="stat-bar">
                            <i style={{ width: `${(homeV / total) * 100}%`, display: "block", height: "100%" }} />
                            <i style={{ width: `${(awayV / total) * 100}%`, display: "block", height: "100%" }} />
                          </div>
                          <span style={{ textAlign: "right" }}>{awayV}</span>
                        </div>
                      </div>
                    );
                  })}
                  <p style={{ color: "var(--text-tertiary)", fontSize: "0.75rem" }}>
                    Sample stats shell (same as iOS until API is wired).
                  </p>
                </div>
              )}

              {tab === "h2h" && (
                <div>
                  <div className="info-grid">
                    <div>
                      <span>{home?.name || "Home"} wins</span>
                      <strong>3</strong>
                    </div>
                    <div>
                      <span>Draws</span>
                      <strong>2</strong>
                    </div>
                    <div>
                      <span>{away?.name || "Away"} wins</span>
                      <strong>1</strong>
                    </div>
                  </div>
                  <p style={{ color: "var(--text-tertiary)", fontSize: "0.75rem" }}>
                    Sample H2H shell (same as iOS until API is wired).
                  </p>
                </div>
              )}
            </div>
          </>
        )}
      </main>

      {mini && playableUrl && selected && (
        <div className="mini-player">
          <div style={{ width: 96, height: 54, borderRadius: 8, overflow: "hidden", flexShrink: 0 }}>
            <HlsPlayer
              src={playableUrl}
              title={selected.name}
              muted={muted}
              onMutedChange={setMuted}
              fill
              className="mini"
            />
          </div>
          <div className="meta">
            <strong>{selected.name}</strong>
            <span>{servers.find((s) => s.id === activeServerId)?.name || "Live"}</span>
          </div>
          <button type="button" className="ctrl" onClick={() => setMini(false)} title="Expand">
            ⤴
          </button>
          <button
            type="button"
            className="ctrl"
            onClick={() => {
              setMini(false);
              setPlayableUrl(null);
              setActiveServerId(null);
            }}
            title="Close"
          >
            ✕
          </button>
        </div>
      )}
    </div>
  );
}
