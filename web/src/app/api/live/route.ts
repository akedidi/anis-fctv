import { listLiveMatches } from "@/lib/rblive/handlers/live";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request) {
  const url = new URL(request.url);
  return listLiveMatches(url.searchParams.get("sportType"), url.searchParams.get("language"));
}
