import { digestHex, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

export type EngineSourceMode = "legacy" | "direct" | "all";
export type EngineSnapshotProfile = "release" | "parity";

export function snapshotIncludesRawCandidates(profile: EngineSnapshotProfile): boolean {
  return profile === "release";
}

function modePredicate(mode: EngineSourceMode): string {
  if (mode === "legacy") return "s.capture_method = 'legacy_bridge'";
  if (mode === "direct") return "s.capture_method <> 'legacy_bridge'";
  return "1 = 1";
}

export async function readEngineSnapshotIdentity(env: WorkerEnv, mode: EngineSourceMode) {
  const configuration = await env.DB.prepare("SELECT id, content_hash FROM configuration_versions WHERE active = 1").first<{ id: string; content_hash: string }>();
  if (!configuration) throw new Error("No active engine configuration");
  const currentRelease = await env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = 'omaha'").first<{ release_id: string }>();
  if (!currentRelease) throw new Error("No current Omaha release");
  const batches = await env.DB.prepare(
    `WITH ranked AS (
       SELECT b.id, b.source_id, b.coverage_mode, b.captured_to, s.capture_method,
              ROW_NUMBER() OVER (PARTITION BY b.source_id ORDER BY b.captured_to DESC, b.promoted_at DESC, b.id DESC) AS ordinal
         FROM capture_batches b JOIN capture_sources s ON s.id = b.source_id
        WHERE b.status = 'promoted' AND ${modePredicate(mode)}
     )
     SELECT id, source_id, coverage_mode, captured_to, capture_method FROM ranked WHERE ordinal = 1 ORDER BY source_id`,
  ).all<{ id: string; source_id: string; coverage_mode: string; captured_to: string; capture_method: string }>();
  if (batches.results.length === 0) throw new Error(`No promoted ${mode} capture batches`);
  const inputBatchIds = batches.results.map((batch) => batch.id).sort();
  const inputHash = await digestHex(stableJson({ configurationId: configuration.id, configurationHash: configuration.content_hash, mode, inputBatchIds }));
  return {
    mode,
    configurationId: configuration.id,
    currentReleaseId: currentRelease.release_id,
    inputHash,
    inputBatchIds,
    batches: batches.results,
  };
}

export async function readEngineSnapshot(env: WorkerEnv, mode: EngineSourceMode, profile: EngineSnapshotProfile = "release") {
  const configuration = await env.DB.prepare("SELECT id, content_hash FROM configuration_versions WHERE active = 1").first<{ id: string; content_hash: string }>();
  if (!configuration) throw new Error("No active engine configuration");
  const currentRelease = await env.DB.prepare("SELECT release_id FROM current_releases WHERE market_id = 'omaha'").first<{ release_id: string }>();
  if (!currentRelease) throw new Error("No current Omaha release");
  const predicate = modePredicate(mode);
  const batches = await env.DB.prepare(
    `WITH ranked AS (
       SELECT b.id, b.source_id, b.coverage_mode, b.captured_to, s.capture_method,
              ROW_NUMBER() OVER (PARTITION BY b.source_id ORDER BY b.captured_to DESC, b.promoted_at DESC, b.id DESC) AS ordinal
         FROM capture_batches b JOIN capture_sources s ON s.id = b.source_id
        WHERE b.status = 'promoted' AND ${predicate}
     )
     SELECT id, source_id, coverage_mode, captured_to, capture_method FROM ranked WHERE ordinal = 1 ORDER BY source_id`,
  ).all<{ id: string; source_id: string; coverage_mode: string; captured_to: string; capture_method: string }>();
  if (batches.results.length === 0) throw new Error(`No promoted ${mode} capture batches`);
  const placeholders = batches.results.map((_, index) => `?${index + 2}`).join(",");
  const rawPlaceholders = batches.results.map((_, index) => `?${index + 1}`).join(",");
  const candidates = await env.DB.prepare(
    `SELECT o.id AS observation_id, m.commodity_id, p.store_location_id, o.per_unit_micros,
            o.captured_at, o.valid_to, b.coverage_mode, b.captured_to, b.id AS batch_id,
            o.normalized_basis_unit, o.normalized_basis_qty_micros, o.purchase_price_minor,
            o.purchase_quantity, o.package_count, pv.size_text,
            o.membership_required, o.loyalty_required, o.raw_price_text, pv.name, pv.product_url,
            pv.taxonomy_path, p.external_key,
            o.basis_options_json,
            CAST(COALESCE(json_extract(s.coverage_policy_json, '$.max_age_days'), 14) AS INTEGER) AS max_age_days,
            EXISTS (
              SELECT 1 FROM known_wrong_rules k
               WHERE k.configuration_id = ?1 AND k.commodity_id = m.commodity_id
                 AND (k.store_location_id IS NULL OR k.store_location_id = p.store_location_id)
                 AND (k.external_product_key = p.external_key OR k.normalized_name = pv.normalized_name)
            ) AS known_wrong
       FROM observations o
       JOIN capture_batches b ON b.id = o.batch_id
       JOIN capture_sources s ON s.id = b.source_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       JOIN match_decisions m ON m.product_id = p.id AND m.configuration_id = ?1 AND m.superseded_at IS NULL
      WHERE o.batch_id IN (${placeholders})
      ORDER BY m.commodity_id, p.store_location_id, o.per_unit_micros, o.id`,
  ).bind(configuration.id, ...batches.results.map((batch) => batch.id)).all();
  const rawCandidates = snapshotIncludesRawCandidates(profile) ? await env.DB.prepare(
    `SELECT o.id AS observation_id, p.store_location_id, o.per_unit_micros, o.captured_at, o.valid_to,
            b.coverage_mode, b.captured_to, b.id AS batch_id, o.normalized_basis_unit,
            o.normalized_basis_qty_micros, o.purchase_price_minor, o.purchase_quantity, o.package_count,
            o.membership_required, o.loyalty_required, o.raw_price_text, pv.name, pv.normalized_name,
            pv.size_text, pv.product_url, pv.taxonomy_path, p.external_key
            , o.basis_options_json
            , CAST(COALESCE(json_extract(s.coverage_policy_json, '$.max_age_days'), 14) AS INTEGER) AS max_age_days
       FROM observations o
       JOIN capture_batches b ON b.id = o.batch_id
       JOIN capture_sources s ON s.id = b.source_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
      WHERE o.batch_id IN (${rawPlaceholders})
      ORDER BY p.store_location_id, o.per_unit_micros, o.id`,
  ).bind(...batches.results.map((batch) => batch.id)).all() : { results: [] };
  const [commodities, stores, currentCells] = await Promise.all([
    env.DB.prepare(
      `SELECT c.id, c.label, c.basis_unit, c.category_id, c.band_min_micros, c.band_max_micros, cat.label AS category_label, cat.sort_order
         FROM commodities c LEFT JOIN categories cat ON cat.id = c.category_id
        WHERE c.configuration_id = ?1 AND c.active = 1 ORDER BY cat.sort_order, c.id`,
    ).bind(configuration.id).all(),
    env.DB.prepare(
      `SELECT l.id, b.name AS store_name, l.display_name, b.membership_required
         FROM store_locations l JOIN store_brands b ON b.id = l.brand_id
        WHERE l.market_id = 'omaha' AND l.active = 1 ORDER BY l.id`,
    ).all(),
    env.DB.prepare(
      `SELECT c.commodity_id, c.store_location_id, c.observation_id, c.status, c.is_crown,
              c.display_per_unit_micros, c.display_unit
         FROM release_cells c WHERE c.release_id = ?1 ORDER BY c.commodity_id, c.store_location_id`,
    ).bind(currentRelease.release_id).all(),
  ]);
  const inputBatchIds = batches.results.map((batch) => batch.id).sort();
  const inputHash = await digestHex(stableJson({ configurationId: configuration.id, configurationHash: configuration.content_hash, mode, inputBatchIds }));
  return {
    ok: true,
    mode,
    observedAt: new Date().toISOString(),
    configurationId: configuration.id,
    currentReleaseId: currentRelease.release_id,
    inputHash,
    inputBatchIds,
    batches: batches.results,
    commodities: commodities.results,
    stores: stores.results,
    candidates: candidates.results,
    rawCandidates: rawCandidates.results,
    currentCells: currentCells.results,
  };
}
