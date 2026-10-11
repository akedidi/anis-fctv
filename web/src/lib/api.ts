/** Cloudflare Workers API — Vercel `web` project only hosts the UI. */
export const API_BASE = (
  process.env.NEXT_PUBLIC_API_BASE || "https://fctv33-api.kedidi-anis.workers.dev"
).replace(/\/$/, "");

export function apiUrl(pathAndQuery: string): string {
  const path = pathAndQuery.startsWith("/") ? pathAndQuery : `/${pathAndQuery}`;
  return `${API_BASE}${path}`;
}
