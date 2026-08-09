import type { ReleaseGuardResult } from "@thriftycrew/contracts";
import type { EngineParityReport } from "@thriftycrew/contracts";
import { normalizeName } from "@thriftycrew/domain";

export interface MatchRuleSet {
  commodityId: string;
  includes: readonly string[];
  excludes: readonly string[];
  priority?: number;
}

export interface MatchOutcome {
  commodityId: string | null;
  status: "matched" | "unmatched" | "collision";
  candidates: string[];
}

export interface AisleVerdict {
  status: "confirmed" | "rejected" | "unavailable";
  examined: boolean;
  taxonomyPath: string | null;
  reason: string;
}

export function evaluateAisleEvidence(
  taxonomyPath: string | undefined,
  allowedPatterns: readonly string[],
  blockedPatterns: readonly string[],
): AisleVerdict {
  if (!taxonomyPath) return { status: "unavailable", examined: false, taxonomyPath: null, reason: "source supplied no shelf taxonomy; name decision is unchanged" };
  const normalized = normalizeName(taxonomyPath);
  if (blockedPatterns.some((pattern) => new RegExp(pattern, "i").test(normalized))) {
    return { status: "rejected", examined: true, taxonomyPath, reason: "store shelf taxonomy matches a blocked aisle" };
  }
  if (allowedPatterns.some((pattern) => new RegExp(pattern, "i").test(normalized))) {
    return { status: "confirmed", examined: true, taxonomyPath, reason: "store shelf taxonomy confirms the commodity family" };
  }
  return { status: "unavailable", examined: true, taxonomyPath, reason: "shelf taxonomy is present but does not justify an authoritative flip" };
}

export function matchProductName(productName: string, ruleSets: readonly MatchRuleSet[]): MatchOutcome {
  const normalized = normalizeName(productName);
  const matches = ruleSets
    .filter((rules) => rules.includes.some((pattern) => new RegExp(pattern, "i").test(normalized)))
    .filter((rules) => !rules.excludes.some((pattern) => new RegExp(pattern, "i").test(normalized)))
    .sort((left, right) => (right.priority ?? 0) - (left.priority ?? 0) || left.commodityId.localeCompare(right.commodityId));

  if (matches.length === 0) return { commodityId: null, status: "unmatched", candidates: [] };
  const highest = matches[0]?.priority ?? 0;
  const tied = matches.filter((candidate) => (candidate.priority ?? 0) === highest);
  if (tied.length > 1) return { commodityId: null, status: "collision", candidates: tied.map((item) => item.commodityId) };
  return { commodityId: tied[0]!.commodityId, status: "matched", candidates: [tied[0]!.commodityId] };
}

export interface WinnerCandidate {
  observationId: string;
  commodityId: string;
  storeLocationId: string;
  perUnitMicros: number;
  capturedAt: string;
  batchCoverageMode: "full" | "partial" | "targeted" | "ad_only";
  batchCapturedTo: string;
  validTo?: string;
  knownWrong?: boolean;
}

export interface WinnerSelection {
  winner: WinnerCandidate | null;
  eligible: WinnerCandidate[];
  rejected: Array<{ observationId: string; reason: string }>;
}

export function selectWinner(candidates: readonly WinnerCandidate[], nowIso: string): WinnerSelection {
  const rejected: Array<{ observationId: string; reason: string }> = [];
  const eligible = candidates.filter((candidate) => {
    if (candidate.knownWrong) {
      rejected.push({ observationId: candidate.observationId, reason: "known-wrong" });
      return false;
    }
    if (candidate.validTo && candidate.validTo < nowIso) {
      rejected.push({ observationId: candidate.observationId, reason: "expired" });
      return false;
    }
    return true;
  });

  if (eligible.length === 0) return { winner: null, eligible, rejected };

  // A partial capture may add observations but cannot evict an otherwise eligible
  // product from a newer complete window merely because its batch is thinner.
  const complete = eligible.filter((candidate) => candidate.batchCoverageMode === "full" || candidate.batchCoverageMode === "ad_only");
  const selectionPool = complete.length > 0 ? complete : eligible;
  const winner = [...selectionPool].sort((left, right) =>
    left.perUnitMicros - right.perUnitMicros || right.capturedAt.localeCompare(left.capturedAt) || left.observationId.localeCompare(right.observationId)
  )[0] ?? null;
  return { winner, eligible, rejected };
}

export function guardResult(input: Omit<ReleaseGuardResult, "findings"> & { findings?: ReleaseGuardResult["findings"] }): ReleaseGuardResult {
  const result: ReleaseGuardResult = { ...input, findings: input.findings ?? [] };
  if (result.examinedCount > result.eligibleCount) throw new Error("guard examined count exceeds eligible count");
  if (result.eligibleCount > 0 && result.examinedCount === 0 && result.status === "pass") {
    throw new Error("blind guard cannot pass");
  }
  return result;
}

export interface NativeEngineSnapshot {
  mode: "legacy" | "direct" | "all";
  observedAt: string;
  configurationId: string;
  currentReleaseId: string;
  inputHash: string;
  inputBatchIds: string[];
  commodities: Array<{ id: string; label: string; basis_unit: WinnerCandidate["commodityId"] extends string ? string : never; category_id: string }>;
  stores: Array<{ id: string; store_name: string }>;
  candidates: Array<{
    observation_id: string; commodity_id: string; store_location_id: string; per_unit_micros: number;
    captured_at: string; valid_to: string | null; coverage_mode: WinnerCandidate["batchCoverageMode"];
    captured_to: string; known_wrong: number;
  }>;
  currentCells: Array<{
    commodity_id: string; store_location_id: string; observation_id: string | null; status: string;
    is_crown: number; display_per_unit_micros: number | null; display_unit: string | null;
  }>;
}

interface ComparableCell {
  commodityId: string;
  storeLocationId: string;
  observationId: string | null;
  status: "priced" | "missing";
  isCrown: boolean;
  displayPerUnitMicros: number | null;
  displayUnit: string | null;
}

function comparableRecord(cell: ComparableCell): Record<string, unknown> {
  return {
    commodityId: cell.commodityId,
    storeLocationId: cell.storeLocationId,
    observationId: cell.observationId,
    status: cell.status,
    isCrown: cell.isCrown,
    displayPerUnitMicros: cell.displayPerUnitMicros,
    displayUnit: cell.displayUnit,
  };
}

function parityRecord(cell: ComparableCell): Record<string, unknown> {
  const { isCrown: _tiePresentation, ...semantic } = comparableRecord(cell);
  return semantic;
}

export function buildNativeParityReport(snapshot: NativeEngineSnapshot): EngineParityReport {
  const groups = new Map<string, NativeEngineSnapshot["candidates"]>();
  for (const candidate of snapshot.candidates) {
    const key = `${candidate.commodity_id}\u001f${candidate.store_location_id}`;
    const items = groups.get(key) ?? [];
    items.push(candidate);
    groups.set(key, items);
  }
  const cells: ComparableCell[] = [];
  for (const commodity of snapshot.commodities) {
    for (const store of snapshot.stores) {
      const key = `${commodity.id}\u001f${store.id}`;
      const selection = selectWinner((groups.get(key) ?? []).map((candidate) => ({
        observationId: candidate.observation_id,
        commodityId: candidate.commodity_id,
        storeLocationId: candidate.store_location_id,
        perUnitMicros: candidate.per_unit_micros,
        capturedAt: candidate.captured_at,
        batchCoverageMode: candidate.coverage_mode,
        batchCapturedTo: candidate.captured_to,
        ...(candidate.valid_to ? { validTo: candidate.valid_to } : {}),
        knownWrong: candidate.known_wrong === 1,
      })), snapshot.observedAt);
      cells.push({
        commodityId: commodity.id,
        storeLocationId: store.id,
        observationId: selection.winner?.observationId ?? null,
        status: selection.winner ? "priced" : "missing",
        isCrown: false,
        displayPerUnitMicros: selection.winner?.perUnitMicros ?? null,
        displayUnit: selection.winner ? commodity.basis_unit : null,
      });
    }
  }
  for (const commodity of snapshot.commodities) {
    const priced = cells.filter((cell) => cell.commodityId === commodity.id && cell.status === "priced");
    const crown = [...priced].sort((left, right) => left.displayPerUnitMicros! - right.displayPerUnitMicros! || left.storeLocationId.localeCompare(right.storeLocationId))[0];
    if (crown) crown.isCrown = true;
  }
  const current = new Map(snapshot.currentCells.map((cell) => [`${cell.commodity_id}\u001f${cell.store_location_id}`, {
    commodityId: cell.commodity_id,
    storeLocationId: cell.store_location_id,
    observationId: cell.observation_id,
    status: cell.status === "priced" ? "priced" as const : "missing" as const,
    isCrown: cell.is_crown === 1,
    displayPerUnitMicros: cell.display_per_unit_micros,
    displayUnit: cell.display_unit,
  } satisfies ComparableCell]));
  const diffs: EngineParityReport["diffs"] = [];
  for (const cell of cells) {
    const key = `${cell.commodityId}\u001f${cell.storeLocationId}`;
    const expected = current.get(key) ?? null;
    if (!expected || JSON.stringify(parityRecord(expected)) !== JSON.stringify(parityRecord(cell))) {
      if (diffs.length < 500) diffs.push({ key: key.replace("\u001f", ":"), current: expected ? comparableRecord(expected) : null, native: comparableRecord(cell), reason: !expected ? "cell is absent from current release" : "native winner semantics differ from current release" });
    }
  }
  const currentOnly = [...current.keys()].filter((key) => !cells.some((cell) => `${cell.commodityId}\u001f${cell.storeLocationId}` === key));
  for (const key of currentOnly) if (diffs.length < 500) diffs.push({ key: key.replace("\u001f", ":"), current: comparableRecord(current.get(key)!), native: null, reason: "current release cell is absent from native output" });
  const diffCount = cells.filter((cell) => {
    const expected = current.get(`${cell.commodityId}\u001f${cell.storeLocationId}`);
    return !expected || JSON.stringify(parityRecord(expected)) !== JSON.stringify(parityRecord(cell));
  }).length + currentOnly.length;
  return {
    runId: `parity-v3-${snapshot.mode}-${snapshot.observedAt.slice(0, 10)}-${snapshot.inputHash.slice(0, 16)}`,
    mode: snapshot.mode,
    observedAt: snapshot.observedAt,
    currentReleaseId: snapshot.currentReleaseId,
    configurationId: snapshot.configurationId,
    inputHash: snapshot.inputHash,
    inputBatchIds: [...snapshot.inputBatchIds].sort(),
    comparedCells: cells.length,
    diffCount,
    diffs,
  };
}
