import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { captureHeadlessDiscovery } from "../apps/operator/src/headless-targeted-capture.ts";

const [mode, store, outputFile] = process.argv.slice(2);
if (!mode || !store || !outputFile || !["headless", "browser"].includes(mode)) {
  throw new Error("usage: tsx scripts/run-v4-backfill-store-batch.mjs <headless|browser> <store> <output.json>");
}
const chunks = [];
for await (const chunk of process.stdin) chunks.push(chunk);
const claim = JSON.parse(Buffer.concat(chunks).toString("utf8"));
const workItems = Array.isArray(claim.workItems) ? claim.workItems : [];
if (workItems.length === 0) throw new Error("backfill claim contained no work items");
const inputs = workItems.map((row) => JSON.parse(String(row.input_json ?? "{}")));
const terms = [...new Set(inputs.flatMap((row) => Array.isArray(row.queryTerms) ? row.queryTerms : []).map(String).map((term) => term.trim()).filter(Boolean))];
if (terms.length === 0 || terms.length > 50) throw new Error("backfill store batch requires 1-50 unique terms");
await mkdir(path.dirname(path.resolve(outputFile)), { recursive: true });
if (mode === "browser") {
  const artifact = { kind: "catalog-backfill-browser-claim-v4", store, claimedAt: new Date().toISOString(), terms, workItems };
  await writeFile(outputFile, `${JSON.stringify(artifact, null, 2)}\n`, "utf8");
  process.stdout.write(`${JSON.stringify({ ok: true, mode, store, workItems: workItems.length, terms: terms.length, outputFile })}\n`);
} else {
  if (!new Set(["bakers", "family-fare", "hy-vee"]).has(store)) throw new Error("unsupported headless backfill store");
  const artifact = await captureHeadlessDiscovery(store, terms, outputFile);
  process.stdout.write(`${JSON.stringify({ ok: true, mode, store, workItems: workItems.length, terms: terms.length,
    capturedRows: artifact.rows?.length ?? 0, observedAt: artifact.canary.observedAt, outputFile })}\n`);
}
