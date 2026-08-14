const MIN_BATCH_ACCOMPANIMENT_GRAMS = 980;

type JsonRecord = Record<string, unknown>;

function record(value: unknown): JsonRecord | null {
  return value && typeof value === "object" && !Array.isArray(value) ? value as JsonRecord : null;
}

export function normalizeRecipeMapperReadiness(value: unknown): unknown {
  const output = record(value);
  if (!output || !Array.isArray(output.recipes)) return value;
  return {
    ...output,
    recipes: output.recipes.map((entry) => {
      const recipe = record(entry);
      const candidate = record(recipe?.candidate);
      const ingredients = Array.isArray(recipe?.ingredients) ? recipe.ingredients.map(record).filter(Boolean) as JsonRecord[] : [];
      const components = Array.isArray(recipe?.mealComponents) ? recipe.mealComponents.map(record).filter(Boolean) as JsonRecord[] : [];
      if (!recipe || !candidate) return entry;
      const ingredientBlocked = ingredients.some((ingredient) => ingredient.decision !== "process"
        && (ingredient.decision === "unmapped" || ingredient.scalingStatus === "unresolved"));
      const gramsByCommodity = new Map<string, number>();
      for (const ingredient of ingredients) {
        if (typeof ingredient.commodityId === "string" && typeof ingredient.grams === "number") {
          gramsByCommodity.set(ingredient.commodityId, ingredient.grams);
        }
      }
      const accompanimentIds = new Set(components
        .filter((component) => component.role === "substantial-accompaniment")
        .flatMap((component) => Array.isArray(component.commodityIds) ? component.commodityIds.filter((id): id is string => typeof id === "string") : []));
      const accompanimentGrams = [...accompanimentIds].reduce((sum, id) => sum + (gramsByCommodity.get(id) ?? 0), 0);
      const blocked = candidate.sourceServings === null || ingredientBlocked || accompanimentGrams < MIN_BATCH_ACCOMPANIMENT_GRAMS;
      return blocked ? { ...recipe, readyForWriting: false } : { ...recipe, readyForWriting: true };
    }),
  };
}
