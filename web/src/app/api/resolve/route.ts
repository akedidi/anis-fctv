import { resolveMatch } from "@/lib/rblive/handlers/match";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const url = new URL(request.url);
  return resolveMatch(
    url.searchParams.get("matchId"),
    url.searchParams.get("sportType"),
    url.origin,
    url.searchParams.get("streamId"),
  );
}
