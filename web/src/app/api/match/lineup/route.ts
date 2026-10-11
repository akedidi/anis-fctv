import { getMatchLineup } from "@/lib/rblive/handlers/match";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const url = new URL(request.url);
  return getMatchLineup(
    url.searchParams.get("matchId"),
    url.searchParams.get("sportType"),
    url.searchParams.get("language"),
  );
}
