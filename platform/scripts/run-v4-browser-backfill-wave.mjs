import { readFile } from "node:fs/promises";
import path from "node:path";
import { MutationClient } from "@thriftycrew/daily/client";
import { buildBrowserBackfillWavePlan, closeCompletedBrowserBackfillSessions, executeBrowserBackfillWave, heartbeatBrowserBackfillWave,
  validateBrowserBackfillWaveArtifacts } from "../apps/operator/src/browser-backfill-wave.ts";

const [command, inputFile] = process.argv.slice(2);
if (!inputFile || !new Set(["plan", "claim", "heartbeat", "close-completed", "verify-artifacts"]).has(command)) {
  throw new Error("usage: tsx scripts/run-v4-browser-backfill-wave.mjs plan|claim|heartbeat|close-completed|verify-artifacts <config-or-manifest.json>");
}
const input = JSON.parse(await readFile(path.resolve(inputFile), "utf8"));

function client() {
  if (!process.env.TC_LOCAL_MUTATION_SECRET) throw new Error("claim and heartbeat require TC_LOCAL_MUTATION_SECRET");
  const mutation = new MutationClient({ origin: process.env.TC_API_ORIGIN ?? "http://127.0.0.1:8787",
    agentId: process.env.TC_AGENT_ID ?? "local-operator", secret: process.env.TC_LOCAL_MUTATION_SECRET });
  return {
    claim: (body) => mutation.request("/internal/v4/backfill/claim", { json: body }),
    claimExact: (body) => mutation.request("/internal/v4/backfill/claim-exact", { json: body }),
    heartbeat: (body) => mutation.request("/internal/v4/backfill/heartbeat", { json: body }),
  };
}

let result;
if (command === "plan") result = buildBrowserBackfillWavePlan(input);
else if (command === "claim") result = await executeBrowserBackfillWave(input, client());
else if (command === "heartbeat") result = await heartbeatBrowserBackfillWave(input, client());
else if (command === "close-completed") result = await closeCompletedBrowserBackfillSessions(input, client());
else result = await validateBrowserBackfillWaveArtifacts(input);
process.stdout.write(`${JSON.stringify({ ok: true, command, result }, null, 2)}\n`);
