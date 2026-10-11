import { rot47 } from "../crypto/rot47.js";
import { requestHashPrefix, sortRequestParams, type RequestParams } from "../crypto/request-hash.js";
import { PATH, SIGNATURE, SIGNATURE_CODES, USER_AGENT } from "../config/site.js";
import { loadSiteBootstrap, clearSiteBootstrap } from "./bootstrap.js";
import { enrichStreamCountry } from "./country.js";
import {
  getOrFetchSignatures,
  invalidateSignatureCache,
  signatureCacheKey,
} from "./signature-cache.js";
import {
  parseApiEnvelope,
  parseLiveMatchList,
  parseMatchAnalysis,
  parseMatchDetail,
  parseMatchEvents,
  parseMatchLineup,
  parseMatchStatistics,
  parseSignatureEntries,
  parseStreamDetail,
  parseUserGeo,
  type H2HSummary,
  type LiveMatch,
  type MatchEvent,
  type MatchLineup,
  type MatchStatRow,
  type StreamItem,
  type UserGeo,
} from "./protobuf.js";

type RequestContext = { referer: string; origin: string };

function headers(context: RequestContext): Record<string, string> {
  return {
    Referer: context.referer,
    Origin: context.origin,
    Accept: "application/json, text/plain, */*",
    "User-Agent": USER_AGENT,
  };
}

const AUTH_RETRY_STATUSES = new Set([401, 403, 419, 440, 498]);

export class ApiClient {
  private signatureKeys = new Map<number, string>();
  private signatureCacheKey = "";
  private siteConfig: Record<string, string> | null = null;
  private dataApiBaseUrl: string | null = null;
  private digit: string | null = null;
  private context: RequestContext | null = null;
  private playerReferer: string | null = null;
  /** Upstream `rb-session` — stale values poison detail/stream calls (same as iOS). */
  private rbSession: string | null = null;

  private async bootstrap(force = false): Promise<void> {
    if (!force && this.dataApiBaseUrl && this.digit && this.context) return;
    const site = await loadSiteBootstrap(force);
    this.dataApiBaseUrl = site.dataApiBaseUrl.replace(/\/$/, "");
    this.digit = site.digit;
    this.context = { referer: `${site.entryOrigin}/`, origin: site.entryOrigin };
  }

  /** Drop stale `rb-session` only (iOS `clearSession`) — signatures stay valid for the retry. */
  private clearSession(reason?: string): void {
    if (this.rbSession) {
      console.warn(`[api] clearSession${reason ? ` (${reason})` : ""}`);
    }
    this.rbSession = null;
  }

  /** Cold retry: drop session + body signatures (empty streams / hard upstream failures). */
  private clearAuthState(reason?: string): void {
    if (this.rbSession || this.signatureKeys.size) {
      console.warn(`[api] clearAuthState${reason ? ` (${reason})` : ""}`);
    }
    this.rbSession = null;
    if (this.signatureCacheKey) invalidateSignatureCache(this.signatureCacheKey);
    else invalidateSignatureCache();
    this.signatureKeys.clear();
    this.signatureCacheKey = "";
  }

  private buildHeaders(attachSession = true): Record<string, string> {
    const h = headers(this.req());
    if (attachSession && this.rbSession) h["rb-session"] = this.rbSession;
    return h;
  }

  private captureSession(response: Response): void {
    const header = response.headers.get("rb-session") ?? response.headers.get("Rb-Session");
    if (header?.trim()) {
      this.rbSession = header.trim();
      return;
    }
    const getSetCookie = response.headers.getSetCookie?.bind(response.headers);
    if (!getSetCookie) return;
    for (const cookie of getSetCookie()) {
      const match = /^rb-session=([^;]+)/i.exec(cookie);
      if (match?.[1]) {
        this.rbSession = decodeURIComponent(match[1]);
        return;
      }
    }
  }

  private static isAuthFailure(status: number): boolean {
    return AUTH_RETRY_STATUSES.has(status);
  }

  private static isRetryableMessage(msg: string): boolean {
    return /signature bootstrap failed|auth failed|rate limited|cloudflare|match detail failed/i.test(
      msg,
    );
  }

  private baseUrl(): string {
    if (!this.dataApiBaseUrl) throw new Error("data api base url not set");
    return this.dataApiBaseUrl;
  }

  private req(): RequestContext {
    if (!this.context) throw new Error("request context not set");
    return this.context;
  }

  private async loadSiteConfig(): Promise<Record<string, string>> {
    await this.bootstrap();
    if (this.siteConfig) return this.siteConfig;
    const response = await fetch(`${this.baseUrl()}${PATH.params}`, { headers: headers(this.req()) });
    this.siteConfig = JSON.parse(rot47(await response.text())) as Record<string, string>;
    return this.siteConfig;
  }

  async resolvePlayerReferer(): Promise<string> {
    if (this.playerReferer) return this.playerReferer;
    const config = await this.loadSiteConfig();
    const webClients = JSON.parse(config["common:web:client"] ?? "{}") as Record<
      string,
      { iframePlayerDomains?: string[] }
    >;
    for (const client of Object.values(webClients)) {
      const host = client.iframePlayerDomains?.[0];
      if (host) {
        this.playerReferer = `https://${host.replace(/^https?:\/\//, "").replace(/\/$/, "")}/`;
        return this.playerReferer;
      }
    }
    const domains = JSON.parse(config.g_player_domains ?? "{}") as Record<string, string[]>;
    await this.bootstrap();
    const fallback = domains[this.digit ?? ""]?.find((item) => /^https?:\/\//i.test(item));
    if (!fallback) throw new Error("player referer not found");
    this.playerReferer = `${new URL(fallback).origin}/`;
    return this.playerReferer;
  }

  async resolveCslConfig(): Promise<{
    salt: string;
    maxRetryTimes: number;
    minFetchTimeout: number;
  }> {
    const config = await this.loadSiteConfig();
    const raw = JSON.parse(config["common:cdnSmartLink"] ?? "{}") as {
      auth?: { salt?: string };
      maxRetryTimes?: number;
      minFetchTimeout?: number;
    };
    return {
      salt: raw.auth?.salt ?? "00",
      maxRetryTimes: raw.maxRetryTimes ?? 2,
      minFetchTimeout: raw.minFetchTimeout ?? 3.2,
    };
  }

  async fetchUserGeo(): Promise<UserGeo> {
    await this.bootstrap();
    return parseUserGeo(Buffer.from(await this.get(PATH.userInfo)));
  }

  private async loadSignatures(matchId: string | number, sportType: number): Promise<void> {
    await this.bootstrap();
    const cacheKey = signatureCacheKey(matchId, sportType);
    if (this.signatureCacheKey === cacheKey && this.signatureKeys.size) return;

    this.signatureKeys = await getOrFetchSignatures(matchId, sportType, async () => {
      const query = new URLSearchParams({
        stream: "true",
        sportType: String(sportType),
        matchId: String(matchId),
        // iOS sends cachePriority — helps upstream serve a cached BS body under load.
        cachePriority: "true",
      });
      for (const code of SIGNATURE_CODES) query.append("code", String(code));
      const { message, payload } = parseApiEnvelope(
        Buffer.from(await this.get(`${PATH.signatures}?${query}`)),
      );
      if (message !== "Success") {
        throw new Error(`signature bootstrap failed: ${message || "empty message"}`);
      }
      const keys = new Map(
        payload
          .flatMap((chunk) => parseSignatureEntries(chunk))
          .map((entry) => [entry.code, entry.value] as const),
      );
      if (!keys.size) throw new Error("signature bootstrap failed: no signature entries");
      return keys;
    });
    this.signatureCacheKey = cacheKey;
  }

  async fetchLiveMatches(sportType: number, language = 0): Promise<LiveMatch[]> {
    const run = async (): Promise<LiveMatch[]> => {
      await this.loadSignatures(0, sportType);
      const params: RequestParams = { language, sportType, stream: true };
      const matches = parseLiveMatchList(
        Buffer.from(await this.signedGet(PATH.live, params, SIGNATURE.live)),
      );
      // Flags / country labels for list chips (same enrichment as match detail).
      return matches.map((match) => ({
        ...match,
        streams: match.streams.map((s) =>
          enrichStreamCountry(
            {
              id: s.id,
              name: s.name,
              fullName: s.fullName,
              ...(s.streamId ? { streamId: s.streamId } : {}),
              ...(s.siteType !== undefined ? { siteType: s.siteType } : {}),
              country: s.country ?? "",
            },
            match.region ?? "",
          ),
        ),
      }));
    };
    try {
      return await run();
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      // Soft failures (empty upstream message / rate limit / stale session) — retry like iOS clearSession.
      this.clearAuthState(msg);
      if (ApiClient.isRetryableMessage(msg)) {
        await new Promise((r) => setTimeout(r, 400 + Math.floor(Math.random() * 600)));
        try {
          return await run();
        } catch {
          await new Promise((r) => setTimeout(r, 800));
          return await run();
        }
      }
      clearSiteBootstrap();
      this.dataApiBaseUrl = null;
      this.digit = null;
      this.context = null;
      await this.bootstrap(true);
      return await run();
    }
  }

  private mapDetailResult(parsed: {
    match?: Omit<LiveMatch, "streams">;
    stream: StreamItem[];
  }): { match?: LiveMatch; stream: StreamItem[] } {
    return {
      ...(parsed.match
        ? {
            match: {
              ...parsed.match,
              hasStreams: parsed.stream.length > 0 || parsed.match.hasStreams,
              streams: parsed.stream.map((s, i) =>
                enrichStreamCountry(
                  {
                    id: s.streamId ?? `s-${i}`,
                    name: (s.name ?? s.fullName ?? `Stream ${s.streamId ?? i}`).replace(/^\$+/, "").trim(),
                    fullName: (s.fullName ?? "").replace(/^\$+/, "").trim(),
                    ...(s.streamId ? { streamId: s.streamId } : {}),
                    ...(s.siteType !== undefined ? { siteType: s.siteType } : {}),
                    country: s.country ?? "",
                  },
                  parsed.match?.region ?? "",
                ),
              ),
            },
          }
        : {}),
      stream: parsed.stream,
    };
  }

  async fetchMatchDetail(
    matchId: string,
    sportType: number,
    language = 0,
  ): Promise<{ match?: LiveMatch; stream: StreamItem[] }> {
    const run = async (): Promise<{ match?: LiveMatch; stream: StreamItem[] }> => {
      await this.loadSignatures(matchId, sportType);
      const params: RequestParams = { matchId, sportType, language, stream: true };
      const buffer = Buffer.from(await this.signedGet(PATH.matchDetail, params, SIGNATURE.detail));
      const envelope = parseApiEnvelope(buffer);
      if (envelope.message !== "Success") {
        throw new Error(`match detail failed: ${envelope.message || "unknown"}`);
      }
      return this.mapDetailResult(parseMatchDetail(buffer));
    };

    try {
      let result = await run();
      // Upstream sometimes returns Success with an empty stream list while the match has feeds —
      // clear session/signatures and retry once (mirrors iOS cold retry after stale rb-session).
      if (result.stream.length === 0) {
        // Drop rb-session only — do not bust the shared BS cache (avoids 429 storms).
        console.warn(`[match] empty streams for ${matchId}, refreshing session`);
        this.clearSession("empty-streams");
        await new Promise((r) => setTimeout(r, 350 + Math.floor(Math.random() * 250)));
        result = await run();
      }
      return result;
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      this.clearAuthState(msg);
      await new Promise((r) => setTimeout(r, 400 + Math.floor(Math.random() * 400)));
      try {
        return await run();
      } catch {
        clearSiteBootstrap();
        this.dataApiBaseUrl = null;
        this.digit = null;
        this.context = null;
        this.clearAuthState("bootstrap");
        await this.bootstrap(true);
        return await run();
      }
    }
  }

  async fetchMatchLineup(matchId: string, sportType: number, language = 0): Promise<MatchLineup> {
    await this.loadSignatures(matchId, sportType);
    const params: RequestParams = { matchId, sportType, language };
    return parseMatchLineup(Buffer.from(await this.signedGet(PATH.matchLineup, params, SIGNATURE.detail)));
  }

  async fetchMatchEvents(matchId: string, sportType: number, language = 0): Promise<MatchEvent[]> {
    await this.loadSignatures(matchId, sportType);
    const params: RequestParams = { matchId, sportType, language };
    return parseMatchEvents(Buffer.from(await this.signedGet(PATH.matchEvent, params, SIGNATURE.detail)));
  }

  async fetchMatchStatistics(matchId: string, sportType: number, language = 0): Promise<MatchStatRow[]> {
    await this.loadSignatures(matchId, sportType);
    const params: RequestParams = { matchId, sportType, language };
    return parseMatchStatistics(
      Buffer.from(await this.signedGet(PATH.matchStatistic, params, SIGNATURE.detail)),
    );
  }

  async fetchMatchH2H(
    matchId: string,
    sportType: number,
    perspectiveHomeName = "",
    language = 0,
  ): Promise<H2HSummary> {
    await this.loadSignatures(matchId, sportType);
    const params: RequestParams = { matchId, sportType, language };
    return parseMatchAnalysis(
      Buffer.from(await this.signedGet(PATH.matchAnalysis, params, SIGNATURE.detail)),
      perspectiveHomeName,
    );
  }

  async fetchStreamDetail(input: {
    streamId: string;
    matchId: string;
    sportType: number;
    siteType: number;
    country?: string;
    continent?: string;
  }): Promise<{ stream: StreamItem; sessionToken: string }> {
    await this.bootstrap();
    if (!this.digit) throw new Error("site digit not set");
    const url = new URL(`${this.baseUrl()}${PATH.streamDetail}`);
    url.searchParams.set("streamId", input.streamId);
    url.searchParams.set("matchId", input.matchId);
    url.searchParams.set("sportType", String(input.sportType));
    url.searchParams.set("siteType", String(input.siteType));
    url.searchParams.set("digit", this.digit);
    if (input.continent) url.searchParams.set("continent", input.continent);
    if (input.country) url.searchParams.set("country", input.country);

    const attempt = async (attachSession: boolean) => {
      const response = await fetch(url, { headers: this.buildHeaders(attachSession) });
      if (ApiClient.isAuthFailure(response.status)) {
        throw new Error(`auth failed: ${response.status}`);
      }
      if (response.status === 429 || response.status === 503) {
        throw new Error(`stream detail failed: rate limited (${response.status})`);
      }
      if (!response.ok) {
        throw new Error(`stream detail failed: http ${response.status}`);
      }
      this.captureSession(response);
      const buffer = Buffer.from(await response.arrayBuffer());
      const envelope = parseApiEnvelope(buffer);
      if (envelope.message !== "Success") throw new Error(`stream detail failed: ${envelope.message}`);
      const sessionToken =
        response.headers.get("rb-session") ??
        response.headers.get("Rb-Session") ??
        this.rbSession;
      if (!sessionToken) throw new Error("stream detail missing session token");
      this.rbSession = sessionToken;
      return { stream: parseStreamDetail(buffer), sessionToken };
    };

    try {
      return await attempt(true);
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      if (!this.rbSession || !/auth failed/i.test(msg)) throw error;
      this.clearSession("stream-detail");
      return await attempt(false);
    }
  }

  private async get(path: string): Promise<ArrayBuffer> {
    try {
      return await this.performGet(path, true);
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      if (!this.rbSession || !/auth failed/i.test(msg)) throw error;
      this.clearSession("get");
      return await this.performGet(path, false);
    }
  }

  private async performGet(path: string, attachSession: boolean): Promise<ArrayBuffer> {
    const response = await fetch(`${this.baseUrl()}${path}`, {
      headers: this.buildHeaders(attachSession),
    });
    const buffer = await response.arrayBuffer();
    if (ApiClient.isAuthFailure(response.status)) {
      throw new Error(`auth failed: ${response.status}`);
    }
    if (response.status === 429 || response.status === 503) {
      throw new Error(`signature bootstrap failed: rate limited (${response.status})`);
    }
    const head = Buffer.from(buffer).subarray(0, 32).toString("utf8");
    if (head.includes("<!DOCTYPE") || head.includes("Just a moment")) {
      throw new Error("signature bootstrap failed: cloudflare challenge");
    }
    if (!response.ok) {
      throw new Error(`signature bootstrap failed: http ${response.status}`);
    }
    this.captureSession(response);
    return buffer;
  }

  private async signedGet(path: string, params: RequestParams, code: number): Promise<ArrayBuffer> {
    try {
      return await this.performSignedGet(path, params, code, true);
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      if (!this.rbSession || !/auth failed/i.test(msg)) throw error;
      this.clearSession("signedGet");
      return await this.performSignedGet(path, params, code, false);
    }
  }

  private async performSignedGet(
    path: string,
    params: RequestParams,
    code: number,
    attachSession: boolean,
  ): Promise<ArrayBuffer> {
    const suffix = this.signatureKeys.get(code);
    if (!suffix) throw new Error(`missing body signature for ${path}`);
    const query = new URLSearchParams();
    for (const [key, value] of Object.entries(sortRequestParams(params))) {
      query.set(key, String(value));
    }
    const url = `${this.baseUrl()}/sfver${requestHashPrefix(params)}${suffix}${path}?${query}`;
    const response = await fetch(url, { headers: this.buildHeaders(attachSession) });
    if (ApiClient.isAuthFailure(response.status)) {
      throw new Error(`auth failed: ${response.status}`);
    }
    if (response.status === 429 || response.status === 503) {
      throw new Error(`signature bootstrap failed: rate limited (${response.status})`);
    }
    if (!response.ok) {
      throw new Error(`signed get failed: http ${response.status}`);
    }
    this.captureSession(response);
    return response.arrayBuffer();
  }
}
