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

interface CompiledRuleSet {
  commodityId: string;
  includes: RegExp[];
  excludes: RegExp[];
  priority: number;
}

function compileAuthoredPattern(pattern: string): RegExp {
  // The authority file originated in .NET regex. A few rules carry the
  // redundant leading inline case-insensitive flag; JavaScript receives the
  // equivalent `i` flag separately.
  return new RegExp(pattern.replace(/^\(\?i\)/, ""), "i");
}

export function compileProductMatcher(ruleSets: readonly MatchRuleSet[]): (productName: string) => MatchOutcome {
  const compiled: CompiledRuleSet[] = ruleSets.map((rules) => ({
    commodityId: rules.commodityId,
    includes: rules.includes.map(compileAuthoredPattern),
    excludes: rules.excludes.map(compileAuthoredPattern),
    priority: rules.priority ?? 0,
  }));
  return (productName: string): MatchOutcome => {
    const normalized = normalizeName(productName);
    const matches = compiled
      .filter((rules) => rules.includes.some((pattern) => pattern.test(normalized)))
      .filter((rules) => !rules.excludes.some((pattern) => pattern.test(normalized)))
      .sort((left, right) => right.priority - left.priority || left.commodityId.localeCompare(right.commodityId));
    if (matches.length === 0) return { commodityId: null, status: "unmatched", candidates: [] };
    const highest = matches[0]!.priority;
    const tied = matches.filter((candidate) => candidate.priority === highest);
    if (tied.length > 1) return { commodityId: null, status: "collision", candidates: tied.map((item) => item.commodityId) };
    return { commodityId: tied[0]!.commodityId, status: "matched", candidates: [tied[0]!.commodityId] };
  };
}

export interface AisleVerdict {
  status: "confirmed" | "rejected" | "unavailable";
  examined: boolean;
  taxonomyPath: string | null;
  reason: string;
}

export type AisleFamily = "food" | "household" | "personal" | "baby" | "pet";

const AISLE_FAMILY_PATTERNS: Readonly<Record<AisleFamily, readonly string[]>> = {
  food: ["\\bproduce\\b", "\\bmeat\\b", "\\bdairy\\b", "\\bbakery\\b", "\\bpantry\\b", "\\bfrozen\\b", "\\bbeverages?\\b", "\\bsnacks?\\b", "\\bgrocery\\b"],
  household: ["\\bhousehold\\b", "cleaners? air fresheners?", "\\blaundry\\b", "home maintenance"],
  personal: ["\\bhealth beauty\\b", "grooming hygiene", "oral care", "skin care", "feminine products"],
  baby: ["baby child", "infant meals?", "toddler meals?"],
  pet: ["pets wildlife", "pet supplies", "cat litter", "dog food", "cat food", "dog treats?"],
};

export function evaluateAisleFamilyEvidence(
  taxonomyPath: string | undefined,
  expectedFamily: AisleFamily,
  additionalAllowedFamilies: readonly AisleFamily[] = [],
): AisleVerdict {
  if (!taxonomyPath) return { status: "unavailable", examined: false, taxonomyPath: null, reason: "source supplied no shelf taxonomy; name decision is unchanged" };
  const normalized = normalizeName(taxonomyPath);
  const allowedFamilies = new Set<AisleFamily>([expectedFamily, ...additionalAllowedFamilies]);
  // Specific nested taxonomies must win over broad parents. For example,
  // `health_beauty/baby_child` is baby, not generic personal care.
  const detectionOrder: readonly AisleFamily[] = ["baby", "pet", "household", "personal", "food"];
  const observedFamily = detectionOrder.find((family) => AISLE_FAMILY_PATTERNS[family].some((pattern) => new RegExp(pattern, "i").test(normalized)));
  if (!observedFamily) return { status: "unavailable", examined: true, taxonomyPath, reason: "shelf taxonomy is present but does not justify an authoritative flip" };
  if (allowedFamilies.has(observedFamily)) return { status: "confirmed", examined: true, taxonomyPath, reason: `store shelf taxonomy confirms the ${observedFamily} commodity family` };
  return { status: "rejected", examined: true, taxonomyPath, reason: `store shelf taxonomy identifies ${observedFamily}, contradicting the ${expectedFamily} commodity family` };
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
  return compileProductMatcher(ruleSets)(productName);
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
  maxAgeDays?: number;
}

const UNIT_TO_BASE: Readonly<Record<string, { family: "mass" | "volume" | "count"; unitsPerBase: number }>> = {
  gram: { family: "mass", unitsPerBase: 1 },
  kg: { family: "mass", unitsPerBase: 1000 },
  oz: { family: "mass", unitsPerBase: 28.349523125 },
  lb: { family: "mass", unitsPerBase: 453.59237 },
  ml: { family: "volume", unitsPerBase: 1 },
  liter: { family: "volume", unitsPerBase: 1000 },
  fl_oz: { family: "volume", unitsPerBase: 29.5735295625 },
  pt: { family: "volume", unitsPerBase: 473.176473 },
  qt: { family: "volume", unitsPerBase: 946.352946 },
  gal: { family: "volume", unitsPerBase: 3785.411784 },
  each: { family: "count", unitsPerBase: 1 },
  dozen: { family: "count", unitsPerBase: 12 },
};

export function convertUnitPriceMicros(perUnitMicros: number, fromUnit: string, toUnit: string): number | null {
  const from = UNIT_TO_BASE[fromUnit];
  const to = UNIT_TO_BASE[toUnit];
  if (!from || !to || from.family !== to.family) return null;
  const result = Math.round(perUnitMicros * to.unitsPerBase / from.unitsPerBase);
  return Number.isSafeInteger(result) && result >= 0 ? result : null;
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
    if (candidate.maxAgeDays !== undefined && Date.parse(candidate.capturedAt) < Date.parse(nowIso) - candidate.maxAgeDays * 86_400_000) {
      rejected.push({ observationId: candidate.observationId, reason: "stale" });
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
  commodities: Array<{ id: string; label: string; basis_unit: WinnerCandidate["commodityId"] extends string ? string : never; category_id: string; category_label?: string; sort_order?: number }>;
  stores: Array<{ id: string; store_name: string; display_name?: string; membership_required?: number }>;
  candidates: Array<{
    observation_id: string; commodity_id: string; store_location_id: string; per_unit_micros: number;
    captured_at: string; valid_to: string | null; coverage_mode: WinnerCandidate["batchCoverageMode"];
    captured_to: string; normalized_basis_unit: string; known_wrong: number;
    purchase_price_minor?: number; purchase_quantity?: number; package_count?: number;
    normalized_basis_qty_micros?: number; membership_required?: number; loyalty_required?: number;
    raw_price_text?: string | null; name?: string; product_url?: string | null; taxonomy_path?: string | null;
    external_key?: string; size_text?: string | null; batch_id?: string;
    max_age_days?: number;
    basis_options_json?: string;
  }>;
  rawCandidates?: Array<{
    observation_id: string; store_location_id: string; per_unit_micros: number; captured_at: string;
    valid_to: string | null; coverage_mode: WinnerCandidate["batchCoverageMode"]; captured_to: string;
    normalized_basis_unit: string; purchase_price_minor?: number; purchase_quantity?: number;
    package_count?: number; normalized_basis_qty_micros?: number; membership_required?: number;
    loyalty_required?: number; raw_price_text?: string | null; name: string; normalized_name?: string;
    product_url?: string | null; taxonomy_path?: string | null; external_key?: string; size_text?: string | null;
    batch_id?: string;
    max_age_days?: number;
    basis_options_json?: string;
  }>;
  currentCells: Array<{
    commodity_id: string; store_location_id: string; observation_id: string | null; status: string;
    is_crown: number; display_per_unit_micros: number | null; display_unit: string | null;
  }>;
}

export interface NativeReleaseCell {
  commodityId: string;
  storeLocationId: string;
  observationId: string | null;
  status: "priced" | "missing";
  isCrown: boolean;
  displayPerUnitMicros: number | null;
  displayUnit: string | null;
  winner: NativeEngineSnapshot["candidates"][number] | null;
  reason: Record<string, unknown>;
}

interface CandidateBasisOption { unit: string; perUnitMicros: number; source: string }

export function candidateBasisOptions(candidate: {
  normalized_basis_unit: string;
  per_unit_micros: number;
  basis_options_json?: string;
}): CandidateBasisOption[] {
  const options: CandidateBasisOption[] = [{ unit: candidate.normalized_basis_unit, perUnitMicros: candidate.per_unit_micros, source: "normalized" }];
  if (!candidate.basis_options_json) return options;
  try {
    const parsed = JSON.parse(candidate.basis_options_json) as Array<{ unit?: unknown; perUnitMicros?: unknown; source?: unknown }>;
    if (!Array.isArray(parsed)) return options;
    for (const option of parsed) {
      if (typeof option.unit !== "string" || typeof option.perUnitMicros !== "number" || !Number.isSafeInteger(option.perUnitMicros) || option.perUnitMicros < 0) continue;
      if (options.some((existing) => existing.unit === option.unit && existing.perUnitMicros === option.perUnitMicros)) continue;
      options.push({ unit: option.unit, perUnitMicros: option.perUnitMicros, source: typeof option.source === "string" ? option.source : "basis-option" });
    }
  } catch { /* malformed stored options are ignored; ingestion validates new rows */ }
  return options;
}

export function candidatePriceForUnit(candidate: {
  normalized_basis_unit: string;
  per_unit_micros: number;
  basis_options_json?: string;
}, targetUnit: string): { perUnitMicros: number; source: string; unit: string } | null {
  // The normalized observation basis is the captured source of truth. Alternative package bases exist to
  // bridge an otherwise incompatible commodity axis (for example an each-normalized club pack to ounces),
  // not to underbid a valid normalized basis. Choosing the cheapest of two same-unit interpretations let a
  // product name ending in ".85 oz" contribute a bogus 85 oz option and understate toothpaste by 100x.
  const normalized = convertUnitPriceMicros(candidate.per_unit_micros, candidate.normalized_basis_unit, targetUnit);
  if (normalized !== null) return { perUnitMicros: normalized, source: "normalized", unit: candidate.normalized_basis_unit };
  const compatible = candidateBasisOptions(candidate).slice(1).flatMap((option) => {
    const converted = convertUnitPriceMicros(option.perUnitMicros, option.unit, targetUnit);
    return converted === null ? [] : [{ perUnitMicros: converted, source: option.source, unit: option.unit }];
  });
  return compatible.sort((left, right) => left.perUnitMicros - right.perUnitMicros || left.source.localeCompare(right.source))[0] ?? null;
}

function comparableRecord(cell: NativeReleaseCell): Record<string, unknown> {
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

function parityRecord(cell: NativeReleaseCell): Record<string, unknown> {
  const { isCrown: _tiePresentation, ...semantic } = comparableRecord(cell);
  return semantic;
}

export function buildNativeCells(snapshot: NativeEngineSnapshot): NativeReleaseCell[] {
  const groups = new Map<string, NativeEngineSnapshot["candidates"]>();
  for (const candidate of snapshot.candidates) {
    const key = `${candidate.commodity_id}\u001f${candidate.store_location_id}`;
    const items = groups.get(key) ?? [];
    items.push(candidate);
    groups.set(key, items);
  }
  const cells: NativeReleaseCell[] = [];
  for (const commodity of snapshot.commodities) {
    for (const store of snapshot.stores) {
      const key = `${commodity.id}\u001f${store.id}`;
      const selection = selectWinner((groups.get(key) ?? []).flatMap((candidate) => {
        const converted = candidatePriceForUnit(candidate, commodity.basis_unit);
        if (converted === null) return [];
        return [{
        observationId: candidate.observation_id,
        commodityId: candidate.commodity_id,
        storeLocationId: candidate.store_location_id,
        perUnitMicros: converted.perUnitMicros,
        capturedAt: candidate.captured_at,
        batchCoverageMode: candidate.coverage_mode,
        batchCapturedTo: candidate.captured_to,
        ...(candidate.valid_to ? { validTo: candidate.valid_to } : {}),
        knownWrong: candidate.known_wrong === 1,
        ...(candidate.max_age_days !== undefined ? { maxAgeDays: candidate.max_age_days } : {}),
      }]; }), snapshot.observedAt);
      cells.push({
        commodityId: commodity.id,
        storeLocationId: store.id,
        observationId: selection.winner?.observationId ?? null,
        status: selection.winner ? "priced" : "missing",
        isCrown: false,
        displayPerUnitMicros: selection.winner?.perUnitMicros ?? null,
        displayUnit: selection.winner ? commodity.basis_unit : null,
        winner: selection.winner
          ? (groups.get(key) ?? []).find((candidate) => candidate.observation_id === selection.winner!.observationId) ?? null
          : null,
        reason: selection.winner
          ? { code: "native-winner", eligibleCandidates: selection.eligible.length, rejectedCandidates: selection.rejected }
          : { code: "no-eligible-observation", rejectedCandidates: selection.rejected },
      });
    }
  }
  for (const commodity of snapshot.commodities) {
    const priced = cells.filter((cell) => cell.commodityId === commodity.id && cell.status === "priced");
    const crown = [...priced].sort((left, right) => left.displayPerUnitMicros! - right.displayPerUnitMicros! || left.storeLocationId.localeCompare(right.storeLocationId))[0];
    if (crown) crown.isCrown = true;
  }
  return cells;
}

export function buildNativeParityReport(snapshot: NativeEngineSnapshot): EngineParityReport {
  const cells = buildNativeCells(snapshot);
  const current = new Map(snapshot.currentCells.map((cell) => [`${cell.commodity_id}\u001f${cell.store_location_id}`, {
    commodityId: cell.commodity_id,
    storeLocationId: cell.store_location_id,
    observationId: cell.observation_id,
    status: cell.status === "priced" ? "priced" as const : "missing" as const,
    isCrown: cell.is_crown === 1,
    displayPerUnitMicros: cell.display_per_unit_micros,
    displayUnit: cell.display_unit,
    winner: null,
    reason: {},
  } satisfies NativeReleaseCell]));
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
