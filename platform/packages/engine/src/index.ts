import type { ReleaseGuardResult } from "@thriftycrew/contracts";
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
