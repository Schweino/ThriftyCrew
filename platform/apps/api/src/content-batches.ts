import type { ContentItem } from "@thriftycrew/contracts";
import { digestHex, normalizeName, stableJson } from "@thriftycrew/domain";

export interface ContentGuardFinding {
  key: string;
  severity: "hard" | "warning";
  message: string;
  itemSlug?: string;
}

export async function evaluateContentPromotion(
  items: readonly ContentItem[],
  validCommodityIds: ReadonlySet<string>,
): Promise<{ ok: boolean; contentHash: string; findings: ContentGuardFinding[] }> {
  const findings: ContentGuardFinding[] = [];
  const slugs = new Set<string>();
  const titles = new Set<string>();
  for (const item of items) {
    if (slugs.has(item.slug)) findings.push({ key: `duplicate-slug:${item.slug}`, severity: "hard", message: "recipe slug is duplicated", itemSlug: item.slug });
    slugs.add(item.slug);
    const normalizedTitle = normalizeName(item.title);
    if (titles.has(normalizedTitle)) findings.push({ key: `duplicate-title:${item.slug}`, severity: "hard", message: "normalized recipe title is duplicated", itemSlug: item.slug });
    titles.add(normalizedTitle);
    const ingredients = new Set<string>();
    const ingredientCommodityIds = new Set<string>();
    for (const ingredient of item.ingredients) {
      const normalizedIngredient = normalizeName(ingredient.name);
      if (ingredients.has(normalizedIngredient)) findings.push({ key: `duplicate-ingredient:${item.slug}:${normalizedIngredient}`, severity: "hard", message: "recipe repeats an ingredient instead of combining quantities", itemSlug: item.slug });
      ingredients.add(normalizedIngredient);
      if (ingredientCommodityIds.has(ingredient.commodityId)) findings.push({ key: `duplicate-commodity:${item.slug}:${ingredient.commodityId}`, severity: "hard", message: "recipe repeats a commodity instead of combining its grams", itemSlug: item.slug });
      ingredientCommodityIds.add(ingredient.commodityId);
      if (!validCommodityIds.has(ingredient.commodityId)) findings.push({ key: `unknown-commodity:${item.slug}:${ingredient.commodityId}`, severity: "hard", message: `ingredient maps to unknown commodity ${ingredient.commodityId}`, itemSlug: item.slug });
    }
    const usedCommodityIds = new Set(item.instructions.flatMap((instruction) => instruction.usesCommodityIds));
    for (const commodityId of ingredientCommodityIds) {
      if (!usedCommodityIds.has(commodityId)) findings.push({ key: `unused-ingredient:${item.slug}:${commodityId}`, severity: "hard", message: `ingredient ${commodityId} is purchased but never used by an instruction`, itemSlug: item.slug });
    }
    for (const commodityId of usedCommodityIds) {
      if (!ingredientCommodityIds.has(commodityId)) findings.push({ key: `unlisted-step-ingredient:${item.slug}:${commodityId}`, severity: "hard", message: `instructions use ${commodityId}, but the ingredient list does not purchase it`, itemSlug: item.slug });
    }
    if (new Set(item.provenance.map((source) => new URL(source.url).hostname)).size < 1) findings.push({ key: `missing-provenance:${item.slug}`, severity: "hard", message: "recipe lacks attributable provenance", itemSlug: item.slug });
  }
  const contentHash = await digestHex(stableJson([...items].sort((left, right) => left.slug.localeCompare(right.slug))));
  return { ok: !findings.some((finding) => finding.severity === "hard"), contentHash, findings };
}
