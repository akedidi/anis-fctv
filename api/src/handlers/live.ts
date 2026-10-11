import { loadSiteBootstrap } from "../api/bootstrap.js";
import { ApiClient } from "../api/client.js";
import type { LiveMatch } from "../api/protobuf.js";

/** Primary sports first so "All" fills quickly; annex sports follow. */
const SCHEDULE_SPORTS = [1, 2, 3, 90, 7, 9, 8, 4, 6, 11, 13, 14, 15, 16, 5, 10, 12];

/** One client per sport — sharing a single ApiClient across Promise.all races signatures. */
async function fetchSport(sportType: number, language: number): Promise<LiveMatch[]> {
  const client = new ApiClient();
  try {
    return await client.fetchLiveMatches(sportType, language);
  } catch (error) {
    console.warn(`[live] sportType=${sportType} failed:`, error instanceof Error ? error.message : error);
    return [];
  }
}

/** Bound fan-out so Cloudflare does not 429 the signature endpoint. */
async function mapPool<T, R>(items: T[], concurrency: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  async function worker(): Promise<void> {
    while (next < items.length) {
      const i = next++;
      results[i] = await fn(items[i]!);
      await new Promise((r) => setTimeout(r, 120));
    }
  }
  const n = Math.min(concurrency, items.length);
  await Promise.all(Array.from({ length: n }, () => worker()));
  return results;
}

export async function listLiveMatches(
  sportTypeRaw: string | null,
  languageRaw: string | null = null,
): Promise<Response> {
  const sportType = Number(sportTypeRaw ?? 0);
  const language = Number(languageRaw ?? 0);
  if (!Number.isFinite(sportType) || !Number.isFinite(language)) {
    return Response.json({ error: "invalid sportType or language" }, { status: 400 });
  }
  try {
    // Warm digit/host once before fan-out.
    await loadSiteBootstrap();
    let matches: LiveMatch[];
    if (sportType === 0) {
      const batches = await mapPool(SCHEDULE_SPORTS, 2, (st) => fetchSport(st, language));
      const byId = new Map<number, LiveMatch>();
      for (const batch of batches) {
        for (const match of batch) {
          const prev = byId.get(match.matchId);
          if (!prev || match.streams.length > prev.streams.length) byId.set(match.matchId, match);
        }
      }
      matches = Array.from(byId.values());
    } else {
      matches = await new ApiClient().fetchLiveMatches(sportType, language);
    }
    matches.sort((a, b) => {
      const aLive = a.statusCode > 0 && a.statusCode < 10_000 ? 1 : 0;
      const bLive = b.statusCode > 0 && b.statusCode < 10_000 ? 1 : 0;
      if (aLive !== bLive) return bLive - aLive;
      if (a.hot !== b.hot) return Number(b.hot) - Number(a.hot);
      return a.startDate - b.startDate;
    });
    return Response.json({ sportType, language, matches });
  } catch (error) {
    return Response.json(
      { error: error instanceof Error ? error.message : "live list failed" },
      { status: 502 },
    );
  }
}
