import type { MutationClient } from "@thriftycrew/daily/client";
import type { PublicIngredientSnapshot } from "@thriftycrew/contracts";

export async function publishIncrementalIngredient(client: MutationClient, input: {
  snapshot: PublicIngredientSnapshot; pricingJobId: string; origins: readonly string[];
}) {
  if (input.origins.length !== 2) throw new Error("incremental publication requires exactly two configured public origins");
  const staged = await client.request("/internal/v4/ingredients/stage", { json: { snapshot: input.snapshot, pricingJobId: input.pricingJobId } }) as unknown as {
    publicVersionId: string; snapshotHash: string; previousPublicVersionId: string | null; expectedPointerGeneration: number;
  };
  await client.request(`/internal/v4/ingredients/${encodeURIComponent(staged.publicVersionId)}/preview`);
  const pointer = await client.request(`/internal/v4/ingredients/${encodeURIComponent(staged.publicVersionId)}/pointer`, {
    json: { ingredientId: input.snapshot.ingredientId, expectedGeneration: staged.expectedPointerGeneration },
  }) as unknown as { pointerGeneration: number };
  try {
    const proofs = await Promise.all(input.origins.map(async (origin) => {
      const url = new URL(`/api/v3/grocery/ingredients/${encodeURIComponent(input.snapshot.slug)}`, origin).toString();
      const response = await fetch(url, { headers: { "cache-control": "no-cache" } });
      if (!response.ok) throw new Error(`${origin} returned HTTP ${response.status}`);
      const body = await response.json() as { ingredient?: { contentHash?: string } };
      return { origin, url, expectedHash: staged.snapshotHash, observedHash: String(body.ingredient?.contentHash ?? ""), verifiedAt: new Date().toISOString() };
    }));
    await client.request(`/internal/v4/ingredients/${encodeURIComponent(staged.publicVersionId)}/finalize`, { json: {
      pricingJobId: input.pricingJobId, originProofs: proofs,
    } });
    return { ok: true, ...staged, proofs };
  } catch (error) {
    await client.request(`/internal/v4/ingredients/${encodeURIComponent(staged.publicVersionId)}/rollback`, { json: {
      ingredientId: input.snapshot.ingredientId, expectedGeneration: pointer.pointerGeneration, previousVersionId: staged.previousPublicVersionId,
    } });
    throw error;
  }
}
