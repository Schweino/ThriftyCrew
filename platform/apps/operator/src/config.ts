import { createHash } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";
import { z } from "zod";

interface Commodity { id: string; include?: string[]; exclude?: string[] }
interface KnownWrong { entries?: Array<{ reversed_on?: string; reversed_by?: string; names?: string[] }> }

export const omahaStorePolicySchema = z.object({
  version: z.literal(2),
  marketId: z.literal("omaha"),
  timezone: z.literal("America/Chicago"),
  stores: z.array(z.object({
    storeLocationId: z.enum(OMAHA_GROCERY_STORE_LOCATION_IDS),
    storeName: z.string().trim().min(2),
    sourceId: z.string().trim().min(3),
    firstPartyHost: z.string().trim().min(3),
    plane: z.enum(["browser", "headless"]),
    priceMode: z.enum(["pickup", "in_store", "club"]),
    retailerLocationKey: z.string().trim().min(1),
    priceLocationKey: z.string().trim().min(1),
    adLocationKey: z.string().trim().min(1).nullable(),
    exactAddress: z.string().trim().min(10),
    locationCanary: z.object({
      expectedLocationPattern: z.string().trim().min(3),
      expectedModePattern: z.string().trim().min(3),
    }).strict(),
    minimumIntervalMs: z.number().int().nonnegative(),
    sameStoreConcurrency: z.literal(1),
    evidenceFreshnessMinutes: z.number().int().min(5).max(1440),
    requireDualPriceAgreement: z.boolean(),
    membershipRequired: z.boolean(),
    notFoundRequiresTargetedCoverage: z.literal(true),
    exhaustiveSearchRequired: z.literal(true),
    adCalendarBinding: z.enum(["source_native_or_store_calendar", "none"]),
  }).strict()).length(OMAHA_GROCERY_STORE_LOCATION_IDS.length),
}).strict().superRefine((value, context) => {
  const actual = value.stores.map((store) => store.storeLocationId).sort();
  const expected = [...OMAHA_GROCERY_STORE_LOCATION_IDS].sort();
  if (new Set(actual).size !== actual.length || JSON.stringify(actual) !== JSON.stringify(expected)) {
    context.addIssue({ code: "custom", path: ["stores"], message: "store policies must contain each authoritative Omaha store exactly once" });
  }
  for (const store of value.stores) {
    try { new RegExp(store.locationCanary.expectedLocationPattern, "i"); new RegExp(store.locationCanary.expectedModePattern, "i"); }
    catch { context.addIssue({ code: "custom", path: ["stores", store.storeLocationId, "locationCanary"], message: "canary patterns must compile" }); }
  }
});

const LEGACY_OUTPUTS = ["commodities.json", "categories.json", "known-wrong.json", "recipe-commodities.json"] as const;
const AUTHORITY_FILES = [...LEGACY_OUTPUTS, "recipe-commodity-aliases.json", "recipe-commodity-extensions.json", "omaha-store-policies.json"] as const;

function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
}

function canonicalJsonHash(bytes: Uint8Array): string {
  const normalized = new TextDecoder().decode(bytes).replace(/\r\n/g, "\n");
  return sha256(new TextEncoder().encode(normalized));
}

async function atomicWrite(file: string, bytes: Uint8Array): Promise<void> {
  await mkdir(path.dirname(file), { recursive: true });
  const temporary = `${file}.tmp-${process.pid}`;
  await writeFile(temporary, bytes);
  try {
    await rename(temporary, file);
  } finally {
    await rm(temporary, { force: true });
  }
}

export async function generateLegacyConfiguration(incomeRoot: string, checkOnly: boolean): Promise<Record<string, unknown>> {
  const configRoot = path.join(incomeRoot, "platform", "config");
  const legacyRoot = path.join(incomeRoot, "grocery");
  const changed: string[] = [];
  const hashes: Record<string, string> = {};
  for (const name of AUTHORITY_FILES) {
    const source = new Uint8Array(await readFile(path.join(configRoot, name)));
    // Git may check text files out with CRLF on Windows and LF on Linux. The
    // manifest is an authority hash, so it must describe JSON content rather
    // than a workstation's line-ending policy.
    hashes[name] = canonicalJsonHash(source);
    if ((LEGACY_OUTPUTS as readonly string[]).includes(name)) {
      const destination = path.join(legacyRoot, name);
      const current = await readFile(destination).catch(() => undefined);
      if (!current || !source.every((byte, index) => current[index] === byte) || current.length !== source.length) {
        changed.push(name);
        if (!checkOnly) await atomicWrite(destination, source);
      }
    }
  }
  const commodities = JSON.parse(await readFile(path.join(configRoot, "commodities.json"), "utf8")) as Commodity[];
  const knownWrong = JSON.parse(await readFile(path.join(configRoot, "known-wrong.json"), "utf8")) as KnownWrong;
  omahaStorePolicySchema.parse(JSON.parse(await readFile(path.join(configRoot, "omaha-store-policies.json"), "utf8")));
  const uniqueRules = new Set<string>();
  for (const commodity of commodities) {
    for (const value of commodity.include ?? []) uniqueRules.add(`${commodity.id}\u001finclude\u001f${value}`);
    for (const value of commodity.exclude ?? []) uniqueRules.add(`${commodity.id}\u001fexclude\u001f${value}`);
  }
  const activeKnownWrong = (knownWrong.entries ?? []).filter((entry) => !(entry.reversed_on && entry.reversed_by));
  const manifest = {
    schema: 1,
    authority: "platform/config",
    outputs: LEGACY_OUTPUTS.map((name) => `grocery/${name}`),
    hashes,
    counts: {
      commodities: commodities.length,
      uniqueMatchRules: uniqueRules.size,
      knownWrongRulings: activeKnownWrong.length,
      expandedKnownWrongNames: activeKnownWrong.reduce((count, entry) => count + (entry.names?.length ?? 0), 0),
    },
  };
  const manifestBytes = new TextEncoder().encode(`${JSON.stringify(manifest, null, 2)}\n`);
  const manifestFile = path.join(configRoot, "manifest.json");
  const currentManifest = await readFile(manifestFile).catch(() => undefined);
  const manifestChanged = !currentManifest || canonicalJsonHash(currentManifest) !== canonicalJsonHash(manifestBytes);
  if (manifestChanged && !checkOnly) await atomicWrite(manifestFile, manifestBytes);
  if (checkOnly && (changed.length > 0 || manifestChanged)) {
    throw new Error(`generated configuration is stale: ${[...changed, ...(manifestChanged ? ["manifest.json"] : [])].join(", ")}`);
  }
  return { ok: true, checkOnly, changed, manifestChanged, manifest };
}
