function readVarint(buffer: Buffer, offset: number): [number, number] {
  let value = 0;
  let shift = 0;
  let index = offset;
  while (index < buffer.length) {
    const byte = buffer[index++]!;
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) break;
    shift += 7;
  }
  return [value, index];
}

function readVarintBig(buffer: Buffer, offset: number): [bigint, number] {
  let value = 0n;
  let shift = 0n;
  let index = offset;
  while (index < buffer.length) {
    const byte = BigInt(buffer[index++]!);
    value |= (byte & 0x7fn) << shift;
    if ((byte & 0x80n) === 0n) break;
    shift += 7n;
  }
  return [value, index];
}

function readBytes(buffer: Buffer, offset: number): [Buffer, number] {
  const [length, start] = readVarint(buffer, offset);
  return [buffer.subarray(start, start + length), start + length];
}

function readFields(buffer: Buffer): Map<number, Buffer[]> {
  const fields = new Map<number, Buffer[]>();
  let offset = 0;
  while (offset < buffer.length) {
    const [tag, next] = readVarint(buffer, offset);
    offset = next;
    const field = tag >> 3;
    const wire = tag & 0x7;
    if (wire === 0) {
      const [, after] = readVarintBig(buffer, offset);
      const encoded = buffer.subarray(offset, after);
      offset = after;
      const list = fields.get(field) ?? [];
      list.push(Buffer.from(encoded));
      fields.set(field, list);
      continue;
    }
    if (wire !== 2) break;
    const [chunk, after] = readBytes(buffer, offset);
    offset = after;
    const list = fields.get(field) ?? [];
    list.push(chunk);
    fields.set(field, list);
  }
  return fields;
}

function readVarintValue(buffer: Buffer | undefined): number | undefined {
  return buffer ? readVarint(buffer, 0)[0] : undefined;
}

function readVarint64(buffer: Buffer | undefined): number | undefined {
  if (!buffer) return undefined;
  const [v] = readVarintBig(buffer, 0);
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

const PREFERRED_LOGOS_HOST = "logos1.ta2mnt200stayr2.cfd";

function utf8(buffer: Buffer | undefined): string {
  return buffer?.toString("utf8") ?? "";
}

function isPrintableLabel(s: string): boolean {
  if (s.length < 2 || s.length > 120) return false;
  for (let i = 0; i < s.length; i++) {
    const code = s.charCodeAt(i);
    if (code < 32 || code === 127) return false;
  }
  return /[\p{L}]/u.test(s);
}

function sanitizeLabel(raw: string): string {
  let s = raw.trim();
  while (s.startsWith("$")) s = s.slice(1).trim();
  s = s.replace(/^\d{2,4}(-\d{2,4})?\s*:\s*/, "");
  if (s === "Success" || s === "OK") return "";
  return s;
}

function isPlausibleName(s: string): boolean {
  const t = sanitizeLabel(s);
  if (!isPrintableLabel(t)) return false;
  if (/^https?:/i.test(t)) return false;
  if (t.includes("/")) return false;
  if (/\.(png|jpg|jpeg|webp)/i.test(t)) return false;
  if (/^\d+$/.test(t)) return false;
  if (/^[0-9a-fA-F]{16,}$/.test(t)) return false;
  return true;
}

/** Recursively collect printable UTF-8 strings from protobuf length-delimited fields. */
function extractPrintableStrings(data: Buffer, depth = 0): string[] {
  if (depth > 4 || !data.length) return [];
  const out: string[] = [];
  let offset = 0;
  while (offset < data.length) {
    try {
      const [tag, next] = readVarint(data, offset);
      offset = next;
      const wire = tag & 0x7;
      if (wire === 0) {
        const [, after] = readVarintBig(data, offset);
        offset = after;
        continue;
      }
      if (wire !== 2) break;
      const [chunk, after] = readBytes(data, offset);
      offset = after;
      const asText = chunk.toString("utf8").trim();
      if (asText && isPrintableLabel(asText)) out.push(asText);
      out.push(...extractPrintableStrings(chunk, depth + 1));
    } catch {
      break;
    }
  }
  return out;
}

function normalizeLogoURL(raw?: string): string | undefined {
  if (!raw) return undefined;
  let s = raw.trim();
  const bang = s.indexOf("!");
  if (bang >= 0) s = s.slice(0, bang);
  try {
    const u = new URL(s);
    if (u.host.includes("logos") && u.host.endsWith(".cfd") && u.host !== PREFERRED_LOGOS_HOST) {
      u.host = PREFERRED_LOGOS_HOST;
      return u.toString();
    }
    return u.toString();
  } catch {
    if (s.startsWith("/")) return `https://${PREFERRED_LOGOS_HOST}${s}`;
    return undefined;
  }
}

function pickBestName(candidates: string[]): string {
  return (
    candidates
      .map(sanitizeLabel)
      .filter(isPlausibleName)
      .sort((a, b) => b.length - a.length)[0] ?? ""
  );
}

function parseNamedBlob(buffer: Buffer): { name: string; logoURL?: string } {
  const fields = readFields(buffer);
  const fieldStrings = new Map<number, string[]>();
  let logoURL: string | undefined;

  for (const [field, chunks] of fields) {
    for (const chunk of chunks) {
      const nested = extractPrintableStrings(chunk);
      for (const s of nested) {
        if (/^https?:/i.test(s)) {
          if (!logoURL) logoURL = normalizeLogoURL(s);
        } else if (isPlausibleName(s)) {
          const list = fieldStrings.get(field) ?? [];
          list.push(s);
          fieldStrings.set(field, list);
        }
      }
    }
  }

  // Prefer field 3 (canonical), then 2 / 15 / 5 …
  let name = "";
  for (const f of [3, 2, 15, 5, 10, 4, 1]) {
    const best = pickBestName(fieldStrings.get(f) ?? []);
    if (best) {
      name = best;
      break;
    }
  }
  if (!name) name = pickBestName([...fieldStrings.values()].flat());
  if (/\.(png|jpg)/i.test(name)) name = "";

  if (!logoURL) {
    const all = extractPrintableStrings(buffer);
    logoURL = normalizeLogoURL(all.find((s) => /^https?:/i.test(s) && /logo|aelogo|team|competition/i.test(s)));
    if (!logoURL) logoURL = normalizeLogoURL(all.find((s) => /^https?:/i.test(s)));
  }

  return { name, ...(logoURL ? { logoURL } : {}) };
}

export function parseApiEnvelope(buffer: Buffer): { message: string; payload: Buffer[] } {
  const fields = readFields(buffer);
  return {
    message: fields.get(3)?.[0]?.toString("utf8") ?? "",
    payload: fields.get(10) ?? [],
  };
}

export function parseSignatureEntries(buffer: Buffer): Array<{ code: number; value: string }> {
  const entries: Array<{ code: number; value: string }> = [];
  let offset = 0;
  while (offset < buffer.length) {
    const [tag, next] = readVarint(buffer, offset);
    offset = next;
    if ((tag & 0x7) !== 2) continue;
    const [chunk, after] = readBytes(buffer, offset);
    offset = after;
    let code = 0;
    let value = "";
    let inner = 0;
    while (inner < chunk.length) {
      const [innerTag, innerNext] = readVarint(chunk, inner);
      inner = innerNext;
      const field = innerTag >> 3;
      const wire = innerTag & 0x7;
      if (wire === 0) {
        const [num, numNext] = readVarint(chunk, inner);
        inner = numNext;
        if (field === 1) code = num;
      } else if (wire === 2) {
        const [text, textNext] = readBytes(chunk, inner);
        inner = textNext;
        if (field === 2) value = text.toString("utf8");
      }
    }
    if (code) entries.push({ code, value });
  }
  return entries;
}

export type UserGeo = { country?: string; continent?: string };

export function parseUserGeo(buffer: Buffer): UserGeo {
  const first = parseApiEnvelope(buffer).payload[0];
  if (!first) return {};
  const fields = readFields(first);
  const country = fields.get(2)?.[0]?.toString("utf8");
  const continent = fields.get(3)?.[0]?.toString("utf8");
  return {
    ...(country ? { country } : {}),
    ...(continent ? { continent } : {}),
  };
}

export type StreamItem = {
  streamId?: string;
  url?: string;
  name?: string;
  fullName?: string;
  siteType?: number;
  country?: string;
};

function parseStreamItem(buffer: Buffer): StreamItem & { matchId?: number } {
  const fields = readFields(buffer);
  const idChunk = fields.get(1)?.[0];
  const streamIdNum = idChunk ? readVarintValue(idChunk) : undefined;
  const streamId =
    streamIdNum !== undefined
      ? String(streamIdNum)
      : idChunk && idChunk.length > 8
        ? sanitizeLabel(idChunk.toString("utf8")) || undefined
        : undefined;
  const url = utf8(fields.get(4)?.[0]);
  // iOS parseStreamRow: name (3), fallback (15), fullName (8/10).
  const nameRaw = pickBestName([
    ...extractPrintableStrings(fields.get(3)?.[0] ?? Buffer.alloc(0)),
    utf8(fields.get(3)?.[0]),
    ...extractPrintableStrings(fields.get(15)?.[0] ?? Buffer.alloc(0)),
    utf8(fields.get(15)?.[0]),
  ]);
  const fullName = pickBestName([
    ...extractPrintableStrings(fields.get(8)?.[0] ?? Buffer.alloc(0)),
    ...extractPrintableStrings(fields.get(10)?.[0] ?? Buffer.alloc(0)),
    utf8(fields.get(8)?.[0]),
    utf8(fields.get(10)?.[0]),
    utf8(fields.get(7)?.[0]),
  ]);
  const siteType = readVarintValue(fields.get(9)?.[0]);
  const country = pickBestName([
    ...extractPrintableStrings(fields.get(11)?.[0] ?? Buffer.alloc(0)),
    utf8(fields.get(11)?.[0]),
    utf8(fields.get(12)?.[0]),
  ]);
  const matchId = readVarint64(fields.get(50)?.[0]) ?? readVarintValue(fields.get(50)?.[0]);
  return {
    ...(streamId ? { streamId } : {}),
    ...(url ? { url } : {}),
    ...(nameRaw ? { name: nameRaw } : {}),
    ...(fullName ? { fullName } : {}),
    ...(siteType !== undefined ? { siteType } : {}),
    ...(country ? { country } : {}),
    ...(matchId !== undefined ? { matchId } : {}),
  };
}

type FtbExtra = {
  minuteStatus: string;
  minute: number;
  firstStartMs: number;
  secondStartMs: number;
};

function parseFtbExtra(buffer: Buffer): FtbExtra {
  const fields = readFields(buffer);
  return {
    minuteStatus: utf8(fields.get(1)?.[0]).trim(),
    minute: readVarintValue(fields.get(2)?.[0]) ?? 0,
    firstStartMs: readVarint64(fields.get(3)?.[0]) ?? 0,
    secondStartMs: readVarint64(fields.get(4)?.[0]) ?? 0,
  };
}

/**
 * iOS `RbliveFtbMatchExtra.formattedClock` — timestamps on field 150 drive `76'` / `HT` / `90+'`.
 * Do not gate on statusCode (that produced bogus `120'` clocks).
 */
function formatFtbClock(extra: FtbExtra, nowMs = Date.now()): string | undefined {
  if (extra.secondStartMs > 0 && nowMs >= extra.secondStartMs) {
    const elapsed = Math.floor((nowMs - extra.secondStartMs) / 60_000);
    const total = 45 + Math.max(0, elapsed);
    if (total > 90) return "90+'";
    return `${total}'`;
  }
  if (extra.firstStartMs > 0 && nowMs >= extra.firstStartMs) {
    const elapsed = Math.floor((nowMs - extra.firstStartMs) / 60_000);
    if (elapsed > 45 && (extra.secondStartMs === 0 || nowMs < extra.secondStartMs)) {
      return "HT";
    }
    const clamped = Math.min(Math.max(elapsed, 0), 45);
    if (clamped === 0) return "1'";
    return `${clamped}'`;
  }
  // Rare: discrete minute when timestamps missing (same order as iOS).
  if (extra.minute > 0 && extra.minute <= 130) return `${extra.minute}'`;
  const status = extra.minuteStatus.trim();
  if (status) {
    const upper = status.toUpperCase();
    if (upper === "HT" || upper === "FT") return upper;
    if (/^\d{1,3}(\+\d{1,2})?'?$/.test(status)) {
      return status.endsWith("'") ? status : `${status}'`;
    }
  }
  return undefined;
}

function resolveLiveClock(statusCode: number, ftb: FtbExtra | undefined, gameTime?: string): string | undefined {
  // iOS: scheduled / finished → no live clock.
  if (statusCode === 0 || statusCode >= 10_000) return undefined;
  if (ftb) {
    const label = formatFtbClock(ftb);
    if (label) return label;
  }
  const raw = gameTime?.trim();
  if (!raw) return undefined;
  const upper = raw.toUpperCase();
  if (upper === "LIVE" || upper === "SUCCESS" || upper === "OK") return undefined;
  if (/^\d+$/.test(raw)) return `${raw}'`;
  return raw;
}

export type Contender = {
  id: string;
  name: string;
  logoURL?: string;
};

export type StreamServer = {
  id: string;
  name: string;
  fullName: string;
  streamId?: string;
  siteType?: number;
  country: string;
  countryCode?: string;
  flagURL?: string;
};

export type LiveMatch = {
  matchId: number;
  sportType: number;
  name: string;
  leagueName: string;
  leagueLogoURL?: string;
  region: string;
  contenders: Contender[];
  homeScore?: number;
  awayScore?: number;
  statusCode: number;
  startDate: number;
  liveClock?: string;
  hot: boolean;
  /** Live-list marker: match has at least one stream (full servers come from /api/match). */
  hasStreams: boolean;
  streams: StreamServer[];
};

function parseDataMatch(chunk: Buffer): Omit<LiveMatch, "streams"> | null {
  const fields = readFields(chunk);
  const matchId = readVarint64(fields.get(1)?.[0]) ?? readVarintValue(fields.get(1)?.[0]);
  const sportType = readVarintValue(fields.get(2)?.[0]);
  if (matchId === undefined || sportType === undefined) return null;

  const matchDateMs = readVarint64(fields.get(3)?.[0]) ?? 0;
  const statusCode = readVarintValue(fields.get(4)?.[0]) ?? 0;
  const gameTime = utf8(fields.get(5)?.[0]).trim() || undefined;

  let leagueName = "";
  let leagueLogoURL: string | undefined;
  for (const blob of fields.get(10) ?? []) {
    const comp = parseNamedBlob(blob);
    if (comp.name) leagueName = comp.name;
    if (comp.logoURL) leagueLogoURL = comp.logoURL;
  }

  let region = "";
  let regionLogoURL: string | undefined;
  for (const blob of fields.get(11) ?? []) {
    const country = parseNamedBlob(blob);
    if (country.name) region = country.name;
    if (country.logoURL) regionLogoURL = country.logoURL;
  }

  let homeName = "";
  let awayName = "";
  let homeLogoURL: string | undefined;
  let awayLogoURL: string | undefined;

  for (const blob of fields.get(20) ?? []) {
    const team = parseNamedBlob(blob);
    if (team.name) homeName = team.name;
    if (team.logoURL) homeLogoURL = team.logoURL;
  }
  for (const blob of fields.get(21) ?? []) {
    const team = parseNamedBlob(blob);
    if (team.name) awayName = team.name;
    if (team.logoURL) awayLogoURL = team.logoURL;
  }

  let teamBlobIndex = 0;
  for (const blob of fields.get(30) ?? []) {
    const team = parseNamedBlob(blob);
    if (/ vs /i.test(team.name)) {
      const parts = team.name.split(/\s+vs\s+/i);
      if (parts[0] && !homeName) homeName = parts[0].trim();
      if (parts[1] && !awayName) awayName = parts[1].trim();
      if (!homeLogoURL && team.logoURL) homeLogoURL = team.logoURL;
    } else if (team.name || team.logoURL) {
      if (teamBlobIndex === 0) {
        if (team.name) homeName = team.name;
        if (team.logoURL) homeLogoURL = team.logoURL;
        teamBlobIndex = 1;
      } else if (teamBlobIndex === 1) {
        if (team.name) awayName = team.name;
        if (team.logoURL) awayLogoURL = team.logoURL;
        teamBlobIndex = 2;
      }
    }
  }

  // Protobuf omits default varints — a real 0–0 (or 1–0) often arrives with field 22/23 missing.
  const homeScoreRaw = readVarintValue(fields.get(22)?.[0]);
  const awayScoreRaw = readVarintValue(fields.get(23)?.[0]);
  const hot = (readVarintValue(fields.get(80)?.[0]) ?? 0) !== 0;
  const ftb = fields.get(150)?.[0] ? parseFtbExtra(fields.get(150)![0]!) : undefined;
  const liveClock = resolveLiveClock(statusCode, ftb, gameTime);

  const contenders: Contender[] = [];
  // Never invent "Home"/"Away" placeholders — solo events (F1, MotoGP, …) must stay non-versus.
  if (homeName.trim()) {
    contenders.push({ id: "home", name: homeName, ...(homeLogoURL ? { logoURL: homeLogoURL } : {}) });
  } else if (homeLogoURL && awayName.trim()) {
    // Logo-only home side only when there is a real away name (true versus).
    contenders.push({ id: "home", name: homeName || "Home", logoURL: homeLogoURL });
  }
  if (awayName.trim()) {
    contenders.push({ id: "away", name: awayName, ...(awayLogoURL ? { logoURL: awayLogoURL } : {}) });
  } else if (awayLogoURL && homeName.trim()) {
    contenders.push({ id: "away", name: awayName || "Away", logoURL: awayLogoURL });
  }

  const isVersus = contenders.length >= 2;
  const matchHasStarted = statusCode !== 0; // live, finished, or abandoned — not pre-kickoff
  const homeScore =
    homeScoreRaw !== undefined ? homeScoreRaw : isVersus && matchHasStarted ? 0 : undefined;
  const awayScore =
    awayScoreRaw !== undefined ? awayScoreRaw : isVersus && matchHasStarted ? 0 : undefined;

  const name =
    homeName && awayName
      ? `${homeName} vs ${awayName}`
      : homeName || awayName || leagueName || `Match ${matchId}`;

  return {
    matchId,
    sportType,
    name,
    leagueName,
    ...((leagueLogoURL ?? regionLogoURL) ? { leagueLogoURL: leagueLogoURL ?? regionLogoURL } : {}),
    region,
    contenders,
    ...(homeScore !== undefined ? { homeScore } : {}),
    ...(awayScore !== undefined ? { awayScore } : {}),
    statusCode,
    startDate: matchDateMs > 0 ? matchDateMs : Date.now(),
    ...(liveClock ? { liveClock } : {}),
    hot,
    hasStreams: false,
  };
}

function parseStreamServer(buffer: Buffer, index: number): StreamServer | null {
  const item = parseStreamItem(buffer);
  if (!item.streamId && !item.name) return null;
  const name = (item.name ?? "").replace(/^\$+/, "").trim();
  const fullName = (item.fullName ?? "").replace(/^\$+/, "").trim();
  return {
    id: item.streamId ?? `s-${index}`,
    name: name || fullName || `Stream ${item.streamId ?? index}`,
    fullName,
    ...(item.streamId ? { streamId: item.streamId } : {}),
    ...(item.siteType !== undefined ? { siteType: item.siteType } : {}),
    country: item.country ?? "",
  };
}

export function parseLiveMatchList(buffer: Buffer): LiveMatch[] {
  const { message, payload } = parseApiEnvelope(buffer);
  const rootBuf = payload[0];
  if (message !== "Success" || !rootBuf) return [];
  const root = readFields(rootBuf);

  // Live-list field 2 is often a presence marker (matchId only). When the upstream
  // includes full PBDataStream rows (name/siteType/streamId), attach them like iOS.
  const streamsByMatch = new Map<number, StreamServer[]>();
  const hasStreamIds = new Set<number>();
  for (const chunk of root.get(2) ?? []) {
    const item = parseStreamItem(chunk);
    if (item.matchId === undefined) continue;
    hasStreamIds.add(item.matchId);
    const bucket = streamsByMatch.get(item.matchId) ?? [];
    const server = parseStreamServer(chunk, bucket.length);
    if (server) {
      bucket.push(server);
      streamsByMatch.set(item.matchId, bucket);
    }
  }

  const matches: LiveMatch[] = [];
  for (const chunk of root.get(1) ?? []) {
    const parsed = parseDataMatch(chunk);
    if (!parsed) continue;
    const streams = streamsByMatch.get(parsed.matchId) ?? [];
    matches.push({
      ...parsed,
      hasStreams: streams.length > 0 || hasStreamIds.has(parsed.matchId),
      streams,
    });
  }

  return matches;
}

export function parseMatchDetail(buffer: Buffer): { match?: Omit<LiveMatch, "streams">; stream: StreamItem[] } {
  const first = parseApiEnvelope(buffer).payload[0];
  if (!first) return { stream: [] };
  const fields = readFields(first);
  const matchChunk = fields.get(1)?.[0];
  const match = matchChunk ? parseDataMatch(matchChunk) ?? undefined : undefined;
  const stream = (fields.get(2) ?? []).map(parseStreamItem);
  return { ...(match ? { match } : {}), stream };
}

export function parseStreamDetail(buffer: Buffer): StreamItem {
  const first = parseApiEnvelope(buffer).payload[0];
  if (!first) return {};
  const fields = readFields(first);
  return parseStreamItem(fields.get(2)?.[0] ?? fields.get(1)?.[0] ?? first);
}

export type LineupPlayer = {
  id: string;
  name: string;
  number?: string;
  positionLabel: string;
  positionOrder: number;
  isStarter: boolean;
};

export type MatchLineup = { home: LineupPlayer[]; away: LineupPlayer[] };

function positionLabel(code: number): string {
  // Same mapping as iOS `positionLabel` (PBDataMatchLineup.position).
  switch (code) {
    case 1:
      return "FWD";
    case 2:
      return "MID";
    case 3:
      return "DEF";
    case 4:
      return "GK";
    default:
      return "";
  }
}

/** `PBDataPlayer`: playerId (1), name map<int32,string> (3). */
function parsePlayerName(blob?: Buffer): string {
  if (!blob) return "";
  const fields = readFields(blob);
  const names = new Map<number, string>();
  for (const entry of fields.get(3) ?? []) {
    const ef = readFields(entry);
    const key = readVarintValue(ef.get(1)?.[0]);
    const value = utf8(ef.get(2)?.[0]).trim();
    if (key !== undefined && value) names.set(key, value);
  }
  const mapped = names.get(1) ?? names.get(0) ?? [...names.values()][0] ?? "";
  if (mapped && isPlausibleName(mapped)) return sanitizeLabel(mapped);
  return pickBestName(extractPrintableStrings(blob));
}

function parseLineupRow(buffer: Buffer, index: number): LineupPlayer | null {
  const fields = readFields(buffer);
  const name =
    parsePlayerName(fields.get(1)?.[0]) ||
    pickBestName(extractPrintableStrings(fields.get(6)?.[0] ?? Buffer.alloc(0)));
  if (!name) return null;
  const position = readVarintValue(fields.get(2)?.[0]) ?? 0;
  const positionOrder = readVarintValue(fields.get(3)?.[0]) ?? index;
  const appearance = readVarintValue(fields.get(4)?.[0]) ?? 1;
  const numberRaw = utf8(fields.get(5)?.[0]).trim();
  const number = /^\d+$/.test(numberRaw) ? numberRaw : undefined;
  return {
    id: `${name}-${number ?? index}`,
    name,
    ...(number ? { number } : {}),
    positionLabel: positionLabel(position),
    positionOrder,
    isStarter: appearance === 1,
  };
}

export function parseMatchLineup(buffer: Buffer): MatchLineup {
  const first = parseApiEnvelope(buffer).payload[0] ?? buffer;
  const fields = readFields(first);
  const home = (fields.get(1) ?? [])
    .map((c, i) => parseLineupRow(c, i))
    .filter((p): p is LineupPlayer => p !== null);
  const away = (fields.get(2) ?? [])
    .map((c, i) => parseLineupRow(c, i))
    .filter((p): p is LineupPlayer => p !== null);
  return { home, away };
}

export type MatchEvent = {
  id: string;
  minute?: string;
  text: string;
  kind: "goal" | "status" | "info";
};

function parseDataMatchEvent(chunk: Buffer, index: number): MatchEvent | null {
  const f = readFields(chunk);
  const type = readVarintValue(f.get(3)?.[0]) ?? 0;
  const minute = utf8(f.get(4)?.[0]);
  const score = utf8(f.get(5)?.[0]);
  const reason = utf8(f.get(6)?.[0]);
  const side = readVarintValue(f.get(7)?.[0]) ?? 0;
  const scorer = parsePlayerName(f.get(10)?.[0]);
  const assist = parsePlayerName(f.get(11)?.[0]);
  const booked = parsePlayerName(f.get(20)?.[0]);
  const subIn = parsePlayerName(f.get(30)?.[0]);
  const subOut = parsePlayerName(f.get(31)?.[0]);

  let kind: MatchEvent["kind"];
  let text: string;
  switch (type) {
    case 101: {
      kind = "goal";
      let t = "Goal";
      if (scorer) t += ` — ${scorer}`;
      if (assist) t += ` (assist ${assist})`;
      if (score) t += ` · ${score}`;
      text = t;
      break;
    }
    case 102: {
      kind = "goal";
      text = ["Own goal", scorer && `— ${scorer}`, score && `· ${score}`].filter(Boolean).join(" ");
      break;
    }
    case 103: {
      kind = "goal";
      text = ["Penalty", scorer && `— ${scorer}`, score && `· ${score}`].filter(Boolean).join(" ");
      break;
    }
    case 105: {
      kind = "info";
      if (subIn && subOut) text = `Sub — ${subIn} on for ${subOut}`;
      else if (subIn) text = `Sub — ${subIn} on`;
      else if (subOut) text = `Sub — ${subOut} off`;
      else text = "Substitution";
      break;
    }
    case 106: {
      kind = "info";
      text = ["Yellow card", booked && `— ${booked}`, reason && `· ${reason}`].filter(Boolean).join(" ");
      break;
    }
    case 107: {
      kind = "info";
      text = ["Red card", booked && `— ${booked}`, reason && `· ${reason}`].filter(Boolean).join(" ");
      break;
    }
    case 108: {
      kind = "info";
      text = ["Second yellow", booked && `— ${booked}`, reason && `· ${reason}`].filter(Boolean).join(" ");
      break;
    }
    case 10001:
      kind = "status";
      text = "Kick-off";
      break;
    case 10002:
      kind = "status";
      text = "Second half";
      break;
    case 10003:
      kind = "status";
      text = score ? `Half-time · ${score}` : "Half-time";
      break;
    case 10005:
      kind = "status";
      text = score ? `Full time · ${score}` : "Full time";
      break;
    default:
      return null;
  }

  const minuteLabel = minute
    ? minute.includes("'")
      ? minute
      : `${minute}'`
    : undefined;
  return {
    id: `ev-${type}-${minute}-${index}-${side}-${scorer}-${booked}-${subIn}-${score}`,
    ...(minuteLabel ? { minute: minuteLabel } : {}),
    text,
    kind,
  };
}

export function parseMatchEvents(buffer: Buffer): MatchEvent[] {
  const first = parseApiEnvelope(buffer).payload[0] ?? buffer;
  const fields = readFields(first);
  const chronological: MatchEvent[] = [];
  let i = 0;
  for (const chunk of fields.get(1) ?? []) {
    const row = parseDataMatchEvent(chunk, i++);
    if (row) chronological.push(row);
  }
  return chronological.reverse().slice(0, 60);
}

export type MatchStatRow = {
  type: number;
  label: string;
  home: number;
  away: number;
  /** True when values are percentages that already sum ~100. */
  isPercent: boolean;
};

export type H2HMeeting = {
  matchId: number;
  startDate: number;
  homeName: string;
  awayName: string;
  homeScore: number;
  awayScore: number;
  leagueName?: string;
};

export type H2HSummary = {
  wins: number;
  draws: number;
  losses: number;
  meetings: H2HMeeting[];
};

/** Upstream `/api/match/statistic` type codes → UI labels (football-oriented). */
const STAT_LABELS: Record<number, { label: string; isPercent?: boolean }> = {
  100: { label: "Possession", isPercent: true },
  101: { label: "Attacks" },
  102: { label: "Dangerous attacks" },
  154: { label: "Shots on target" },
  155: { label: "Corners" },
  107: { label: "Yellow cards" },
  109: { label: "Red cards" },
  103: { label: "Shots" },
  104: { label: "Shots off target" },
  105: { label: "Blocked shots" },
  106: { label: "Fouls" },
  108: { label: "Offsides" },
  110: { label: "Saves" },
};

const STAT_ORDER = [100, 101, 102, 103, 154, 155, 106, 107, 109, 108, 104, 105, 110];

export function parseMatchStatistics(buffer: Buffer): MatchStatRow[] {
  const first = parseApiEnvelope(buffer).payload[0] ?? buffer;
  const fields = readFields(first);
  const byType = new Map<number, MatchStatRow>();
  for (const chunk of fields.get(1) ?? []) {
    const row = readFields(chunk);
    const type = readVarintValue(row.get(3)?.[0]);
    if (type === undefined) continue;
    const home = readVarintValue(row.get(10)?.[0]) ?? 0;
    const away = readVarintValue(row.get(11)?.[0]) ?? 0;
    const meta = STAT_LABELS[type] ?? { label: `Stat ${type}` };
    byType.set(type, {
      type,
      label: meta.label,
      home,
      away,
      isPercent: meta.isPercent === true,
    });
  }
  const ordered: MatchStatRow[] = [];
  for (const type of STAT_ORDER) {
    const row = byType.get(type);
    if (row) ordered.push(row);
    byType.delete(type);
  }
  for (const row of byType.values()) ordered.push(row);
  return ordered;
}

function splitVersusTitle(title: string): { home: string; away: string } | null {
  const parts = title.split(/\s+vs\s+/i);
  if (parts.length !== 2) return null;
  const home = parts[0]!.trim();
  const away = parts[1]!.trim();
  if (!home || !away) return null;
  return { home, away };
}

function parseAnalysisMeeting(chunk: Buffer): H2HMeeting | null {
  const fields = readFields(chunk);
  const matchId = readVarint64(fields.get(1)?.[0]) ?? readVarintValue(fields.get(1)?.[0]);
  if (matchId === undefined) return null;
  const startDate = readVarint64(fields.get(3)?.[0]) ?? 0;
  const statusCode = readVarintValue(fields.get(4)?.[0]) ?? 0;
  const homeScoreRaw = readVarintValue(fields.get(22)?.[0]);
  const awayScoreRaw = readVarintValue(fields.get(23)?.[0]);
  // Skip fixtures that have not been played yet.
  const finished = statusCode >= 10_000 || statusCode === -1;
  const hasScore = homeScoreRaw !== undefined || awayScoreRaw !== undefined;
  if (!finished && !hasScore) return null;
  if (startDate > Date.now() + 60_000 && !hasScore) return null;

  let homeName = "";
  let awayName = "";
  let leagueName = "";
  for (const blob of fields.get(30) ?? []) {
    const inner = readFields(blob);
    const title = utf8(inner.get(2)?.[0]).trim();
    const split = splitVersusTitle(title);
    if (split) {
      homeName = split.home;
      awayName = split.away;
    }
  }
  for (const blob of fields.get(10) ?? []) {
    const comp = parseNamedBlob(blob);
    if (comp.name && !leagueName) leagueName = comp.name;
  }
  if (!homeName || !awayName) {
    const strings = extractPrintableStrings(chunk).filter(
      (t) => !t.startsWith("http") && !t.includes("/") && t.length < 60,
    );
    const vs = strings.find((t) => /\svs\s/i.test(t));
    const split = vs ? splitVersusTitle(vs) : null;
    if (split) {
      homeName = split.home;
      awayName = split.away;
    }
  }
  if (!homeName || !awayName) return null;

  return {
    matchId,
    startDate,
    homeName,
    awayName,
    homeScore: homeScoreRaw ?? 0,
    awayScore: awayScoreRaw ?? 0,
    ...(leagueName ? { leagueName } : {}),
  };
}

function normalizeTeam(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

function teamsMatch(a: string, b: string): boolean {
  const na = normalizeTeam(a);
  const nb = normalizeTeam(b);
  if (!na || !nb) return false;
  return na === nb || na.includes(nb) || nb.includes(na);
}

export function parseMatchAnalysis(
  buffer: Buffer,
  perspectiveHomeName = "",
): H2HSummary {
  const first = parseApiEnvelope(buffer).payload[0] ?? buffer;
  const fields = readFields(first);
  const meetings = (fields.get(1) ?? [])
    .map((chunk) => parseAnalysisMeeting(chunk))
    .filter((m): m is H2HMeeting => m !== null)
    .sort((a, b) => b.startDate - a.startDate);

  let wins = 0;
  let draws = 0;
  let losses = 0;
  const homeKey = perspectiveHomeName.trim();
  for (const m of meetings) {
    if (m.homeScore === m.awayScore) {
      draws++;
      continue;
    }
    const homeWon = m.homeScore > m.awayScore;
    if (!homeKey) {
      if (homeWon) wins++;
      else losses++;
      continue;
    }
    const perspectiveWasHome = teamsMatch(homeKey, m.homeName);
    const perspectiveWasAway = teamsMatch(homeKey, m.awayName);
    if (perspectiveWasHome) {
      if (homeWon) wins++;
      else losses++;
    } else if (perspectiveWasAway) {
      if (homeWon) losses++;
      else wins++;
    } else if (homeWon) {
      wins++;
    } else {
      losses++;
    }
  }

  return {
    wins,
    draws,
    losses,
    meetings: meetings.slice(0, 10),
  };
}
