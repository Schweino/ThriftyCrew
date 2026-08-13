import { writeFile } from "node:fs/promises";

const [siteName, sitemapIndex] = process.argv.slice(2);
if (!siteName || !sitemapIndex) throw new Error("usage: node discover-site.mjs <site-name> <sitemap-index-url>");
const root = new URL(".", import.meta.url);

const fetchText = async (url) => {
  const response = await fetch(url, {
    headers: { "user-agent": "ThriftyCrew recipe research/1.0 (+https://www.thriftycrew.com)" },
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`${response.status} ${url}`);
  return response.text();
};

const recipeNodes = (value, found = [], seen = new Set()) => {
  if (!value || typeof value !== "object" || seen.has(value)) return found;
  seen.add(value);
  if (Array.isArray(value)) {
    for (const child of value) recipeNodes(child, found, seen);
    return found;
  }
  const types = Array.isArray(value["@type"]) ? value["@type"] : [value["@type"]];
  if (types.includes("Recipe")) found.push(value);
  for (const child of Object.values(value)) recipeNodes(child, found, seen);
  return found;
};

const number = (value) => {
  const match = String(Array.isArray(value) ? value[0] : value ?? "").replaceAll(",", "").match(/[\d.]+/);
  return match ? Number(match[0]) : null;
};

const excluded = /\b(salmon|shrimp|prawn|tuna|cod|tilapia|halibut|trout|sardine|anchov|mackerel|crab|lobster|scallop|clam|mussel|oyster|seafood|fish|ground chicken)\b/i;
const nonDinner = /\b(cake|cookie|brownie|cheesecake|pudding|muffin|bread|biscuit|donut|doughnut|smoothie|shake|cocktail|lemonade|ice cream|fat bomb|snack|dip|dressing|sauce|condiment|jam|candy|pancake|waffle|porridge|oatmeal)\b/i;
const accompaniment = /\b(broccoli|cauliflower|cabbage|zucchini|squash|asparagus|green beans|brussels sprouts|spinach|kale|collard|eggplant|pepper|mushroom|radish|turnip|rutabaga|celery|cucumber|lettuce|salad|slaw|bok choy|chard|artichoke|fennel|okra|tomato|avocado|vegetable|veggies)\b/i;

const indexXml = await fetchText(sitemapIndex);
const xmlLocations = [...indexXml.matchAll(/<loc>(.*?)<\/loc>/g)].map((match) => match[1]);
const htmlLocations = [...indexXml.matchAll(/href=["'](https?:\/\/[^"']+)["']/gi)].map((match) => match[1].replaceAll("&amp;", "&"));
const indexLocations = xmlLocations.length > 0 ? xmlLocations : [...new Set(htmlLocations)];
const sitemapUrls = indexLocations.filter((url) => /(?:post|recipe)-sitemap\d*\.xml(?:$|\?)/.test(url));
const nestedSitemaps = sitemapUrls.length > 0 ? sitemapUrls : indexLocations.filter((url) => /\.xml(?:$|\?)/.test(url) || /sitemap\.xml\?/i.test(url));
const urls = nestedSitemaps.length > 0
  ? (await Promise.all(nestedSitemaps.map(fetchText))).flatMap((xml) => [...xml.matchAll(/<loc>(.*?)<\/loc>/g)].map((match) => match[1]))
  : indexLocations.filter((url) => !/\.xml(?:$|\?)/.test(url));
if (urls.length === 0) throw new Error(`no recipe-page URLs found in ${sitemapIndex}`);
const results = [];
const errors = [];
let cursor = 0;

async function worker() {
  for (;;) {
    const index = cursor++;
    if (index >= urls.length) return;
    const url = urls[index];
    try {
      const html = await fetchText(url);
      const blocks = [...html.matchAll(/<script[^>]+type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)];
      for (const block of blocks) {
        let document;
        try { document = JSON.parse(block[1]); } catch { continue; }
        for (const recipe of recipeNodes(document)) {
          const title = String(recipe.name ?? "").trim();
          const ingredients = Array.isArray(recipe.recipeIngredient) ? recipe.recipeIngredient.map(String) : [];
          const categories = Array.isArray(recipe.recipeCategory) ? recipe.recipeCategory.map(String) : [String(recipe.recipeCategory ?? "")];
          const nutrition = recipe.nutrition ?? {};
          const calories = number(nutrition.calories);
          const listedCarbs = number(nutrition.carbohydrateContent);
          const searchable = [title, recipe.description, ...categories, ...ingredients].join(" ");
          if (calories === null || calories < 500 || calories > 650) continue;
          if (listedCarbs === null || listedCarbs > 35) continue;
          if (excluded.test(searchable) || nonDinner.test(searchable)) continue;
          if (!accompaniment.test(searchable)) continue;
          results.push({
            source: siteName,
            url,
            title,
            calories,
            listedCarbs,
            carbohydrateCaveat: "JSON-LD carbohydrate value is a discovery filter only; the registered sourcer must verify total carbs and its serving basis on the public page.",
            yield: recipe.recipeYield ?? null,
            categories,
            cuisine: recipe.recipeCuisine ?? null,
            ingredients,
            description: recipe.description ?? null,
          });
        }
      }
    } catch (error) {
      errors.push({ url, error: error instanceof Error ? error.message : String(error) });
    }
    if ((index + 1) % 100 === 0) process.stderr.write(`${siteName}: checked ${index + 1}/${urls.length}; matches ${results.length}\n`);
  }
}

await Promise.all(Array.from({ length: 6 }, () => worker()));
const unique = [...new Map(results.map((item) => [item.url, item])).values()]
  .sort((left, right) => left.title.localeCompare(right.title));
await writeFile(new URL(`${siteName}-prefilter.json`, root), JSON.stringify({ siteName, checked: urls.length, matches: unique.length, errors, recipes: unique }, null, 2));
process.stdout.write(JSON.stringify({ siteName, checked: urls.length, matches: unique.length, errors: errors.length }));
