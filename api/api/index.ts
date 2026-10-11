import type { VercelRequest, VercelResponse } from "@vercel/node";
import { handleRequest } from "../src/router.js";

/** Vercel catch-all entry — rewrite all /api/* here via vercel.json */
export default async function handler(req: VercelRequest, res: VercelResponse) {
  const host = req.headers.host ?? "localhost";
  const proto = (req.headers["x-forwarded-proto"] as string) ?? "https";
  const url = new URL(req.url ?? "/", `${proto}://${host}`);
  const headers = new Headers();
  for (const [key, value] of Object.entries(req.headers)) {
    if (typeof value === "string") headers.set(key, value);
    else if (Array.isArray(value)) headers.set(key, value.join(","));
  }
  const request = new Request(url, { method: req.method, headers });
  const response = await handleRequest(request);
  res.status(response.status);
  response.headers.forEach((value, key) => res.setHeader(key, value));
  const buf = Buffer.from(await response.arrayBuffer());
  res.send(buf);
}
