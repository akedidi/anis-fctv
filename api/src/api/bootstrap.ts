import { ENTRY_ORIGIN, USER_AGENT } from "../config/site.js";

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

export async function loadSiteBootstrap(force = false): Promise<SiteBootstrap> {
  if (!force && cached && Date.now() - cached.fetchedAt < BOOTSTRAP_TTL_MS) {
    return cached;
  }
  const response = await fetch(`${ENTRY_ORIGIN}/`, {
    headers: {
      "User-Agent": USER_AGENT,
      Accept: "text/html",
      Referer: `${ENTRY_ORIGIN}/`,
      Origin: ENTRY_ORIGIN,
    },
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`entry page ${response.status}`);
  const html = await response.text();
  const match = html.match(
    /"([a-z]+)","(?:\\u002F|\/)",true,"production","https:\\u002F\\u002F(apis-data\d+\.[^"]+)"/,
  );
  if (!match?.[1] || !match[2]) {
    clearSiteBootstrap();
    throw new Error("entry bootstrap not found");
  }
  cached = {
    digit: match[1],
    dataApiBaseUrl: `https://${match[2].replace(/\\u002F/g, "/")}`,
    entryOrigin: ENTRY_ORIGIN,
    fetchedAt: Date.now(),
  };
  return cached;
}
