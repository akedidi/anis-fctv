/** Country / region helpers for stream rows — mirrors iOS `CountryHelper`. */

const ACCEPTED = new Set([
  "FR", "DE", "ES", "IT", "PT", "NL", "PL", "SE", "NO", "DK", "FI",
  "GB", "US", "CA", "BR", "AR", "MX", "AU", "NZ", "JP", "KR", "CN",
  "IN", "SA", "AE", "QA", "TR", "RU", "UA", "BE", "CH", "AT", "IE", "ZA",
  "PY", "BD", "PK", "LK", "JM", "GR", "CZ", "RO", "HU", "HR",
  "CL", "CO", "PE", "UY", "EC", "VE", "BO", "CR", "PA", "GT",
  "DZ", "MA", "TN", "EG", "NG", "GH", "SN", "CI", "KE", "CM",
  "TH", "VN", "ID", "PH", "MY", "SG", "TW", "HK", "KH", "LA", "MM",
  "IL", "IQ", "IR", "KW", "BH", "OM", "JO", "LB", "SY",
  "BG", "RS", "SI", "SK", "LT", "LV", "EE", "AL", "MK", "BA",
  "NZ", "FJ",
]);

const REGION_TO_CODE: Record<string, string> = {
  england: "GB",
  "united kingdom": "GB",
  uk: "GB",
  "great britain": "GB",
  scotland: "GB",
  wales: "GB",
  france: "FR",
  spain: "ES",
  germany: "DE",
  italy: "IT",
  portugal: "PT",
  netherlands: "NL",
  holland: "NL",
  belgium: "BE",
  switzerland: "CH",
  austria: "AT",
  ireland: "IE",
  usa: "US",
  "united states": "US",
  america: "US",
  brazil: "BR",
  argentina: "AR",
  mexico: "MX",
  chile: "CL",
  colombia: "CO",
  japan: "JP",
  korea: "KR",
  china: "CN",
  australia: "AU",
  "new zealand": "NZ",
  turkey: "TR",
  "saudi arabia": "SA",
  uae: "AE",
  qatar: "QA",
  europe: "EU",
  asia: "AS",
  africa: "AF",
  paraguay: "PY",
  "l'europe": "EU",
  europeen: "EU",
  européen: "EU",
  "south africa": "ZA",
  bangladesh: "BD",
  india: "IN",
  pakistan: "PK",
  "sri lanka": "LK",
  "west indies": "JM",
  greece: "GR",
  czech: "CZ",
  czechia: "CZ",
  romania: "RO",
  hungary: "HU",
  croatia: "HR",
  algeria: "DZ",
  morocco: "MA",
  tunisia: "TN",
  egypt: "EG",
  thailand: "TH",
  vietnam: "VN",
  indonesia: "ID",
  philippines: "PH",
  malaysia: "MY",
  singapore: "SG",
};

const BRAND_MAP: [string, string][] = [
  ["bein sports fr", "FR"],
  ["bein sport fr", "FR"],
  ["canal+", "FR"],
  ["canal +", "FR"],
  ["tf1", "FR"],
  ["m6", "FR"],
  ["rmc sport", "FR"],
  ["eurosport fr", "FR"],
  ["sky sport de", "DE"],
  ["dazn de", "DE"],
  ["sky uk", "GB"],
  ["bt sport", "GB"],
  ["tnt sports", "GB"],
  ["espn", "US"],
  ["fox sports", "US"],
  ["pam us", "US"],
  ["fubo", "US"],
  ["raisport", "IT"],
  ["sky italia", "IT"],
  ["dazn it", "IT"],
  ["now it", "IT"],
  ["movistar", "ES"],
  ["dazn es", "ES"],
  ["sport tv", "PT"],
  ["viaplay", "SE"],
  ["polsat", "PL"],
  ["eleven sports pl", "PL"],
  ["ssc", "SA"],
  ["abu dhabi", "AE"],
  ["td en", "GB"],
  ["td uk", "GB"],
  ["tnt cl", "CL"],
  ["dz fr", "DZ"],
  ["dz es", "DZ"],
  ["dz pt", "PT"],
  ["ai en", "GB"],
  ["ai th", "TH"],
  ["tv vn", "VN"],
];

const NAME_FOR: Record<string, string> = {
  FR: "France",
  DE: "Germany",
  ES: "Spain",
  IT: "Italy",
  PT: "Portugal",
  NL: "Netherlands",
  PL: "Poland",
  SE: "Sweden",
  NO: "Norway",
  DK: "Denmark",
  FI: "Finland",
  GB: "United Kingdom",
  US: "United States",
  CA: "Canada",
  BR: "Brazil",
  AR: "Argentina",
  MX: "Mexico",
  CL: "Chile",
  CO: "Colombia",
  PE: "Peru",
  UY: "Uruguay",
  SA: "Saudi Arabia",
  AE: "United Arab Emirates",
  QA: "Qatar",
  TR: "Turkey",
  DZ: "Algeria",
  MA: "Morocco",
  TN: "Tunisia",
  EG: "Egypt",
  AU: "Australia",
  JP: "Japan",
  KR: "Korea",
  CN: "China",
  IN: "India",
  TH: "Thailand",
  VN: "Vietnam",
  ID: "Indonesia",
  PH: "Philippines",
  MY: "Malaysia",
  SG: "Singapore",
  TW: "Taiwan",
  HK: "Hong Kong",
  BE: "Belgium",
  CH: "Switzerland",
  AT: "Austria",
  IE: "Ireland",
  ZA: "South Africa",
  PY: "Paraguay",
  RU: "Russia",
  UA: "Ukraine",
  GR: "Greece",
  CZ: "Czechia",
  RO: "Romania",
  HU: "Hungary",
  HR: "Croatia",
  BG: "Bulgaria",
  IL: "Israel",
};

const BANNED = new Set(["HD", "SD", "UHD", "LQ", "HQ", "OK", "TV", "FC", "AI", "NOW", "TYR"]);

function normalizeCode(raw: string): string {
  const u = raw.toUpperCase();
  if (u === "UK" || u === "EN") return "GB";
  return u;
}

function trailingISOCode(streamName: string): string | undefined {
  const trimmed = streamName.trim();
  if (!trimmed) return undefined;
  const patterns = [/\b([A-Za-z]{2})$/, /[-_/]([A-Za-z]{2})$/];
  for (const p of patterns) {
    const m = trimmed.match(p);
    if (!m?.[1]) continue;
    const normalized = normalizeCode(m[1]);
    if (BANNED.has(normalized)) continue;
    if (ACCEPTED.has(normalized)) return normalized;
  }
  return undefined;
}

export type CountryHint = { label: string; code?: string };

export function inferCountry(streamName: string, matchRegion = ""): CountryHint {
  const blob = `${streamName} ${matchRegion}`.trim();
  if (!blob) return { label: "" };
  const lower = blob.toLowerCase();

  const trailing = trailingISOCode(streamName);
  if (trailing) {
    return { label: NAME_FOR[trailing] ?? trailing, code: trailing };
  }

  for (const [needle, code] of BRAND_MAP) {
    if (lower.includes(needle)) {
      const normalized = normalizeCode(code);
      return { label: NAME_FOR[normalized] ?? normalized, code: normalized };
    }
  }

  for (const p of [/\(([A-Za-z]{2})\)/, /\[([A-Za-z]{2})\]/]) {
    const m = blob.match(p);
    if (!m?.[1]) continue;
    const normalized = normalizeCode(m[1]);
    if (ACCEPTED.has(normalized)) {
      return { label: NAME_FOR[normalized] ?? normalized, code: normalized };
    }
  }

  const region = matchRegion.trim();
  if (region) {
    const code = REGION_TO_CODE[region.toLowerCase()];
    if (code) {
      if (code === "EU" || code === "AS" || code === "AF") return { label: region };
      return { label: NAME_FOR[code] ?? region, code };
    }
    return { label: region };
  }

  return { label: "" };
}

export function flagCDNURL(code: string, width = 40): string | undefined {
  const c = code.toLowerCase();
  if (c.length !== 2 || c === "eu" || c === "as" || c === "af") return undefined;
  return `https://flagcdn.com/w${width}/${c}.png`;
}

/** Enrich a stream row with inferred country label / ISO code / flagcdn URL. */
export function enrichStreamCountry<T extends { name?: string; fullName?: string; country?: string }>(
  stream: T,
  matchRegion = "",
): T & { country: string; countryCode?: string; flagURL?: string } {
  const label = `${stream.name ?? ""} ${stream.fullName ?? ""}`.trim();
  const hint = inferCountry(label, matchRegion);
  const country = (stream.country && stream.country.trim()) || hint.label || "";
  const countryCode = hint.code;
  const flagURL = countryCode ? flagCDNURL(countryCode) : undefined;
  return {
    ...stream,
    country,
    ...(countryCode ? { countryCode } : {}),
    ...(flagURL ? { flagURL } : {}),
  };
}
