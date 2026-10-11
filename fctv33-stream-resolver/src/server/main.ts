import { createServer } from "node:http";

import { handleRequest } from "./router.js";

const port = Number(process.env.PORT ?? "3000");

createServer((incoming, outgoing) => {
  void (async () => {
    const host = incoming.headers.host ?? `localhost:${port}`;
    const headers = new Headers();
    for (const [key, value] of Object.entries(incoming.headers)) {
      if (typeof value === "string") headers.set(key, value);
      else if (Array.isArray(value)) {
        for (const item of value) headers.append(key, item);
      }
    }
    const request = new Request(`http://${host}${incoming.url ?? "/"}`, {
      method: incoming.method ?? "GET",
      headers,
    });
    const response = await handleRequest(request);
    outgoing.statusCode = response.status;
    response.headers.forEach((value, key) => outgoing.setHeader(key, value));
    outgoing.end(Buffer.from(await response.arrayBuffer()));
  })().catch((error: unknown) => {
    outgoing.statusCode = 500;
    outgoing.end(error instanceof Error ? error.message : "internal error");
  });
}).listen(port, () => {
  console.log(`http://localhost:${port}`);
});
