import { createHash } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";

interface Commodity { id: string; include?: string[]; exclude?: string[] }
interface KnownWrong { entries?: Array<{ reversed_on?: string; reversed_by?: string; names?: string[] }> }

const CONFIG_FILES = ["commodities.json", "categories.json", "known-wrong.json"] as const;

function sha256(bytes: Uint8Array): string {
  return createHash("sha256").update(bytes).digest("hex");
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
  for (const name of CONFIG_FILES) {
    const source = new Uint8Array(await readFile(path.join(configRoot, name)));
    const destination = path.join(legacyRoot, name);
    const current = await readFile(destination).catch(() => undefined);
    hashes[name] = sha256(source);
    if (!current || !source.every((byte, index) => current[index] === byte) || current.length !== source.length) {
      changed.push(name);
      if (!checkOnly) await atomicWrite(destination, source);
    }
  }
  const commodities = JSON.parse(await readFile(path.join(configRoot, "commodities.json"), "utf8")) as Commodity[];
  const knownWrong = JSON.parse(await readFile(path.join(configRoot, "known-wrong.json"), "utf8")) as KnownWrong;
  const uniqueRules = new Set<string>();
  for (const commodity of commodities) {
    for (const value of commodity.include ?? []) uniqueRules.add(`${commodity.id}\u001finclude\u001f${value}`);
    for (const value of commodity.exclude ?? []) uniqueRules.add(`${commodity.id}\u001fexclude\u001f${value}`);
  }
  const activeKnownWrong = (knownWrong.entries ?? []).filter((entry) => !(entry.reversed_on && entry.reversed_by));
  const manifest = {
    schema: 1,
    authority: "platform/config",
    outputs: CONFIG_FILES.map((name) => `grocery/${name}`),
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
  const manifestChanged = !currentManifest || !manifestBytes.every((byte, index) => currentManifest[index] === byte) || currentManifest.length !== manifestBytes.length;
  if (manifestChanged && !checkOnly) await atomicWrite(manifestFile, manifestBytes);
  if (checkOnly && (changed.length > 0 || manifestChanged)) {
    throw new Error(`generated configuration is stale: ${[...changed, ...(manifestChanged ? ["manifest.json"] : [])].join(", ")}`);
  }
  return { ok: true, checkOnly, changed, manifestChanged, manifest };
}
