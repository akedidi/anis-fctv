import type { UserGeo } from "./protobuf.js";

/** Continent codes matching iOS `RbliveGeoParameters`. */
export function continentForCountry(cc: string): string {
  const c = cc.toUpperCase();
  const europe = new Set([
    "AD", "AL", "AT", "AX", "BA", "BE", "BG", "BY", "CH", "CY", "CZ", "DE", "DK", "EE", "ES", "FI",
    "FO", "FR", "GB", "GG", "GI", "GR", "HR", "HU", "IE", "IM", "IS", "IT", "JE", "LI", "LT", "LU",
    "LV", "MC", "MD", "ME", "MK", "MT", "NL", "NO", "PL", "PT", "RO", "RS", "RU", "SE", "SI", "SJ",
    "SK", "SM", "UA", "VA", "XK",
  ]);
  if (europe.has(c)) return "EU";
  const asia = new Set([
    "AE", "AF", "AM", "AZ", "BD", "BH", "BN", "BT", "CC", "CN", "CX", "GE", "HK", "ID", "IL", "IN",
    "IO", "IQ", "IR", "JO", "JP", "KG", "KH", "KP", "KR", "KW", "KZ", "LA", "LB", "LK", "MM", "MN",
    "MO", "MV", "MY", "NP", "OM", "PH", "PK", "PS", "QA", "SA", "SG", "SY", "TH", "TJ", "TL", "TM",
    "TR", "TW", "UZ", "VN", "YE",
  ]);
  if (asia.has(c)) return "AS";
  const africa = new Set([
    "AO", "BF", "BI", "BJ", "BW", "CD", "CF", "CG", "CI", "CM", "CV", "DJ", "DZ", "EG", "EH", "ER",
    "ET", "GA", "GH", "GM", "GN", "GQ", "GW", "KE", "KM", "LR", "LS", "LY", "MA", "MG", "ML", "MR",
    "MU", "MW", "MZ", "NA", "NE", "NG", "RE", "RW", "SC", "SD", "SH", "SL", "SN", "SO", "SS", "ST",
    "SZ", "TD", "TG", "TN", "TZ", "UG", "YT", "ZA", "ZM", "ZW",
  ]);
  if (africa.has(c)) return "AF";
  const oceania = new Set([
    "AS", "AU", "CK", "FJ", "FM", "GU", "KI", "MH", "MP", "NC", "NF", "NR", "NU", "NZ", "PF", "PG",
    "PN", "PW", "SB", "TK", "TO", "TV", "UM", "VU", "WF", "WS",
  ]);
  if (oceania.has(c)) return "OC";
  const southAmerica = new Set([
    "AR", "BO", "BR", "CL", "CO", "EC", "FK", "GF", "GY", "PE", "PY", "SR", "UY", "VE",
  ]);
  if (southAmerica.has(c)) return "SA";
  const northAmerica = new Set([
    "AG", "AI", "AW", "BB", "BM", "BQ", "BS", "BZ", "CA", "CR", "CU", "CW", "DM", "DO", "GD", "GL",
    "GP", "GT", "HN", "HT", "JM", "KN", "KY", "LC", "MF", "MQ", "MS", "MX", "NI", "PA", "PM", "PR",
    "SV", "SX", "TC", "TT", "US", "VC", "VG", "VI",
  ]);
  if (northAmerica.has(c)) return "NA";
  return "EU";
}

/** Prefer client locale geo (like iOS) over upstream `/api/user/info` (server IP). */
export function pickStreamGeo(
  countryRaw: string | null | undefined,
  continentRaw: string | null | undefined,
  fallback: UserGeo,
): UserGeo {
  const country = countryRaw?.trim().toUpperCase();
  if (country && /^[A-Z]{2}$/.test(country)) {
    const continent =
      continentRaw?.trim().toUpperCase() || continentForCountry(country);
    return { country, continent };
  }
  return fallback;
}
