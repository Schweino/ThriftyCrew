import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";

const DEFINITIONS = {
  aldi: {
    id: "aldi-real-chrome", version: "3.3.4", module: "aldi-v2.mjs",
    capabilities: ["canary", "discovery", "verification", "taxonomy", "visible-price", "offer-provenance"],
    rate: { maxConcurrent: 1, minimumDelayMs: 5_000, maxTermsPerLegacyChunk: 3 },
  },
  fareway: {
    id: "fareway-real-chrome", version: "3.3.4", module: "fareway-v2.mjs",
    capabilities: ["canary", "discovery", "verification", "taxonomy", "visible-price", "product-detail", "offer-provenance"],
    rate: { maxConcurrent: 1, minimumDelayMs: 2_000, maxTermsPerLegacyChunk: 4 },
  },
  sams: {
    id: "sams-next-data-real-chrome", version: "3.3.4", module: "next-data-v2.mjs",
    capabilities: ["canary", "discovery", "verification", "taxonomy", "dual-price", "structured-identity", "offer-provenance"],
    rate: { maxConcurrent: 1, minimumDelayMs: 3_000, maxTermsPerLegacyChunk: 3 },
  },
  walmart: {
    id: "walmart-next-data-real-chrome", version: "3.3.4", module: "next-data-v2.mjs",
    capabilities: ["canary", "discovery", "verification", "taxonomy", "dual-price", "structured-identity", "offer-provenance"],
    rate: { maxConcurrent: 1, minimumDelayMs: 1_500, maxTermsPerLegacyChunk: 5 },
  },
};

const SHARED_RUNTIME = [
  "browser-store-fanout.mjs",
  "lane-policy.mjs",
  "adapter-protocol.mjs",
  "capture-journal.mjs",
  "../capture-controller-client.mjs",
  "../capture-journal.mjs",
  "../../apps/operator/src/capture-session.ts",
  "../../packages/contracts/src/index.ts",
  "../../packages/domain/src/index.ts",
  "../../packages/engine/src/index.ts",
];

export async function captureAdapterManifest(store) {
  const definition = DEFINITIONS[store];
  if (!definition) throw new Error(`unsupported browser capture adapter: ${store}`);
  const runtimeFiles = [definition.module, ...SHARED_RUNTIME];
  const bodies = await Promise.all(runtimeFiles.map(async (file) => ({ file, body: await readFile(new URL(file, import.meta.url)) })));
  const hash = createHash("sha256");
  for (const { file, body } of bodies) hash.update(`${file}\0`).update(body).update("\0");
  const sha256 = hash.digest("hex");
  return { ...definition, store, sha256 };
}

export async function captureAdapterRegistry() {
  return Object.fromEntries(await Promise.all(Object.keys(DEFINITIONS).map(async (store) => [store, await captureAdapterManifest(store)])));
}

export function validateCaptureAdapterManifest(manifest) {
  if (!manifest || !/^3\.(?:0\.[1-3]|1\.[01]|2\.[0-2]|3\.[0-4])$/.test(manifest.version) || !/^[a-f0-9]{64}$/.test(manifest.sha256)) throw new Error("browser adapter manifest is invalid");
  for (const capability of ["canary", "discovery", "verification", "taxonomy"] ) {
    if (!manifest.capabilities.includes(capability)) throw new Error(`${manifest.store} adapter lacks ${capability}`);
  }
  if (manifest.rate.maxConcurrent !== 1 || manifest.rate.minimumDelayMs < 1_000) throw new Error(`${manifest.store} adapter rate policy is unsafe`);
  return manifest;
}
