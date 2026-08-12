import type { RecipeCost } from "@thriftycrew/contracts";
import { digestHex, stableJson } from "@thriftycrew/domain";

export type ReleaseNodeKind = "cell" | "recipe" | "payload" | "top5" | "free-rotation";

export interface ReleaseGraphNode {
  kind: ReleaseNodeKind;
  key: string;
  dependencyHash: string;
  contentHash: string;
  payload: unknown;
}

export interface ContentAddressedReleaseGraph {
  version: 1;
  parentReleaseId: string | null;
  dependencyHash: string;
  nodes: ReleaseGraphNode[];
}

async function node(kind: ReleaseNodeKind, key: string, dependency: unknown, payload: unknown): Promise<ReleaseGraphNode> {
  const declared = typeof dependency === "string" && /^[a-f0-9]{64}$/.test(dependency) ? dependency : null;
  return { kind, key, dependencyHash: declared ?? await digestHex(stableJson(dependency)), contentHash: await digestHex(stableJson(payload)), payload };
}

export async function buildContentAddressedReleaseGraph(input: {
  parentReleaseId: string | null;
  inputHash: string;
  configurationId: string;
  cells: ReadonlyArray<{
    commodityId: string; storeLocationId: string; observationId?: string;
    status: "priced" | "missing"; isCrown: boolean; displayPerUnitMicros?: number;
    displayUnit?: string; reason: Record<string, unknown>;
  }>;
  recipeCosts: readonly RecipeCost[];
  payloads: Record<string, unknown>;
  top5: readonly unknown[];
  freeRotation: readonly unknown[];
}): Promise<ContentAddressedReleaseGraph> {
  const nodes: ReleaseGraphNode[] = [];
  for (const cell of input.cells) {
    const payload = { ...cell, reason: cell.reason ?? {} };
    const reason = cell.reason as Record<string, unknown>;
    nodes.push(await node("cell", `${cell.commodityId}\u001f${cell.storeLocationId}`,
      typeof reason.incrementalDependencyHash === "string" ? reason.incrementalDependencyHash : {
      configurationId: input.configurationId, commodityId: cell.commodityId,
      storeLocationId: cell.storeLocationId, observationId: cell.observationId ?? null,
    }, payload));
  }
  for (const cost of input.recipeCosts) {
    const detail = cost.detail as Record<string, unknown>;
    const ingredients = Array.isArray(detail.ingredients) ? detail.ingredients : [];
    nodes.push(await node("recipe", cost.recipeSlug,
      typeof detail.incrementalDependencyHash === "string" ? detail.incrementalDependencyHash : {
      configurationId: input.configurationId,
      recipeSlug: cost.recipeSlug,
      inputs: ingredients.map((ingredient) => {
        const value = ingredient && typeof ingredient === "object" ? ingredient as Record<string, unknown> : {};
        return [value.item, value.commodityId, value.observationId, value.nonMemberObservationId, value.grams, value.gpu, value.conversionRegistryHash];
      }),
      scenarioModel: "recipe-cost-scenarios-v1",
    }, cost));
  }
  for (const [kind, payload] of Object.entries(input.payloads).sort(([left], [right]) => left.localeCompare(right))) {
    nodes.push(await node("payload", kind, { inputHash: input.inputHash, kind }, payload));
  }
  nodes.push(await node("top5", "all", { recipes: input.recipeCosts.map((cost) => [cost.recipeSlug, cost.servingCostMinor ?? null]) }, input.top5));
  nodes.push(await node("free-rotation", "all", { top5: input.top5 }, input.freeRotation));
  nodes.sort((left, right) => left.kind.localeCompare(right.kind) || left.key.localeCompare(right.key));
  return {
    version: 1,
    parentReleaseId: input.parentReleaseId,
    dependencyHash: await digestHex(stableJson(nodes.map((item) => [item.kind, item.key, item.dependencyHash]))),
    nodes,
  };
}
