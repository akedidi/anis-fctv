/**
 * Process-wide body-signature cache.
 *
 * Every handler used to `new ApiClient()` and re-hit `/api/common/bs`, which
 * quickly 429s Cloudflare ("signature bootstrap failed"). Coalesce in-flight
 * fetches and reuse keys across match detail / events / stats / H2H.
 */

type Entry = {
  keys: Map<number, string>;
  at: number;
};

const TTL_MS = 4 * 60 * 1000;
const STALE_MS = 15 * 60 * 1000;
const MIN_GAP_MS = 280;

const byKey = new Map<string, Entry>();
const inflight = new Map<string, Promise<Map<number, string>>>();
let lastFetchAt = 0;
let chain: Promise<void> = Promise.resolve();

function sportFallbackKey(sportType: number): string {
  return `*:${sportType}`;
}

export function signatureCacheKey(matchId: string | number, sportType: number): string {
  return `${matchId}:${sportType}`;
}

export function invalidateSignatureCache(key?: string): void {
  if (key) {
    byKey.delete(key);
    // Also drop sport fallback when invalidating a concrete match.
    const sport = String(key).split(":")[1];
    if (sport) byKey.delete(`*:${sport}`);
    return;
  }
  byKey.clear();
}

function cloneKeys(keys: Map<number, string>): Map<number, string> {
  return new Map(keys);
}

function lookup(key: string, sportType: number, allowStale: boolean): Entry | null {
  const now = Date.now();
  const exact = byKey.get(key);
  if (exact && exact.keys.size) {
    if (now - exact.at < TTL_MS) return exact;
    if (allowStale && now - exact.at < STALE_MS) return exact;
  }
  const fallback = byKey.get(sportFallbackKey(sportType));
  if (fallback && fallback.keys.size) {
    if (now - fallback.at < TTL_MS) return fallback;
    if (allowStale && now - fallback.at < STALE_MS) return fallback;
  }
  return null;
}

async function throttle(): Promise<void> {
  const wait = MIN_GAP_MS - (Date.now() - lastFetchAt);
  if (wait > 0) await new Promise((r) => setTimeout(r, wait));
  lastFetchAt = Date.now();
}

/**
 * Return cached signature map, coalescing concurrent fetches for the same key.
 * On upstream failure, returns a still-fresh-or-stale entry when possible.
 */
export async function getOrFetchSignatures(
  matchId: string | number,
  sportType: number,
  fetchFn: () => Promise<Map<number, string>>,
): Promise<Map<number, string>> {
  const key = signatureCacheKey(matchId, sportType);
  const warm = lookup(key, sportType, false);
  if (warm) return cloneKeys(warm.keys);

  const existing = inflight.get(key);
  if (existing) return existing.then(cloneKeys);

  // Also coalesce under sport fallback — detail/events/stats for same sport often race.
  const sportKey = sportFallbackKey(sportType);
  const sportInflight = inflight.get(sportKey);
  if (sportInflight) return sportInflight.then(cloneKeys);

  const task = (async () => {
    // Serialize BS hits process-wide (not only per key).
    const run = chain.then(async () => {
      const again = lookup(key, sportType, false);
      if (again) return cloneKeys(again.keys);
      await throttle();
      try {
        const keys = await fetchFn();
        if (!keys.size) throw new Error("signature bootstrap failed: empty keys");
        const entry: Entry = { keys, at: Date.now() };
        byKey.set(key, entry);
        byKey.set(sportKey, entry);
        return cloneKeys(keys);
      } catch (error) {
        const stale = lookup(key, sportType, true);
        if (stale) {
          console.warn(
            `[signatures] serving stale cache for ${key} after ${
              error instanceof Error ? error.message : error
            }`,
          );
          return cloneKeys(stale.keys);
        }
        throw error;
      }
    });
    // Keep the chain alive even when a fetch fails.
    chain = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  })();

  inflight.set(key, task);
  inflight.set(sportKey, task);
  try {
    return await task;
  } finally {
    if (inflight.get(key) === task) inflight.delete(key);
    if (inflight.get(sportKey) === task) inflight.delete(sportKey);
  }
}
