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

interface KnownWrongLookupRule {
  commodity_id: string;
  store_location_id: string | null;
  external_product_key: string | null;
  normalized_name: string | null;
}

export function markKnownWrongCandidates<T extends {
  commodity_id: unknown; store_location_id: unknown; external_key: unknown; normalized_name?: unknown;
}>(candidates: readonly T[], rules: readonly KnownWrongLookupRule[]): Array<T & { known_wrong: number }> {
  const externalKnownWrong = new Set<string>();
  const nameKnownWrong = new Set<string>();
  for (const rule of rules) {
    const scope = rule.store_location_id ?? "*";
    if (rule.external_product_key) externalKnownWrong.add(stableJson([rule.commodity_id, scope, rule.external_product_key]));
    if (rule.normalized_name) nameKnownWrong.add(stableJson([rule.commodity_id, scope, rule.normalized_name]));
  }
  return candidates.map((candidate) => {
    const commodityId = String(candidate.commodity_id);
    const storeLocationId = String(candidate.store_location_id);
    const externalKey = String(candidate.external_key);
    const normalizedName = String(candidate.normalized_name ?? "");
    const scopedKeys = [storeLocationId, "*"];
    const knownWrong = scopedKeys.some((scope) =>
      externalKnownWrong.has(stableJson([commodityId, scope, externalKey]))
      || nameKnownWrong.has(stableJson([commodityId, scope, normalizedName])));
    return { ...candidate, known_wrong: knownWrong ? 1 : 0 };
  });
}

export async function readEngineSnapshotIdentity(env: WorkerEnv, mode: EngineSourceMode) {
  const observedAt = new Date().toISOString();
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
    observedAt,
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
  const candidatesRequest = env.DB.prepare(
    `SELECT o.id AS observation_id, m.commodity_id, p.store_location_id, o.per_unit_micros,
            member.observed_at AS captured_at, o.valid_to, b.coverage_mode, b.captured_to, b.id AS batch_id,
            o.normalized_basis_unit, o.normalized_basis_qty_micros, o.purchase_price_minor, o.regular_price_minor, o.kind,
            o.purchase_quantity, o.package_count, pv.size_text,
            o.membership_required, o.loyalty_required, o.raw_price_text, pv.name, pv.normalized_name, pv.product_url,
            pv.taxonomy_path, p.external_key,
            o.basis_options_json,
            CAST(COALESCE(json_extract(s.coverage_policy_json, '$.max_age_days'), 14) AS INTEGER) AS max_age_days
       FROM capture_batch_observations member
       JOIN observations o ON o.id = member.observation_id
       JOIN capture_batches b ON b.id = member.batch_id
       JOIN capture_sources s ON s.id = b.source_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
       JOIN match_decisions m ON m.product_id = p.id AND m.configuration_id = ?1 AND m.superseded_at IS NULL
      WHERE member.batch_id IN (${placeholders})
      ORDER BY m.commodity_id, p.store_location_id, o.per_unit_micros, o.id`,
  ).bind(configuration.id, ...batches.results.map((batch) => batch.id)).all();
  const rawCandidatesRequest = snapshotIncludesRawCandidates(profile) ? env.DB.prepare(
    `SELECT o.id AS observation_id, p.store_location_id, o.per_unit_micros, member.observed_at AS captured_at, o.valid_to,
            b.coverage_mode, b.captured_to, b.id AS batch_id, o.normalized_basis_unit,
            o.normalized_basis_qty_micros, o.purchase_price_minor, o.regular_price_minor, o.kind,
            o.membership_required, o.loyalty_required, pv.name, pv.size_text, p.external_key,
            o.basis_options_json,
            CAST(COALESCE(json_extract(s.coverage_policy_json, '$.max_age_days'), 14) AS INTEGER) AS max_age_days
       FROM capture_batch_observations member
       JOIN observations o ON o.id = member.observation_id
       JOIN capture_batches b ON b.id = member.batch_id
       JOIN capture_sources s ON s.id = b.source_id
       JOIN product_versions pv ON pv.id = o.product_version_id
       JOIN products p ON p.id = pv.product_id
      WHERE member.batch_id IN (${rawPlaceholders})
      ORDER BY p.store_location_id, o.per_unit_micros, o.id`,
  ).bind(...batches.results.map((batch) => batch.id)).all() : { results: [] };
  const [candidates, rawCandidates, commodities, stores, currentCells, knownWrongRules] = await Promise.all([
    candidatesRequest,
    rawCandidatesRequest,
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
    env.DB.prepare(
      `SELECT commodity_id, store_location_id, external_product_key, normalized_name
         FROM known_wrong_rules WHERE configuration_id = ?1 ORDER BY commodity_id, id`,
    ).bind(configuration.id).all<KnownWrongLookupRule>(),
  ]);
  const markedCandidates = markKnownWrongCandidates(
    candidates.results as Array<Record<string, unknown> & { commodity_id: unknown; store_location_id: unknown; external_key: unknown }>,
    knownWrongRules.results,
  );
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
    candidates: markedCandidates,
    rawCandidates: rawCandidates.results,
    currentCells: currentCells.results,
  };
}
