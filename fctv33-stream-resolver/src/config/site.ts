export const ENTRY_ORIGIN = "https://www.fctv33.com";

export const PATH = {
  live: "/api/match/live",
  matchDetail: "/api/match/detail",
  streamDetail: "/api/stream/detail",
  params: "/api/common/params",
  signatures: "/api/common/bs",
  userInfo: "/api/user/info",
} as const;

export const SIGNATURE = {
  live: 0x64,
  detail: 0x66,
} as const;

export const SIGNATURE_CODES = [0x64, 0x65, 0x66, 0x67, 0x68, 0x69] as const;

export const REQUEST_PARAM_ORDER = [
  "matchId",
  "sportType",
  "language",
  "stream",
] as const;

export const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
