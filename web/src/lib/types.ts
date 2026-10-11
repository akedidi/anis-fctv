export type Contender = {
  id: string;
  name: string;
  logoURL?: string;
};

export type StreamServer = {
  id: string;
  name: string;
  fullName: string;
  streamId?: string;
  siteType?: number;
  country: string;
};

export type LiveMatch = {
  matchId: number;
  sportType: number;
  name: string;
  leagueName: string;
  leagueLogoURL?: string;
  region: string;
  contenders: Contender[];
  homeScore?: number;
  awayScore?: number;
  statusCode: number;
  startDate: number;
  liveClock?: string;
  hot: boolean;
  streams: StreamServer[];
};

export type MatchEvent = {
  id: string;
  minute?: string;
  text: string;
  kind: "goal" | "status" | "info";
};

export type LineupPlayer = {
  id: string;
  name: string;
  number?: string;
  positionLabel: string;
  positionOrder: number;
  isStarter: boolean;
};

export type SportTab = {
  type: number;
  label: string;
  icon: string;
};

export const PRIMARY_SPORTS: SportTab[] = [
  { type: 0, label: "All", icon: "▦" },
  { type: 1, label: "Football", icon: "⚽" },
  { type: 2, label: "Basketball", icon: "🏀" },
  { type: 3, label: "Tennis", icon: "🎾" },
  { type: 90, label: "Others", icon: "…" },
];

export const MORE_SPORTS: SportTab[] = [
  { type: 5, label: "Golf", icon: "⛳" },
  { type: 9, label: "Am. Football", icon: "🏈" },
  { type: 8, label: "Rugby", icon: "🏉" },
  { type: 6, label: "Cricket", icon: "🏏" },
  { type: 11, label: "Hockey", icon: "🏒" },
  { type: 4, label: "Baseball", icon: "⚾" },
  { type: 12, label: "Volleyball", icon: "🏐" },
  { type: 7, label: "Motorsport", icon: "🏍" },
  { type: 15, label: "Handball", icon: "🤾" },
  { type: 14, label: "Cycling", icon: "🚴" },
];

export function isLiveStatus(code: number): boolean {
  return code > 0 && code < 10_000;
}

export function isFinishedStatus(code: number): boolean {
  return code >= 10_000 || code === -1;
}

export function formatKickoff(ms: number): { date: string; time: string; isToday: boolean } {
  const d = new Date(ms);
  const now = new Date();
  const isToday =
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate();
  const date = d.toLocaleDateString(undefined, { day: "2-digit", month: "short" });
  const time = d.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  return { date, time, isToday };
}
