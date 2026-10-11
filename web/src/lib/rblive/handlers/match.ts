import { ApiClient } from "../api/client";
import { buildSignedStreamUrl } from "../crypto/stream-token";
import { buildProxyUrl, type ProxyContext } from "../proxy/hls";

export async function resolveMatch(
  matchIdRaw: string | null,
  sportTypeRaw: string | null,
  origin: string,
  streamIdRaw: string | null = null,
): Promise<Response> {
  if (!matchIdRaw || !sportTypeRaw) {
    return Response.json({ error: "matchId and sportType required" }, { status: 400 });
  }
  const matchId = matchIdRaw.trim();
  const sportType = Number(sportTypeRaw);
  if (!/^\d+$/.test(matchId) || !Number.isFinite(sportType)) {
    return Response.json({ error: "invalid matchId or sportType" }, { status: 400 });
  }
  const wantedStreamId = streamIdRaw?.trim() || "";
  try {
    const client = new ApiClient();
    const [geo, match, playerReferer, csl] = await Promise.all([
      client.fetchUserGeo(),
      client.fetchMatchDetail(matchId, sportType),
      client.resolvePlayerReferer(),
      client.resolveCslConfig(),
    ]);
    const stream =
      (wantedStreamId
        ? match.stream.find((item) => String(item.streamId ?? "") === wantedStreamId)
        : undefined) ?? match.stream.find((item) => item.streamId);
    if (!stream?.streamId) throw new Error("no stream on match");
    if (stream.siteType == null) throw new Error("stream missing site type");
    const detail = await client.fetchStreamDetail({
      streamId: stream.streamId,
      matchId,
      sportType,
      siteType: stream.siteType,
      ...(geo.country ? { country: geo.country } : {}),
      ...(geo.continent ? { continent: geo.continent } : {}),
    });
    if (!detail.stream.url) throw new Error("stream detail missing url");
    const streamUrl = buildSignedStreamUrl(detail.stream.url, detail.sessionToken);
    const proxyContext: ProxyContext = {
      referer: playerReferer,
      ...(geo.country ? { country: geo.country } : {}),
      ...(geo.continent ? { continent: geo.continent } : {}),
      salt: csl.salt,
      maxRetryTimes: String(csl.maxRetryTimes),
      minFetchTimeout: String(csl.minFetchTimeout),
    };
    return Response.json({
      name: stream.name ?? stream.fullName ?? "",
      matchId,
      sportType,
      streamUrl,
      referer: playerReferer,
      playableUrl: buildProxyUrl(streamUrl, proxyContext, origin),
      streams: match.stream,
      match: match.match,
    });
  } catch (error) {
    return Response.json(
      { error: error instanceof Error ? error.message : "resolve failed" },
      { status: 502 },
    );
  }
}

export async function getMatchDetail(
  matchIdRaw: string | null,
  sportTypeRaw: string | null,
  languageRaw: string | null,
): Promise<Response> {
  if (!matchIdRaw || !sportTypeRaw) {
    return Response.json({ error: "matchId and sportType required" }, { status: 400 });
  }
  const matchId = matchIdRaw.trim();
  const sportType = Number(sportTypeRaw);
  const language = Number(languageRaw ?? 0);
  if (!/^\d+$/.test(matchId) || !Number.isFinite(sportType)) {
    return Response.json({ error: "invalid matchId or sportType" }, { status: 400 });
  }
  try {
    const detail = await new ApiClient().fetchMatchDetail(matchId, sportType, language);
    return Response.json({
      match: detail.match,
      streams: detail.stream.map((s, i) => ({
        id: s.streamId ?? `s-${i}`,
        name: s.name ?? s.fullName ?? `Stream ${s.streamId ?? i}`,
        fullName: s.fullName ?? "",
        streamId: s.streamId,
        siteType: s.siteType,
        country: s.country ?? "",
      })),
    });
  } catch (error) {
    return Response.json(
      { error: error instanceof Error ? error.message : "match detail failed" },
      { status: 502 },
    );
  }
}

export async function getMatchLineup(
  matchIdRaw: string | null,
  sportTypeRaw: string | null,
  languageRaw: string | null,
): Promise<Response> {
  if (!matchIdRaw || !sportTypeRaw) {
    return Response.json({ error: "matchId and sportType required" }, { status: 400 });
  }
  try {
    const lineup = await new ApiClient().fetchMatchLineup(
      matchIdRaw.trim(),
      Number(sportTypeRaw),
      Number(languageRaw ?? 0),
    );
    return Response.json({ lineup });
  } catch (error) {
    return Response.json(
      { error: error instanceof Error ? error.message : "lineup failed" },
      { status: 502 },
    );
  }
}

export async function getMatchEvents(
  matchIdRaw: string | null,
  sportTypeRaw: string | null,
  languageRaw: string | null,
): Promise<Response> {
  if (!matchIdRaw || !sportTypeRaw) {
    return Response.json({ error: "matchId and sportType required" }, { status: 400 });
  }
  try {
    const events = await new ApiClient().fetchMatchEvents(
      matchIdRaw.trim(),
      Number(sportTypeRaw),
      Number(languageRaw ?? 0),
    );
    return Response.json({ events });
  } catch (error) {
    return Response.json(
      { error: error instanceof Error ? error.message : "events failed" },
      { status: 502 },
    );
  }
}
