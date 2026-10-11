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

function utf8(buffer: Buffer | undefined): string {
  return buffer?.toString("utf8") ?? "";
}

function firstHttpUrl(text: string): string | undefined {
  const m = text.match(/https?:\/\/[^\s"']+/);
  return m?.[0];
}

function harvestStrings(buffer: Buffer, out: string[] = []): string[] {
  const fields = readFields(buffer);
  for (const chunks of fields.values()) {
    for (const chunk of chunks) {
      const asText = chunk.toString("utf8");
      if (asText.length >= 2 && /^[\x20-\x7E\u00A0-\uFFFF]+$/.test(asText) && asText.length < 200) {
        out.push(asText);
      } else if (chunk.length > 2) {
        harvestStrings(chunk, out);
      }
    }
  }
  return out;
}

function parseNamedBlob(buffer: Buffer): { name: string; logoURL?: string } {
  const fields = readFields(buffer);
  let name = utf8(fields.get(2)?.[0]) || utf8(fields.get(3)?.[0]) || utf8(fields.get(1)?.[0]);
  if (!name) {
    const harvested = harvestStrings(buffer).filter((s) => !s.startsWith("http"));
    name = harvested.sort((a, b) => b.length - a.length)[0] ?? "";
  }
  let logoURL: string | undefined;
  for (const field of [4, 5, 6, 7, 8]) {
    const raw = utf8(fields.get(field)?.[0]);
    const url = firstHttpUrl(raw) ?? (raw.startsWith("http") ? raw : undefined);
    if (url) {
      logoURL = url;
      break;
    }
  }
  if (!logoURL) {
    for (const s of harvestStrings(buffer)) {
      const url = firstHttpUrl(s);
      if (url) {
        logoURL = url;
        break;
      }
    }
  }
  return { name: name.trim(), ...(logoURL ? { logoURL } : {}) };
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

function parseStreamItem(buffer: Buffer): StreamItem {
  const fields = readFields(buffer);
  const idChunk = fields.get(1)?.[0];
  const streamId =
    idChunk && idChunk.length <= 8
      ? String(readVarint(idChunk, 0)[0])
      : idChunk?.toString("utf8");
  const url = fields.get(4)?.[0]?.toString("utf8");
  const name = fields.get(3)?.[0]?.toString("utf8");
  const fullName =
    fields.get(8)?.[0]?.toString("utf8") ||
    fields.get(10)?.[0]?.toString("utf8") ||
    fields.get(7)?.[0]?.toString("utf8");
  const siteType = readVarintValue(fields.get(9)?.[0]);
  const country = fields.get(11)?.[0]?.toString("utf8") || fields.get(12)?.[0]?.toString("utf8");
  return {
    ...(streamId ? { streamId } : {}),
    ...(url ? { url } : {}),
    ...(name ? { name } : {}),
    ...(fullName ? { fullName } : {}),
    ...(siteType !== undefined ? { siteType } : {}),
    ...(country ? { country } : {}),
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

function formatFtbClock(extra: FtbExtra, statusCode: number): string | undefined {
  const now = Date.now();
  if (extra.secondStartMs > 0 && statusCode >= 4) {
    const elapsed = Math.floor((now - extra.secondStartMs) / 60000);
    const minute = Math.min(90 + Math.max(0, elapsed), 120);
    return `${minute}'`;
  }
  if (extra.firstStartMs > 0 && statusCode > 0 && statusCode < 10_000) {
    const elapsed = Math.floor((now - extra.firstStartMs) / 60000);
    if (elapsed >= 0 && elapsed <= 120) return `${Math.min(elapsed + 1, 45)}'`;
  }
  if (extra.minuteStatus) {
    const u = extra.minuteStatus.toUpperCase();
    if (u === "HT" || u === "FT" || u === "ET" || u === "PEN") return u;
    if (/^\d+$/.test(extra.minuteStatus)) return `${extra.minuteStatus}'`;
    return extra.minuteStatus;
  }
  if (extra.minute > 0) return `${extra.minute}'`;
  return undefined;
}

function resolveLiveClock(statusCode: number, ftb: FtbExtra | undefined, gameTime?: string): string | undefined {
  if (statusCode === 0 || statusCode >= 10_000) return undefined;
  if (ftb) {
    const label = formatFtbClock(ftb, statusCode);
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
  for (const blob of fields.get(11) ?? []) {
    const country = parseNamedBlob(blob);
    if (country.name) region = country.name;
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

  const homeScore = readVarintValue(fields.get(22)?.[0]);
  const awayScore = readVarintValue(fields.get(23)?.[0]);
  const hot = (readVarintValue(fields.get(80)?.[0]) ?? 0) !== 0;
  const ftb = fields.get(150)?.[0] ? parseFtbExtra(fields.get(150)![0]!) : undefined;
  const liveClock = resolveLiveClock(statusCode, ftb, gameTime);

  const contenders: Contender[] = [];
  if (homeName || homeLogoURL) {
    contenders.push({ id: "home", name: homeName || "Home", ...(homeLogoURL ? { logoURL: homeLogoURL } : {}) });
  }
  if (awayName || awayLogoURL) {
    contenders.push({ id: "away", name: awayName || "Away", ...(awayLogoURL ? { logoURL: awayLogoURL } : {}) });
  }

  const name =
    homeName && awayName
      ? `${homeName} vs ${awayName}`
      : homeName || awayName || leagueName || `Match ${matchId}`;

  return {
    matchId,
    sportType,
    name,
    leagueName,
    ...(leagueLogoURL ? { leagueLogoURL } : {}),
    region,
    contenders,
    ...(homeScore !== undefined ? { homeScore } : {}),
    ...(awayScore !== undefined ? { awayScore } : {}),
    statusCode,
    startDate: matchDateMs > 0 ? matchDateMs : Date.now(),
    ...(liveClock ? { liveClock } : {}),
    hot,
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

  const streamsByMatch = new Map<number, StreamServer[]>();
  for (const chunk of root.get(2) ?? []) {
    const fields = readFields(chunk);
    const matchId = readVarintValue(fields.get(50)?.[0]);
    if (matchId === undefined) continue;
    const servers = (fields.get(2) ?? [])
      .map((s, i) => parseStreamServer(s, i))
      .filter((s): s is StreamServer => s !== null);
    if (servers.length) {
      const prev = streamsByMatch.get(matchId) ?? [];
      streamsByMatch.set(matchId, [...prev, ...servers]);
    } else {
      streamsByMatch.set(matchId, streamsByMatch.get(matchId) ?? []);
    }
  }

  // Also accept matches that only appear as stream hosts with match id.
  const streamIds = new Set(streamsByMatch.keys());

  const matches: LiveMatch[] = [];
  for (const chunk of root.get(1) ?? []) {
    const parsed = parseDataMatch(chunk);
    if (!parsed) continue;
    if (streamIds.size && !streamIds.has(parsed.matchId) && !(parsed.statusCode > 0 && parsed.statusCode < 10_000)) {
      // Keep scheduled/live rows even without stream map when API omits field 2 links.
    }
    matches.push({
      ...parsed,
      streams: streamsByMatch.get(parsed.matchId) ?? [],
    });
  }

  // Prefer rows that have streams when filtering empty sport days, but return all parsed.
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
  switch (code) {
    case 1:
      return "GK";
    case 2:
      return "DEF";
    case 3:
      return "MID";
    case 4:
      return "FWD";
    default:
      return "";
  }
}

function parseLineupRow(buffer: Buffer, index: number): LineupPlayer | null {
  const fields = readFields(buffer);
  const playerBlob = fields.get(1)?.[0];
  const playerFields = playerBlob ? readFields(playerBlob) : new Map<number, Buffer[]>();
  const name = utf8(playerFields.get(2)?.[0]) || utf8(fields.get(6)?.[0]);
  if (!name) return null;
  const position = readVarintValue(fields.get(2)?.[0]) ?? 0;
  const positionOrder = readVarintValue(fields.get(3)?.[0]) ?? index;
  const appearance = readVarintValue(fields.get(4)?.[0]) ?? 1;
  const number = utf8(fields.get(5)?.[0]) || undefined;
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

function pickBestName(candidates: string[]): string {
  return (
    candidates
      .map(sanitizeLabel)
      .filter(isPlausibleName)
      .sort((a, b) => b.length - a.length)[0] ?? ""
  );
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

/** iOS / api `PBDataMatchEvent` — goals, cards, subs, period markers. */
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

  const minuteLabel = minute ? (minute.includes("'") ? minute : `${minute}'`) : undefined;
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
