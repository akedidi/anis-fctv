import { ApiClient } from "./dist/api/client.js";
import { parseApiEnvelope, parseMatchDetail } from "./dist/api/protobuf.js";

function readVarint(buffer, offset) {
  let result = 0, shift = 0, pos = offset;
  while (pos < buffer.length) {
    const b = buffer[pos++];
    result |= (b & 0x7f) << shift;
    if ((b & 0x80) === 0) break;
    shift += 7;
  }
  return [result, pos];
}
function readFields(buffer) {
  const fields = new Map();
  let offset = 0;
  while (offset < buffer.length) {
    const [tag, next] = readVarint(buffer, offset);
    offset = next;
    const field = tag >>> 3;
    const wire = tag & 7;
    if (wire === 0) {
      const [, n] = readVarint(buffer, offset); offset = n;
      // skip storing varints unless needed
    } else if (wire === 2) {
      const [len, n] = readVarint(buffer, offset);
      offset = n;
      const chunk = buffer.subarray(offset, offset + len);
      offset += len;
      if (!fields.has(field)) fields.set(field, []);
      fields.get(field).push(Buffer.from(chunk));
    } else if (wire === 1) { offset += 8; }
    else if (wire === 5) { offset += 4; }
    else break;
  }
  return fields;
}

const client = new ApiClient();
const matches = await client.fetchLiveMatches(1);
console.log("live sample", matches.slice(0,3));
const mid = String(matches[0].matchId);
const st = matches[0].sportType;
const detail = await client.fetchMatchDetail(mid, st);
console.log("streams", detail.stream?.map(s => ({id:s.streamId, name:s.name, site:s.siteType})));

await client.loadSignatures(mid, st);
const buf = Buffer.from(await client.signedGet("/api/match/detail", { matchId: mid, sportType: st, language: 0, stream: true }, 102));
const env = parseApiEnvelope(buf);
const root = env.payload[0];
const fields = readFields(root);
console.log("root fields", [...fields.keys()]);
for (const matchChunk of fields.get(1) || []) {
  const mf = readFields(matchChunk);
  console.log("match fields", [...mf.keys()]);
  for (const f of [10, 11]) {
    for (const chunk of mf.get(f) || []) {
      const inner = readFields(chunk);
      console.log("=== field", f, "keys", [...inner.keys()]);
      for (const [k, vals] of inner) {
        for (const v of vals) {
          const asStr = v.toString("utf8");
          const printable = asStr.length < 200 && !/[\x00-\x08]/.test(asStr);
          console.log("  sub", k, "len", v.length, printable ? JSON.stringify(asStr) : v.slice(0,32).toString("hex"));
        }
      }
    }
  }
}
// Also dump live list match blob field 10 from live endpoint
const liveBuf = Buffer.from(await client.signedGet("/api/live/match", { language: 0, sportType: 1, stream: true }, /* need correct path */ 0)).catch?.(()=>null);
