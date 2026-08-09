import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { buildCurrentBridge } from "./legacy";
import { MutationClient, replayCurrentArtifact } from "./client";

const platformRoot = path.resolve(import.meta.dirname, "../../..");
const incomeRoot = path.resolve(platformRoot, "..");
const command = process.argv[2] ?? "build";

if (command !== "build" && command !== "replay") {
  throw new Error(`unknown command ${command}`);
}

const artifact = await buildCurrentBridge(incomeRoot);
const outputDirectory = path.join(platformRoot, "tmp");
const outputFile = path.join(outputDirectory, "current-bridge.json");
await mkdir(outputDirectory, { recursive: true });
await writeFile(outputFile, `${JSON.stringify(artifact)}\n`, "utf8");
let replay: Record<string, unknown> | undefined;
if (command === "replay") {
  const secret = process.env.TC_LOCAL_MUTATION_SECRET;
  if (!secret) throw new Error("TC_LOCAL_MUTATION_SECRET is required for replay");
  replay = await replayCurrentArtifact(new MutationClient({
    origin: process.env.TC_API_ORIGIN ?? "http://127.0.0.1:8787",
    agentId: process.env.TC_AGENT_ID ?? "local-operator",
    secret,
  }), artifact);
}
console.log(JSON.stringify({ ok: true, command, outputFile, audit: artifact.audit, replay }, null, 2));
