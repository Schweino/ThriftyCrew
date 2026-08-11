import { normalizeName } from "@thriftycrew/domain";

export interface ProductHistoryRow {
  product_id: string;
  external_key: string;
  current_observation_id: string;
  current_name: string;
  current_size_text: string;
  current_per_unit_micros: number;
  current_basis_unit: string;
  current_basis_qty_micros: number;
  current_identity_json: string;
  prior_observation_id: string | null;
  prior_name: string | null;
  prior_size_text: string | null;
  prior_per_unit_micros: number | null;
  prior_basis_unit: string | null;
  prior_basis_qty_micros: number | null;
  prior_identity_json: string | null;
}

export interface CaptureSemanticFinding {
  key: string;
  message: string;
  evidence: Record<string, unknown>;
}

function object(value: string | null): Record<string, unknown> {
  try {
    const parsed = JSON.parse(value ?? "{}");
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed as Record<string, unknown> : {};
  } catch { return {}; }
}

function tokenSimilarity(left: string, right: string): number {
  const a = new Set(normalizeName(left).split(" ").filter(Boolean));
  const b = new Set(normalizeName(right).split(" ").filter(Boolean));
  if (a.size === 0 && b.size === 0) return 1;
  const intersection = [...a].filter((token) => b.has(token)).length;
  return intersection / new Set([...a, ...b]).size;
}

function ratio(left: number, right: number): number {
  if (left <= 0 || right <= 0) return left === right ? 1 : Number.POSITIVE_INFINITY;
  return Math.max(left, right) / Math.min(left, right);
}

export function assessProductHistory(rows: readonly ProductHistoryRow[]): { identityFindings: CaptureSemanticFinding[]; changePointFindings: CaptureSemanticFinding[] } {
  const identityFindings: CaptureSemanticFinding[] = [];
  const changePointFindings: CaptureSemanticFinding[] = [];
  for (const row of rows) {
    const currentIdentity = object(row.current_identity_json);
    // Missing stable channels are a source-specific coverage ratchet. They are
    // not an identity contradiction: some carried catalogs legitimately omit
    // IDs, and rejecting those here would turn a measured gap into a false fact.
    if (!row.prior_observation_id || !row.prior_name || !row.prior_size_text) continue;
    const priorIdentity = object(row.prior_identity_json);
    for (const key of ["gtin", "upc", "retailerProductId", "sku"] as const) {
      const current = currentIdentity[key];
      const prior = priorIdentity[key];
      if (typeof current === "string" && typeof prior === "string" && current !== prior) {
        identityFindings.push({ key: `identifier:${row.product_id}:${key}`, message: `Stable ${key} changed while the retailer external key stayed the same`, evidence: { productId: row.product_id, externalKey: row.external_key, current, prior, currentObservationId: row.current_observation_id, priorObservationId: row.prior_observation_id } });
      }
    }
    const nameSimilarity = tokenSimilarity(row.current_name, row.prior_name);
    const sizeChanged = normalizeName(row.current_size_text) !== normalizeName(row.prior_size_text);
    if (nameSimilarity < 0.25 && sizeChanged) {
      identityFindings.push({ key: `reuse:${row.product_id}`, message: "Retailer external key appears to have been reused for a different product", evidence: { productId: row.product_id, externalKey: row.external_key, currentName: row.current_name, priorName: row.prior_name, currentSize: row.current_size_text, priorSize: row.prior_size_text, nameSimilarity } });
    }
    if (row.prior_basis_unit === row.current_basis_unit && row.prior_basis_qty_micros !== null
      && ratio(row.current_basis_qty_micros, row.prior_basis_qty_micros) >= 4) {
      changePointFindings.push({ key: `basis:${row.product_id}`, message: "Captured package basis changed by at least 4x for the same retailer product", evidence: { productId: row.product_id, externalKey: row.external_key, currentQuantityMicros: row.current_basis_qty_micros, priorQuantityMicros: row.prior_basis_qty_micros, unit: row.current_basis_unit } });
    }
    if (row.prior_per_unit_micros !== null && ratio(row.current_per_unit_micros, row.prior_per_unit_micros) >= 4) {
      changePointFindings.push({ key: `price:${row.product_id}`, message: "Normalized price changed by at least 4x for the same retailer product", evidence: { productId: row.product_id, externalKey: row.external_key, currentPerUnitMicros: row.current_per_unit_micros, priorPerUnitMicros: row.prior_per_unit_micros } });
    }
  }
  return { identityFindings, changePointFindings };
}

export function assessSourceSchema(current: string | null, prior: string | null, required: boolean): { pass: boolean; detail: Record<string, unknown> } {
  if (!required) return { pass: true, detail: { required: false } };
  if (!current) return { pass: false, detail: { required: true, reason: "missing-source-contract-fingerprint" } };
  if (!prior) return { pass: true, detail: { required: true, baseline: true, currentContractFingerprint: current } };
  return { pass: current === prior, detail: { required: true, currentContractFingerprint: current, priorContractFingerprint: prior, drift: current !== prior } };
}
