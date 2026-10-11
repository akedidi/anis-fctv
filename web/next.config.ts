import type { NextConfig } from "next";

/** Same default as `src/lib/api.ts` — UI on Vercel, API on Cloudflare Workers. */
const WORKERS_API =
  process.env.NEXT_PUBLIC_API_BASE?.replace(/\/$/, "") ||
  "https://fctv33-api.kedidi-anis.workers.dev";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  // Fallback if a relative /api call remains — Workers serve the live API.
  async rewrites() {
    return [
      {
        source: "/api/:path*",
        destination: `${WORKERS_API}/api/:path*`,
      },
    ];
  },
};

export default nextConfig;
