import { ApiClient } from "../api/client.js";
import type { LiveMatch } from "../api/protobuf.js";

const SCHEDULE_SPORTS = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 90];

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
    const client = new ApiClient();
    let matches: LiveMatch[];
    if (sportType === 0) {
      const batches = await Promise.all(
        SCHEDULE_SPORTS.map(async (st) => {
          try {
            return await client.fetchLiveMatches(st, language);
          } catch {
            return [] as LiveMatch[];
          }
        }),
      );
      const byId = new Map<number, LiveMatch>();
      for (const batch of batches) {
        for (const match of batch) {
          const prev = byId.get(match.matchId);
          if (!prev || match.streams.length > prev.streams.length) byId.set(match.matchId, match);
        }
      }
      matches = Array.from(byId.values());
    } else {
      matches = await client.fetchLiveMatches(sportType, language);
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
