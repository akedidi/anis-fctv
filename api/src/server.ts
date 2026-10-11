import { createServer } from "node:http";
import { handleRequest } from "./router.js";

const port = Number(process.env.PORT ?? 3000);

createServer(async (req, res) => {
  try {
    const host = req.headers.host ?? `localhost:${port}`;
    const url = new URL(req.url ?? "/", `http://${host}`);
    const request = new Request(url, {
      method: req.method,
      headers: req.headers as HeadersInit,
    });
    const response = await handleRequest(request);
    res.statusCode = response.status;
    response.headers.forEach((value, key) => res.setHeader(key, value));
    const buf = Buffer.from(await response.arrayBuffer());
    res.end(buf);
  } catch (error) {
    res.statusCode = 500;
    res.setHeader("Content-Type", "application/json");
    res.end(JSON.stringify({ error: error instanceof Error ? error.message : "server error" }));
  }
}).listen(port, () => {
  console.log(`[fctv33-api] http://localhost:${port}`);
});
