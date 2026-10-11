import { proxyHls } from "./proxy/hls.js";
import { listLiveMatches } from "./handlers/live.js";
import {
  getMatchDetail,
  getMatchEvents,
  getMatchLineup,
  resolveMatch,
} from "./handlers/match.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "*",
} as const;

function withCors(response: Response): Response {
  const headers = new Headers(response.headers);
  for (const [k, v] of Object.entries(CORS)) headers.set(k, v);
  return new Response(response.body, { status: response.status, headers });
}

export async function handleRequest(request: Request): Promise<Response> {
  if (request.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS });
  }

  const url = new URL(request.url);
  let response: Response;

  if (url.pathname === "/api/hls") response = await proxyHls(request);
  else if (url.pathname === "/api/live") {
    response = await listLiveMatches(url.searchParams.get("sportType"), url.searchParams.get("language"));
  } else if (url.pathname === "/api/resolve") {
    response = await resolveMatch(
      url.searchParams.get("matchId"),
      url.searchParams.get("sportType"),
      url.origin,
      url.searchParams.get("streamId"),
    );
  } else if (url.pathname === "/api/match") {
    response = await getMatchDetail(
      url.searchParams.get("matchId"),
      url.searchParams.get("sportType"),
      url.searchParams.get("language"),
    );
  } else if (url.pathname === "/api/match/lineup") {
    response = await getMatchLineup(
      url.searchParams.get("matchId"),
      url.searchParams.get("sportType"),
      url.searchParams.get("language"),
    );
  } else if (url.pathname === "/api/match/events") {
    response = await getMatchEvents(
      url.searchParams.get("matchId"),
      url.searchParams.get("sportType"),
      url.searchParams.get("language"),
    );
  } else if (url.pathname === "/api/health") {
    response = Response.json({ ok: true, service: "fctv33-api" });
  } else {
    response = Response.json({ error: "not found" }, { status: 404 });
  }

  return withCors(response);
}
