import { proxyHls } from "../proxy/hls.js";
import { listLiveMatches } from "../handlers/live.js";
import { resolveMatch } from "../handlers/match.js";
import { serveClient } from "./static.js";

export async function handleRequest(request: Request): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname === "/api/hls") return proxyHls(request);
  if (url.pathname === "/api/live") return listLiveMatches(url.searchParams.get("sportType"));
  if (url.pathname === "/api/resolve") {
    return resolveMatch(
      url.searchParams.get("matchId"),
      url.searchParams.get("sportType"),
      url.origin,
      url.searchParams.get("streamId"),
    );
  }
  if (url.pathname.startsWith("/api/")) return Response.json({ error: "not found" }, { status: 404 });
  return serveClient(url.pathname);
}
