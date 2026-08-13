import { mkdir, readFile, writeFile } from "node:fs/promises";

const root = new URL(".", import.meta.url);
const ranked = JSON.parse(await readFile(new URL("ranked-leads.json", root), "utf8"));
const attempted = new Set([
  "https://www.ruled.me/keto-fried-chicken-and-broccoli/",
  "https://www.ruled.me/15-minute-keto-lamb-asparagus-stir-fry/",
  "https://www.ruled.me/alfredo-chicken-skillet-with-mushrooms-spinach/",
  "https://www.ruled.me/cabbage-sausage-skillet/",
  "https://www.ruled.me/beanless-low-carb-chili-con-carne/",
  "https://www.ibreatheimhungry.com/keto-chicken-chorizo-sheet-pan-dinner/",
  "https://www.ibreatheimhungry.com/keto-stuffed-cabbage-instant-pot-sc/",
  "https://lowcarbyum.com/chicken-alfredo-casserole/",
  "https://lowcarbyum.com/chicken-vegetable-casserole/",
  "https://peaceloveandlowcarb.com/prosciutto-chicken-and-broccoli-sheet-pan-meal/",
  "https://peaceloveandlowcarb.com/spaghetti-squash-alfredo-with-pancetta-and-peas-low-carb-gluten-free/",
]);
const obviousNonDinner = /\b(breakfast|omelet|omelette|eggwich|quiche|muffin|pizza|bites|basket|sandwich)\b/i;
const candidates = ranked.recipes.filter((recipe) => recipe.likelyCompleteMeal
  && recipe.compatibilityScore >= 0.7
  && recipe.nearestCatalog.score < 0.67
  && !attempted.has(recipe.url)
  && !obviousNonDinner.test(recipe.title));

const bySource = new Map();
for (const recipe of candidates) {
  const source = recipe.source || "ruledme";
  if (!bySource.has(source)) bySource.set(source, []);
  bySource.get(source).push(recipe);
}
const selected = [];
while (selected.length < 100 && [...bySource.values()].some((recipes) => recipes.length)) {
  for (const recipes of bySource.values()) {
    const recipe = recipes.shift();
    if (recipe) selected.push(recipe);
    if (selected.length >= 100) break;
  }
}

const basePrompt = "Hard per-serving limits for the entire served meal: 500 to 650 calories inclusive and no more than 35 grams total carbohydrates, not net carbohydrates. Inspect every listed page directly and return every URL either as a verified candidate or with a specific rejection reason. Accept only pages with a complete quantified ingredient list, usable published yield, and published per-serving calories and total carbohydrates. Every candidate must contain a main and a substantial accompaniment in the source serving and nutrition basis; require at least 70 grams of mapped accompaniment per serving. Aromatics, garnish, sauce, broth, cooking fat, and seasoning do not count. Preserve source quantities and yield for later scaling to 14 servings. Exclude seafood, ground chicken, catalog duplicates, standalone proteins, inaccessible pages, ambiguous nutrition bases, unresolved quantity ranges, and ingredients incompatible with the supplied commodity catalog. Never estimate, substitute, or pad the count.";
const manifest = [];
for (let offset = 0; offset < selected.length; offset += 10) {
  const waveNumber = 3 + offset / 10;
  const waveLabel = String(waveNumber).padStart(2, "0");
  const recipes = selected.slice(offset, offset + 10);
  const directory = new URL(`tranche-${waveLabel}/`, root);
  await mkdir(directory, { recursive: true });
  const requestedAt = new Date(Date.UTC(2026, 7, 13, 9, 0, waveNumber, 0)).toISOString();
  const request = {
    id: `recipe_20260813T0900${waveLabel}Z_low_carb_${waveLabel}`,
    request: `Verify these ${recipes.length} externally discovered public recipe pages as potential materially distinct, budget-conscious complete low-carbohydrate dinners. Metadata prefiltering is only discovery evidence; verify all facts on the source pages: ${recipes.map((recipe) => recipe.url).join(" ; ")} . ${basePrompt}`,
    requestedAt,
    sourceRef: `codex-task://current/low-carb-150/tranche-${waveLabel}`,
  };
  const path = new URL("request.json", directory);
  await writeFile(path, JSON.stringify(request, null, 2));
  manifest.push({ wave: waveLabel, requestId: request.id, path: decodeURIComponent(path.pathname).replace(/^\/([A-Za-z]:)/, "$1"), recipes: recipes.map(({ title, url, source, calories, listedCarbs }) => ({ title, url, source: source || "ruledme", calories, listedCarbs })) });
}
await writeFile(new URL("verification-wave-manifest.json", root), JSON.stringify({ selected: selected.length, waves: manifest }, null, 2));
process.stdout.write(JSON.stringify({ eligible: candidates.length, selected: selected.length, waves: manifest.length }));
