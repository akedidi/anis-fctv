import { handleRequest } from "./router.js";

/**
 * Cloudflare Workers entry — same `/api/*` surface as the Node/Vercel server.
 * Requires `nodejs_compat` (Buffer + node:crypto for stream tokens / CSL).
 */
export default {
  async fetch(request: Request): Promise<Response> {
    try {
      return await handleRequest(request);
    } catch (error) {
      return Response.json(
        { error: error instanceof Error ? error.message : "worker error" },
        {
          status: 500,
          headers: {
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-store",
          },
        },
      );
    }
  },
};
