import type { NativeEngineSnapshot } from "@thriftycrew/engine";
import { stableJson } from "@thriftycrew/domain";

type Candidate = NativeEngineSnapshot["candidates"][number];

function verifiedIdentity(candidate: Candidate): string {
  return stableJson([
    candidate.commodity_id,
    candidate.store_location_id,
    candidate.normalized_name ?? candidate.name ?? "",
  ]);
}

export function publicationCandidates(
  candidates: readonly Candidate[],
  publicationCommodityIds: ReadonlySet<string>,
  materializedBatchIds: ReadonlySet<string>,
): Candidate[] {
  const verified = new Set(candidates
    .filter((candidate) => publicationCommodityIds.has(candidate.commodity_id)
      && candidate.batch_id !== undefined && materializedBatchIds.has(candidate.batch_id))
    .map(verifiedIdentity));
  return candidates.filter((candidate) => {
    if (!publicationCommodityIds.has(candidate.commodity_id)) return true;
    if (candidate.batch_id !== undefined && materializedBatchIds.has(candidate.batch_id)) return true;
    return (candidate.coverage_mode === "full" || candidate.coverage_mode === "ad_only")
      && verified.has(verifiedIdentity(candidate));
  });
}
