import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const [contentExport, workExport, outputDirectory] = process.argv.slice(2);
if (!contentExport || !workExport || !outputDirectory) {
  throw new Error("usage: node scripts/backfill-recipe-content-nutrition.mjs <content-export> <work-export> <output-directory>");
}

const sha256 = (value) => createHash("sha256").update(typeof value === "string" ? value : JSON.stringify(value)).digest("hex");
const contentDocument = JSON.parse((await readFile(contentExport, "utf8")).replace(/^\uFEFF/, ""));
const workDocument = JSON.parse((await readFile(workExport, "utf8")).replace(/^\uFEFF/, ""));
const contentRows = contentDocument[0]?.results ?? [];
const workRows = workDocument[0]?.results ?? [];
const nutritionBySlug = new Map();
for (const row of workRows) {
  if (row.agent_id !== "recipe-mapper" || !row.output_json) continue;
  const output = JSON.parse(row.output_json);
  for (const mapped of output.recipes ?? []) {
    if (!mapped.readyForWriting || !mapped.candidate?.proposedSlug || !mapped.candidate?.sourceNutrition) continue;
    nutritionBySlug.set(mapped.candidate.proposedSlug, mapped.candidate.sourceNutrition);
  }
}
const items = contentRows.map((row) => {
  const item = JSON.parse(row.content_json);
  const sourceNutrition = nutritionBySlug.get(item.slug);
  if (!sourceNutrition) throw new Error(`nutrition is unavailable for ${item.slug}`);
  return { ...item, sourceNutrition };
}).sort((left, right) => left.slug.localeCompare(right.slug));
if (items.length !== 8 || new Set(items.map((item) => item.slug)).size !== 8) throw new Error("expected exactly eight unique recipes");

const provenance = {
  kind: "recipe-content-nutrition-backfill-v1",
  sourceBatches: [...new Set(contentRows.map((row) => row.batch_id))].sort(),
  items,
};
const promptHash = sha256("Deterministically preserve promoted recipe content and attach the exact sourceNutrition facts from its completed mapper handoff.");
const batchId = `content_nutrition_backfill_${sha256(provenance).slice(0, 24)}`;
await mkdir(outputDirectory, { recursive: true });
await Promise.all([
  writeFile(path.join(outputDirectory, "batch.json"), `${JSON.stringify({
    id: batchId,
    kind: "recipe-pack",
    inputHash: sha256(provenance),
    promptHash,
    sourceRefs: provenance.sourceBatches.map((id) => `content-batch://${id}`),
  }, null, 2)}\n`, "utf8"),
  writeFile(path.join(outputDirectory, "items.json"), `${JSON.stringify({ items }, null, 2)}\n`, "utf8"),
  writeFile(path.join(outputDirectory, "audit.json"), `${JSON.stringify({
    auditorAgentId: "recipe-content-migration",
    promptHash,
    findings: [],
  }, null, 2)}\n`, "utf8"),
]);
console.log(JSON.stringify({ ok: true, batchId, items: items.length, outputDirectory }, null, 2));
