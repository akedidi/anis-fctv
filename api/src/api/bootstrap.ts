import {
  ENTRY_ORIGIN,
  FALLBACK_DATA_API_HOST,
  FALLBACK_DIGIT,
  USER_AGENT,
} from "../config/site.js";

type SiteBootstrap = {
  digit: string;
  dataApiBaseUrl: string;
  entryOrigin: string;
  fetchedAt: number;
};

let cached: SiteBootstrap | null = null;

/** Re-fetch entry HTML periodically — digit / apis-data host rotate. */
const BOOTSTRAP_TTL_MS = 10 * 60 * 1000;

export function clearSiteBootstrap(): void {
  cached = null;
}

function fallbackBootstrap(): SiteBootstrap {
  console.warn(
    `[bootstrap] using fallback digit=${FALLBACK_DIGIT} host=${FALLBACK_DATA_API_HOST}`,
  );
  return {
    digit: FALLBACK_DIGIT,
    dataApiBaseUrl: `https://${FALLBACK_DATA_API_HOST}`,
    entryOrigin: ENTRY_ORIGIN,
    fetchedAt: Date.now(),
  };
}

export async function loadSiteBootstrap(force = false): Promise<SiteBootstrap> {
  if (!force && cached && Date.now() - cached.fetchedAt < BOOTSTRAP_TTL_MS) {
    return cached;
  }
  try {
    const response = await fetch(`${ENTRY_ORIGIN}/`, {
      headers: {
        "User-Agent": USER_AGENT,
        Accept: "text/html",
        Referer: `${ENTRY_ORIGIN}/`,
        Origin: ENTRY_ORIGIN,
      },
      cache: "no-store",
    });
    if (!response.ok) {
      cached = fallbackBootstrap();
      return cached;
    }
    const html = await response.text();
    const match = html.match(
      /"([a-z]+)","(?:\\u002F|\/)",true,"production","https:\\u002F\\u002F(apis-data\d+\.[^"]+)"/,
    );
    if (!match?.[1] || !match[2]) {
      cached = fallbackBootstrap();
      return cached;
    }
    cached = {
      digit: match[1],
      dataApiBaseUrl: `https://${match[2].replace(/\\u002F/g, "/")}`,
      entryOrigin: ENTRY_ORIGIN,
      fetchedAt: Date.now(),
    };
    return cached;
  } catch (error) {
    console.warn("[bootstrap] entry fetch failed", error);
    cached = fallbackBootstrap();
    return cached;
  }
}
