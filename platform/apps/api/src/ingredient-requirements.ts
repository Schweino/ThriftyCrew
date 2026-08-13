import { normalizeName } from "@thriftycrew/domain";

export type ShoppingRequirement = {
  sourceLine: string;
  splitComponentIndex: number;
  displayName: string;
  normalizedName: string;
  role: "purchased" | "process" | "alternative";
};

const processWater = /^(?:\d+(?:[./]\d+)?\s*(?:cups?|tablespoons?|tbsp|teaspoons?|tsp|fl\s*oz|ounces?|oz|ml|liters?|l)\s+)?(?:hot |cold |boiling )?water(?:\s+as needed)?$/i;
const indivisibleProducts = new Set([
  "half and half", "half-and-half", "macaroni and cheese", "sweet and sour sauce", "salt and vinegar seasoning",
]);

function stripQuantity(value: string): string {
  return value.replace(/^\s*(?:\d+(?:\s+\d+\/\d+|[./]\d+)?|one|two|three|four|five|six|seven|eight|nine|ten)\s*(?:cups?|tablespoons?|tbsp|teaspoons?|tsp|pounds?|lbs?|ounces?|oz|grams?|g|kilograms?|kg|milliliters?|ml|liters?|l|cans?|jars?|packages?|pkg|bunches?|cloves?|sticks?)?\s*/i, "").trim();
}

export function extractShoppingRequirements(sourceLine: string): ShoppingRequirement[] {
  const raw = sourceLine.trim();
  const withoutQuantity = stripQuantity(raw).replace(/,\s*(?:divided|optional|to taste|for serving).*$/i, "").trim();
  if (processWater.test(raw) || processWater.test(withoutQuantity)) {
    return [{ sourceLine: raw, splitComponentIndex: 0, displayName: "water", normalizedName: "water", role: "process" }];
  }
  const normalizedWhole = normalizeName(withoutQuantity);
  if (/\s+or\s+/i.test(withoutQuantity)) {
    return [{ sourceLine: raw, splitComponentIndex: 0, displayName: withoutQuantity, normalizedName: normalizedWhole, role: "alternative" }];
  }
  const parts = indivisibleProducts.has(normalizedWhole) ? [withoutQuantity] : withoutQuantity.split(/\s+and\s+/i).map((part) => part.trim()).filter(Boolean);
  return parts.map((displayName, splitComponentIndex) => ({
    sourceLine: raw,
    splitComponentIndex,
    displayName,
    normalizedName: normalizeName(displayName),
    role: "purchased" as const,
  })).filter((item) => item.normalizedName.length > 0);
}

export function expectedUnitDimension(sourceLine: string): "mass" | "volume" | "count" | "variable" {
  if (/\b(?:pounds?|lbs?|ounces?|oz|grams?|g|kilograms?|kg)\b/i.test(sourceLine)) return "mass";
  if (/\b(?:cups?|tablespoons?|tbsp|teaspoons?|tsp|fl\s*oz|milliliters?|ml|liters?|l)\b/i.test(sourceLine)) return "volume";
  if (/\b(?:count|ct|each|cloves?|sticks?|bunches?|cans?|jars?|packages?|pkg)\b/i.test(sourceLine)) return "count";
  return "variable";
}
