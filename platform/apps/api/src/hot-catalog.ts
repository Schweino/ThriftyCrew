import { digestHex, normalizeName, stableJson } from "@thriftycrew/domain";

type PolicyRow = { store_location_id: string; source_id: string };
type BatchRow = { id: string; source_id: string; store_location_id: string; coverage_mode: "full" | "partial"; captured_from: string; captured_to: string; valid_from: string | null; valid_to: string | null };

export type CatalogCandidate = {
  productId: string;
  observationId: string;
  productName: string;
  normalizedName: string;
  sizeText: string;
  productUrl: string | null;
  availabilityStatus: string;
  fulfillmentMode: string;
  sellerName: string | null;
  offerKind: string;
  packagePriceMinor: number;
  normalizedBasisUnit: string;
  normalizedBasisQtyMicros: number;
  perUnitMicros: number;
  loyaltyRequired: boolean;
  membershipRequired: boolean;
  validFrom: string | null;
  validTo: string | null;
  capturedAt: string;
  evidenceHash: string;
};

const tokens = (value: string): string[] => [...new Set(normalizeName(value).split(/[^a-z0-9]+/).filter((token) => token.length >= 2))].sort();

export function catalogCandidatesForTerms(offers: CatalogCandidate[], terms: string[], now = new Date()): CatalogCandidate[] {
  const normalizedTerms = terms.map((term) => normalizeName(term)).filter(Boolean);
  const nowIso = now.toISOString();
  return offers.filter((offer) => {
    if (!normalizedTerms.some((term) => offer.normalizedName.includes(term))) return false;
    if (!["in_stock", "available", "limited"].includes(offer.availabilityStatus)) return false;
    if (offer.validFrom && offer.validFrom > nowIso) return false;
    if (offer.validTo && offer.validTo <= nowIso) return false;
    return true;
  }).sort((left, right) => left.normalizedBasisUnit.localeCompare(right.normalizedBasisUnit)
    || left.perUnitMicros - right.perUnitMicros || left.productId.localeCompare(right.productId));
}

export function chooseCatalogWinner(candidates: CatalogCandidate[]): { winner: CatalogCandidate | null; reason: string | null } {
  if (candidates.length === 0) return { winner: null, reason: "no exact catalog candidate" };
  const units = new Set(candidates.map((candidate) => candidate.normalizedBasisUnit));
  if (units.size !== 1) return { winner: null, reason: "candidate basis units are incompatible" };
  return { winner: [...candidates].sort((left, right) => left.perUnitMicros - right.perUnitMicros || left.productId.localeCompare(right.productId))[0]!, reason: null };
}

export async function materializeHotCatalog(db: D1Database): Promise<{ roots: number; offers: number; tokens: number }> {
  const policies = await db.prepare("SELECT store_location_id, source_id FROM store_pricing_policies ORDER BY store_location_id").all<PolicyRow>();
  let offerCount = 0;
  let tokenCount = 0;
  for (const policy of policies.results) {
    const batch = await db.prepare(
      `SELECT batch.id, batch.source_id, source.store_location_id, batch.coverage_mode,
              batch.captured_from, batch.captured_to, batch.valid_from, batch.valid_to
         FROM capture_batches batch JOIN capture_sources source ON source.id = batch.source_id
        WHERE batch.source_id = ?1 AND batch.status = 'promoted' AND batch.coverage_mode IN ('full','partial')
        ORDER BY CASE batch.coverage_mode WHEN 'full' THEN 0 ELSE 1 END, batch.captured_to DESC, batch.id DESC LIMIT 1`,
    ).bind(policy.source_id).first<BatchRow>();
    if (!batch) continue;
    const rootHash = await digestHex(stableJson(batch));
    await db.prepare(
      `INSERT INTO capture_source_roots
         (source_id, store_location_id, base_batch_id, root_hash, coverage_mode, valid_from, valid_to)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
       ON CONFLICT(source_id) DO UPDATE SET base_batch_id = excluded.base_batch_id,
         root_hash = excluded.root_hash, coverage_mode = excluded.coverage_mode,
         valid_from = excluded.valid_from, valid_to = excluded.valid_to, updated_at = CURRENT_TIMESTAMP`,
    ).bind(batch.source_id, batch.store_location_id, batch.id, rootHash, batch.coverage_mode, batch.valid_from ?? batch.captured_from, batch.valid_to).run();
    const rows = await db.prepare(
      `SELECT product.id AS product_id, observation.id AS observation_id, observation.product_version_id,
              version.name AS product_name, version.normalized_name, version.size_text, version.product_url,
              observation.availability_status, observation.fulfillment_mode, observation.seller_name,
              observation.kind AS offer_kind, observation.purchase_price_minor AS package_price_minor,
              observation.normalized_basis_unit, observation.normalized_basis_qty_micros, observation.per_unit_micros,
              observation.loyalty_required, observation.membership_required, observation.valid_from, observation.valid_to,
              observation.captured_at
         FROM observations observation
         JOIN product_versions version ON version.id = observation.product_version_id
         JOIN products product ON product.id = version.product_id
        WHERE observation.batch_id = ?1
          AND NOT EXISTS (
            SELECT 1 FROM observations newer
             WHERE newer.batch_id = observation.batch_id AND newer.product_version_id = observation.product_version_id
               AND (newer.captured_at > observation.captured_at OR (newer.captured_at = observation.captured_at AND newer.id > observation.id))
          )
        ORDER BY product.id`,
    ).bind(batch.id).all<Record<string, unknown>>();
    const currentProductIds = new Set(rows.results.map((row) => String(row.product_id)));
    if (batch.coverage_mode === "full") {
      const existing = await db.prepare("SELECT product_id FROM catalog_current_offers WHERE source_id = ?1").bind(batch.source_id).all<{ product_id: string }>();
      const stale = existing.results.filter((row) => !currentProductIds.has(row.product_id));
      if (stale.length) {
        for (let offset = 0; offset < stale.length; offset += 90) {
          await db.batch(stale.slice(offset, offset + 90).flatMap((row) => [
            db.prepare("DELETE FROM catalog_offer_tokens WHERE store_location_id = ?1 AND product_id = ?2").bind(batch.store_location_id, row.product_id),
            db.prepare("DELETE FROM catalog_current_offers WHERE store_location_id = ?1 AND product_id = ?2 AND source_id = ?3").bind(batch.store_location_id, row.product_id, batch.source_id),
          ]));
        }
      }
    }
    for (const row of rows.results) {
      const semantic = {
        observationId: row.observation_id, productVersionId: row.product_version_id, name: row.product_name,
        size: row.size_text, price: row.package_price_minor, unit: row.normalized_basis_unit,
        qty: row.normalized_basis_qty_micros, perUnit: row.per_unit_micros, validFrom: row.valid_from, validTo: row.valid_to,
        availability: row.availability_status, fulfillment: row.fulfillment_mode, seller: row.seller_name,
      };
      const evidenceHash = await digestHex(stableJson(semantic));
      await db.prepare(
        `INSERT INTO catalog_current_offers
           (store_location_id, product_id, observation_id, product_version_id, source_id, batch_id, normalized_name,
            product_name, size_text, product_url, availability_status, fulfillment_mode, seller_name, offer_kind,
            package_price_minor, normalized_basis_unit, normalized_basis_qty_micros, per_unit_micros,
            loyalty_required, membership_required, valid_from, valid_to, captured_at, evidence_hash)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)
         ON CONFLICT(store_location_id, product_id) DO UPDATE SET
           observation_id = excluded.observation_id, product_version_id = excluded.product_version_id,
           source_id = excluded.source_id, batch_id = excluded.batch_id, normalized_name = excluded.normalized_name,
           product_name = excluded.product_name, size_text = excluded.size_text, product_url = excluded.product_url,
           availability_status = excluded.availability_status, fulfillment_mode = excluded.fulfillment_mode,
           seller_name = excluded.seller_name, offer_kind = excluded.offer_kind, package_price_minor = excluded.package_price_minor,
           normalized_basis_unit = excluded.normalized_basis_unit, normalized_basis_qty_micros = excluded.normalized_basis_qty_micros,
           per_unit_micros = excluded.per_unit_micros, loyalty_required = excluded.loyalty_required,
           membership_required = excluded.membership_required, valid_from = excluded.valid_from, valid_to = excluded.valid_to,
           captured_at = excluded.captured_at, evidence_hash = excluded.evidence_hash, updated_at = CURRENT_TIMESTAMP`,
      ).bind(batch.store_location_id, row.product_id, row.observation_id, row.product_version_id, batch.source_id, batch.id,
        row.normalized_name, row.product_name, row.size_text, row.product_url, row.availability_status, row.fulfillment_mode,
        row.seller_name, row.offer_kind, row.package_price_minor, row.normalized_basis_unit, row.normalized_basis_qty_micros,
        row.per_unit_micros, row.loyalty_required, row.membership_required, row.valid_from, row.valid_to, row.captured_at, evidenceHash).run();
      await db.prepare("DELETE FROM catalog_offer_tokens WHERE store_location_id = ?1 AND product_id = ?2").bind(batch.store_location_id, row.product_id).run();
      const tokenStatements = tokens(String(row.normalized_name)).map((token) => db.prepare(
        "INSERT INTO catalog_offer_tokens (store_location_id, token, product_id) VALUES (?1, ?2, ?3) ON CONFLICT DO NOTHING",
      ).bind(batch.store_location_id, token, row.product_id));
      if (tokenStatements.length) await db.batch(tokenStatements);
      offerCount += 1;
      tokenCount += tokenStatements.length;
    }
  }
  return { roots: policies.results.length, offers: offerCount, tokens: tokenCount };
}

export async function readStoreCatalog(db: D1Database, storeLocationId: string): Promise<{ coverageMode: string | null; rootHash: string | null; offers: CatalogCandidate[] }> {
  const root = await db.prepare(
    `SELECT root.coverage_mode, root.root_hash
       FROM capture_source_roots root JOIN store_pricing_policies policy ON policy.source_id = root.source_id
      WHERE policy.store_location_id = ?1`,
  ).bind(storeLocationId).first<{ coverage_mode: string; root_hash: string }>();
  const rows = await db.prepare(
    `SELECT product_id, observation_id, product_name, normalized_name, size_text, product_url,
            availability_status, fulfillment_mode, seller_name, offer_kind, package_price_minor,
            normalized_basis_unit, normalized_basis_qty_micros, per_unit_micros, loyalty_required,
            membership_required, valid_from, valid_to, captured_at, evidence_hash
       FROM catalog_current_offers WHERE store_location_id = ?1 ORDER BY product_id`,
  ).bind(storeLocationId).all<Record<string, unknown>>();
  return {
    coverageMode: root?.coverage_mode ?? null,
    rootHash: root?.root_hash ?? null,
    offers: rows.results.map((row) => ({
      productId: String(row.product_id), observationId: String(row.observation_id), productName: String(row.product_name),
      normalizedName: String(row.normalized_name), sizeText: String(row.size_text), productUrl: row.product_url ? String(row.product_url) : null,
      availabilityStatus: String(row.availability_status), fulfillmentMode: String(row.fulfillment_mode), sellerName: row.seller_name ? String(row.seller_name) : null,
      offerKind: String(row.offer_kind), packagePriceMinor: Number(row.package_price_minor), normalizedBasisUnit: String(row.normalized_basis_unit),
      normalizedBasisQtyMicros: Number(row.normalized_basis_qty_micros), perUnitMicros: Number(row.per_unit_micros),
      loyaltyRequired: Number(row.loyalty_required) === 1, membershipRequired: Number(row.membership_required) === 1,
      validFrom: row.valid_from ? String(row.valid_from) : null, validTo: row.valid_to ? String(row.valid_to) : null,
      capturedAt: String(row.captured_at), evidenceHash: String(row.evidence_hash),
    })),
  };
}
