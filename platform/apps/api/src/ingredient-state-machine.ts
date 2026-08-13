import { OMAHA_GROCERY_STORE_LOCATION_IDS } from "@thriftycrew/contracts";

export const INGREDIENT_JOB_STATES = [
  "queued", "identity_ready", "store_checks_running", "aggregate_ready", "proposal_ready",
  "ready_to_publish", "publishing", "public_verified", "permanently_unavailable",
  "cancelled", "failed_manual",
] as const;

export const INGREDIENT_STORE_CHECK_STATES = [
  "queued", "catalog_lookup", "capture_queued", "capture_leased", "evidence_ready",
  "qa_queued", "qa_leased", "qa_verified_priced", "qa_verified_not_found",
  "challenge_blocked", "location_blocked", "authentication_blocked", "ambiguous",
  "adapter_quarantined", "transient_backoff", "evidence_expired", "cancelled",
] as const;

export type IngredientJobState = typeof INGREDIENT_JOB_STATES[number];
export type IngredientStoreCheckState = typeof INGREDIENT_STORE_CHECK_STATES[number];

export type IngredientAggregate = {
  state: "store_checks_running" | "ready_to_publish" | "permanently_unavailable";
  terminalCount: number;
  pricedCount: number;
  notFoundCount: number;
};

const terminalChecks = new Set<IngredientStoreCheckState>(["qa_verified_priced", "qa_verified_not_found"]);

const storeTransitions: Readonly<Record<IngredientStoreCheckState, ReadonlySet<IngredientStoreCheckState>>> = {
  queued: new Set(["catalog_lookup", "capture_queued", "cancelled"]),
  catalog_lookup: new Set(["capture_queued", "evidence_ready", "qa_queued", "transient_backoff", "cancelled"]),
  capture_queued: new Set(["capture_leased", "cancelled"]),
  capture_leased: new Set(["evidence_ready", "challenge_blocked", "location_blocked", "authentication_blocked", "ambiguous", "adapter_quarantined", "transient_backoff", "cancelled"]),
  evidence_ready: new Set(["qa_queued", "evidence_expired", "cancelled"]),
  qa_queued: new Set(["qa_leased", "evidence_expired", "cancelled"]),
  qa_leased: new Set(["qa_verified_priced", "qa_verified_not_found", "ambiguous", "evidence_expired", "transient_backoff", "cancelled"]),
  qa_verified_priced: new Set(["evidence_expired", "cancelled"]),
  qa_verified_not_found: new Set(["evidence_expired", "cancelled"]),
  challenge_blocked: new Set(["capture_queued", "cancelled"]),
  location_blocked: new Set(["capture_queued", "adapter_quarantined", "cancelled"]),
  authentication_blocked: new Set(["capture_queued", "adapter_quarantined", "cancelled"]),
  ambiguous: new Set(["capture_queued", "qa_queued", "cancelled"]),
  adapter_quarantined: new Set(["capture_queued", "cancelled"]),
  transient_backoff: new Set(["catalog_lookup", "capture_queued", "qa_queued", "cancelled"]),
  evidence_expired: new Set(["catalog_lookup", "capture_queued", "cancelled"]),
  cancelled: new Set(),
};

export function assertStoreCheckTransition(from: string, to: string): asserts to is IngredientStoreCheckState {
  if (!(INGREDIENT_STORE_CHECK_STATES as readonly string[]).includes(from)) throw new Error(`unknown store-check state ${from}`);
  if (!(INGREDIENT_STORE_CHECK_STATES as readonly string[]).includes(to)) throw new Error(`unknown store-check state ${to}`);
  if (from !== to && !storeTransitions[from as IngredientStoreCheckState].has(to as IngredientStoreCheckState)) {
    throw new Error(`invalid store-check transition ${from} -> ${to}`);
  }
}

export function aggregateIngredientStoreChecks(states: Array<{ storeLocationId?: string; state: string }>): IngredientAggregate {
  if (states.length !== OMAHA_GROCERY_STORE_LOCATION_IDS.length) {
    return { state: "store_checks_running", terminalCount: states.filter((row) => terminalChecks.has(row.state as IngredientStoreCheckState)).length,
      pricedCount: states.filter((row) => row.state === "qa_verified_priced").length,
      notFoundCount: states.filter((row) => row.state === "qa_verified_not_found").length };
  }
  const providedStores = states.map((row) => row.storeLocationId).filter((value): value is string => Boolean(value));
  if (providedStores.length > 0) {
    const expected = [...OMAHA_GROCERY_STORE_LOCATION_IDS].sort();
    const actual = [...providedStores].sort();
    if (new Set(actual).size !== actual.length || JSON.stringify(actual) !== JSON.stringify(expected)) {
      throw new Error("ingredient aggregate must contain exactly one check for each authoritative Omaha store");
    }
  }
  const terminalCount = states.filter((row) => terminalChecks.has(row.state as IngredientStoreCheckState)).length;
  const pricedCount = states.filter((row) => row.state === "qa_verified_priced").length;
  const notFoundCount = states.filter((row) => row.state === "qa_verified_not_found").length;
  if (terminalCount !== OMAHA_GROCERY_STORE_LOCATION_IDS.length) return { state: "store_checks_running", terminalCount, pricedCount, notFoundCount };
  if (notFoundCount === OMAHA_GROCERY_STORE_LOCATION_IDS.length) return { state: "permanently_unavailable", terminalCount, pricedCount, notFoundCount };
  if (pricedCount > 0 && pricedCount + notFoundCount === OMAHA_GROCERY_STORE_LOCATION_IDS.length) {
    return { state: "ready_to_publish", terminalCount, pricedCount, notFoundCount };
  }
  throw new Error("seven terminal store checks have an impossible aggregate");
}

export async function transitionStoreCheck(
  db: D1Database,
  input: { checkId: string; from: IngredientStoreCheckState; to: IngredientStoreCheckState; expectedVersion: number; detail?: string | null },
): Promise<number> {
  assertStoreCheckTransition(input.from, input.to);
  const update = await db.prepare(
    `UPDATE ingredient_store_checks
        SET operational_state = ?3, state_version = state_version + 1,
            last_error = COALESCE(?5, last_error), last_progress_at = CURRENT_TIMESTAMP,
            updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND operational_state = ?2 AND state_version = ?4`,
  ).bind(input.checkId, input.from, input.to, input.expectedVersion, input.detail ?? null).run();
  if ((update.meta.changes ?? 0) !== 1) throw new Error("store-check transition rejected by state-version fence");
  return input.expectedVersion + 1;
}
