import { readdir, readFile, writeFile } from "node:fs/promises";

const root = new URL(".", import.meta.url);
const files = (await readdir(root)).filter((name) => name.endsWith("-prefilter.json"));
const documents = await Promise.all(files.map(async (name) => JSON.parse(await readFile(new URL(name, root), "utf8"))));
const context = JSON.parse(await readFile(new URL("catalog-context.json", root), "utf8"));

const stop = new Set("a an and are as at baked best chicken cook cooked cooking creamy easy for from healthy homemade how in instant keto low carb lowcarb make of on one pan pot recipe skillet slow style the to with without".split(" "));
const tokens = (value) => new Set(String(value).toLowerCase().replace(/&amp;/g, " and ").replace(/[^a-z0-9]+/g, " ").trim().split(/\s+/).filter((token) => token.length > 1 && !stop.has(token)));
const similarity = (left, right) => {
  if (!left.size || !right.size) return 0;
  let intersection = 0;
  for (const token of left) if (right.has(token)) intersection++;
  return Math.max(intersection / left.size, intersection / right.size, intersection / (left.size + right.size - intersection));
};

const catalog = context.catalog.map((item) => ({ ...item, titleTokens: tokens(item.slug) }));
const ingredientStop = new Set("about approximately chopped diced divided finely fresh heaping large medium minced more optional packed peeled plus roughly sliced small taste thinly to or and as needed ounce ounces oz pound pounds lb lbs gram grams kilogram kilograms kg cup cups tablespoon tablespoons tbsp teaspoon teaspoons tsp clove cloves can cans package packages pinch dash sprig sprigs bunch bunches head heads stalk stalks piece pieces".split(" "));
const formTokens = new Set("black white red green yellow hot sweet smoked ground powdered powder dried frozen canned boneless skinless bone thigh thighs breast breasts whole".split(" "));
const singular = (token) => token.endsWith("ies") ? `${token.slice(0, -3)}y` : token.endsWith("s") && !token.endsWith("ss") ? token.slice(0, -1) : token;
const conceptTokens = (value) => new Set(String(value).toLowerCase().replace(/[^a-z]+/g, " ").trim().split(/\s+/).map(singular).filter((token) => token.length > 1 && !ingredientStop.has(token)));
const commodities = context.commodities.map((line) => {
  const [id, label] = String(line).split(" | ");
  return { id, label, tokens: conceptTokens(`${id.replaceAll("-", " ")} ${label}`) };
});
const ingredientMatch = (line) => {
  if (/\bwater\b/i.test(line) || /\b(?:salt|pepper)\b.*\bto taste\b/i.test(line)) return { score: 1, commodityId: null, ignored: true };
  const ingredient = conceptTokens(line);
  let best = { score: 0, commodityId: null };
  for (const commodity of commodities) {
    const requiredForms = [...ingredient].filter((token) => formTokens.has(token));
    if (requiredForms.some((token) => !commodity.tokens.has(token))) continue;
    let intersection = 0;
    for (const token of ingredient) if (commodity.tokens.has(token)) intersection++;
    const score = intersection / Math.max(1, Math.min(ingredient.size, commodity.tokens.size));
    if (score > best.score) best = { score, commodityId: commodity.id };
  }
  return best;
};
const sidePattern = /\b(broccoli|cauliflower|cabbage|zucchini|squash|asparagus|green beans|brussels sprouts|spinach|kale|collard|eggplant|bell pepper|mushroom|radish|turnip|rutabaga|celery|cucumber|lettuce|salad greens|bok choy|chard|artichoke|fennel|okra|tomato|avocado)\b/i;
const numeric = (text) => {
  const normalized = text.replaceAll("½", " 1/2").replaceAll("¼", " 1/4").replaceAll("¾", " 3/4").replaceAll("⅓", " 1/3").replaceAll("⅔", " 2/3");
  const match = normalized.match(/^\s*(\d+(?:\.\d+)?)?(?:\s+)?(?:(\d+)\/(\d+))?/);
  if (!match) return 0;
  return Number(match[1] ?? 0) + (match[2] && match[3] ? Number(match[2]) / Number(match[3]) : 0);
};
const sideGrams = (line) => {
  if (!sidePattern.test(line)) return 0;
  const amount = numeric(line);
  if (!amount) return 0;
  if (/\b(?:kilograms?|kg)\b/i.test(line)) return amount * 1000;
  if (/\b(?:grams?|g)\b/i.test(line)) return amount;
  if (/\b(?:pounds?|lbs?|lb)\b/i.test(line)) return amount * 453.592;
  if (/\b(?:ounces?|oz)\b/i.test(line)) return amount * 28.3495;
  if (/\bcups?\b/i.test(line)) return amount * 100;
  return 0;
};
const yieldCount = (value) => {
  const text = Array.isArray(value) ? value.join(" ") : String(value ?? "");
  return Number(text.match(/[\d.]+/)?.[0] ?? 0);
};
const seen = new Set();
const ranked = [];
for (const document of documents) {
  for (const recipe of document.recipes ?? []) {
    if (seen.has(recipe.url)) continue;
    seen.add(recipe.url);
    const titleTokens = tokens(recipe.title);
    let nearest = null;
    for (const item of catalog) {
      const score = similarity(titleTokens, item.titleTokens);
      if (!nearest || score > nearest.score) nearest = { slug: item.slug, score, commodityIds: item.commodityIds };
    }
    const ingredientMatches = (recipe.ingredients ?? []).map((line) => ({ line, ...ingredientMatch(line) }));
    const compatibilityScore = ingredientMatches.length
      ? ingredientMatches.filter((match) => match.score >= 0.75).length / ingredientMatches.length
      : 0;
    const servings = yieldCount(recipe.yield);
    const accompanimentGramsPerServing = servings > 0
      ? (recipe.ingredients ?? []).reduce((sum, line) => sum + sideGrams(line), 0) / servings
      : 0;
    ranked.push({
      ...recipe,
      nearestCatalog: nearest,
      noveltyScore: Number((1 - (nearest?.score ?? 0)).toFixed(3)),
      compatibilityScore: Number(compatibilityScore.toFixed(3)),
      accompanimentGramsPerServingEstimate: Number(accompanimentGramsPerServing.toFixed(1)),
      likelyCompleteMeal: accompanimentGramsPerServing >= 70,
      unmatchedIngredients: ingredientMatches.filter((match) => match.score < 0.75),
    });
  }
}

ranked.sort((left, right) => Number(right.likelyCompleteMeal) - Number(left.likelyCompleteMeal)
  || right.compatibilityScore - left.compatibilityScore
  || right.noveltyScore - left.noveltyScore
  || left.title.localeCompare(right.title));
const likelyNovel = ranked.filter((item) => (item.nearestCatalog?.score ?? 0) < 0.67 && item.likelyCompleteMeal && item.compatibilityScore >= 0.8);
await writeFile(new URL("ranked-leads.json", root), JSON.stringify({ total: ranked.length, likelyNovel: likelyNovel.length, recipes: ranked }, null, 2));
await writeFile(new URL("likely-novel-leads.json", root), JSON.stringify({ total: likelyNovel.length, recipes: likelyNovel }, null, 2));
process.stdout.write(JSON.stringify({ files: files.length, total: ranked.length, likelyNovel: likelyNovel.length }));
