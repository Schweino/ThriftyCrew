import recipeCommodityExtensions from "../../../config/recipe-commodity-extensions.json";
import recipeCommodityAliases from "../../../config/recipe-commodity-aliases.json";
import recipeCommodityRules from "../../../config/recipe-commodities.json";

interface RecipeCommodityRule {
  id: string;
  label: string;
  unit: string;
}

const recipePricingCommodities = [
  ...recipeCommodityRules.commodities,
  ...recipeCommodityExtensions.commodities,
] as RecipeCommodityRule[];

export function mergeRecipeCommodityCatalog(
  activeCommodities: Array<Record<string, unknown>>,
): Array<Record<string, unknown>> {
  const commoditiesById = new Map<string, Record<string, unknown>>();
  for (const commodity of activeCommodities) {
    const id = typeof commodity.id === "string" ? commodity.id : "";
    if (id) commoditiesById.set(id, commodity);
  }
  for (const commodity of recipePricingCommodities) {
    if (commoditiesById.has(commodity.id)) continue;
    commoditiesById.set(commodity.id, {
      id: commodity.id,
      label: commodity.label,
      basis_unit: commodity.unit,
      category: "Recipe pricing",
    });
  }
  for (const [alias, target] of Object.entries(recipeCommodityAliases)) {
    const commodity = commoditiesById.get(target);
    if (!commodity) continue;
    const aliases = Array.isArray(commodity.recipe_aliases)
      ? commodity.recipe_aliases.filter((value): value is string => typeof value === "string")
      : [];
    commoditiesById.set(target, { ...commodity, recipe_aliases: [...new Set([...aliases, alias])].sort() });
  }
  return [...commoditiesById.values()].sort((left, right) => String(left.id).localeCompare(String(right.id)));
}

export function recipeCommodityIds(activeCommodities: Array<Record<string, unknown>>): Set<string> {
  return new Set(mergeRecipeCommodityCatalog(activeCommodities).map((commodity) => String(commodity.id)));
}
