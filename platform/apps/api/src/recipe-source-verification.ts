import { digestHex, stableJson } from "@thriftycrew/domain";

function visibleText(value: string): string {
  const structuredRecipeText = [...value.matchAll(/<script\b[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi)]
    .map((match) => match[1] ?? "").join(" ");
  return `${value.replace(/<script\b[^>]*>[\s\S]*?<\/script>/gi, " ")} ${structuredRecipeText}`
    .replace(/<style\b[^>]*>[\s\S]*?<\/style>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&#x([0-9a-f]+);/gi, (_match, code: string) => String.fromCodePoint(Number.parseInt(code, 16)))
    .replace(/&#([0-9]+);/g, (_match, code: string) => String.fromCodePoint(Number.parseInt(code, 10)))
    .replace(/&(?:nbsp|#160);/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&quot;/gi, '"')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&(?:frac12|half);/gi, " 1/2 ")
    .replace(/&frac14;/gi, " 1/4 ")
    .replace(/&frac34;/gi, " 3/4 ")
    .toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
}

export function assertPublicRecipeSourceUrl(sourceUrl: string): URL {
  const parsed = new URL(sourceUrl);
  if (parsed.protocol !== "https:") throw new Error("recipe source artifacts require HTTPS");
  const hostname = parsed.hostname.toLowerCase();
  if (hostname === "localhost" || hostname.endsWith(".localhost") || hostname === "0.0.0.0" || hostname === "::1"
    || /^127\./.test(hostname) || /^10\./.test(hostname) || /^192\.168\./.test(hostname)
    || /^169\.254\./.test(hostname) || /^172\.(?:1[6-9]|2\d|3[01])\./.test(hostname)) {
    throw new Error("recipe source URL must be public");
  }
  return parsed;
}

export function verifyRecipeFactsAgainstArtifact(candidate: {
  title: string;
  ingredients: Array<{ raw: string; quantityText: string }>;
}, artifact: string): string[] {
  const text = visibleText(artifact);
  const findings: string[] = [];
  const title = visibleText(candidate.title);
  if (!title || !text.includes(title)) findings.push("title_missing_from_artifact");
  candidate.ingredients.forEach((ingredient, index) => {
    const raw = visibleText(ingredient.raw);
    const quantity = visibleText(ingredient.quantityText);
    if (!raw || !text.includes(raw)) findings.push(`ingredient_${index}_missing_from_artifact`);
    if (quantity && !text.includes(quantity)) findings.push(`ingredient_${index}_quantity_missing_from_artifact`);
  });
  return findings;
}

export async function recipeFactVerificationHash(input: unknown): Promise<string> {
  return digestHex(stableJson(input));
}

export function verifyRecipeMappingContinuity(recipe: {
  candidate: { ingredients: Array<{ raw: string }> };
  ingredients: Array<{ sourceLine: string }>;
}): string[] {
  const source = new Set(recipe.candidate.ingredients.map((ingredient) => visibleText(ingredient.raw)));
  const findings: string[] = [];
  recipe.ingredients.forEach((ingredient, index) => {
    if (!source.has(visibleText(ingredient.sourceLine))) findings.push(`mapping_${index}_source_line_not_locked`);
  });
  return findings;
}
