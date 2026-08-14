export type MatchRunIdentity = {
  id: string;
  batchId: string;
  configurationId: string;
  inputHash: string;
  productCount: number;
  matchedCount: number;
  unmatchedCount: number;
  collisionCount: number;
  aisleRejectedCount: number;
};

type StoredMatchRun = {
  id: string;
  status: string;
  product_count: number;
  matched_count: number;
  unmatched_count: number;
  collision_count: number;
  aisle_rejected_count: number;
};

export function sameMatchRunFacts(row: StoredMatchRun, body: MatchRunIdentity, status: string): boolean {
  return row.status === status
    && Number(row.product_count) === body.productCount
    && Number(row.matched_count) === body.matchedCount
    && Number(row.unmatched_count) === body.unmatchedCount
    && Number(row.collision_count) === body.collisionCount
    && Number(row.aisle_rejected_count) === body.aisleRejectedCount;
}

