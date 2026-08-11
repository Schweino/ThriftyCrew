import { digestHex, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

async function pagedRows(env: WorkerEnv, sql: string, configurationId: string): Promise<Array<Record<string, unknown>>> {
  const rows: Array<Record<string, unknown>> = [];
  const pageSize = 5_000;
  for (let offset = 0; ; offset += pageSize) {
    const page = await env.DB.prepare(`${sql} LIMIT ?2 OFFSET ?3`).bind(configurationId, pageSize, offset).all<Record<string, unknown>>();
    rows.push(...page.results);
    if (page.results.length < pageSize) return rows;
  }
}

export async function archiveConfiguration(env: WorkerEnv, configurationId: string): Promise<{ objectKey: string; byteLength: number; sha256: string }> {
  const existing = await env.DB.prepare(
    "SELECT object_key, byte_length, sha256, status FROM configuration_archives WHERE configuration_id = ?1",
  ).bind(configurationId).first<{ object_key: string; byte_length: number; sha256: string; status: string }>();
  if (existing?.status === "verified") {
    try { return await verifyConfigurationArchive(env, configurationId, existing.object_key, existing.byte_length, existing.sha256); }
    catch { /* Rewrite and reverify the source-of-truth snapshot below. */ }
  }
  const configuration = await env.DB.prepare(
    "SELECT id, source_commit, content_hash, expected_categories, expected_commodities, expected_rules, expected_known_wrong FROM configuration_versions WHERE id = ?1",
  ).bind(configurationId).first<Record<string, unknown>>();
  if (!configuration) throw new Error("configuration archive source does not exist");
  const [categories, commodities, rules, knownWrong] = await Promise.all([
    pagedRows(env, "SELECT category.id, category.label, category.sort_order FROM configuration_categories member JOIN categories category ON category.id = member.category_id WHERE member.configuration_id = ?1 ORDER BY category.id", configurationId),
    pagedRows(env, "SELECT id, label, basis_unit, category_id, active, band_min_micros, band_max_micros FROM commodities WHERE configuration_id = ?1 ORDER BY id", configurationId),
    pagedRows(env, `SELECT * FROM (
      SELECT id, commodity_id, kind, pattern, reason, priority FROM match_rules WHERE configuration_id = ?1
      UNION ALL
      SELECT definition.id, definition.commodity_id, definition.kind, definition.pattern, definition.reason, definition.priority
        FROM configuration_match_rules member JOIN match_rule_definitions definition ON definition.id = member.definition_id
       WHERE member.configuration_id = ?1
    ) ORDER BY id`, configurationId),
    pagedRows(env, "SELECT id, commodity_id, store_location_id, external_product_key, normalized_name, ruling, evidence FROM known_wrong_rules WHERE configuration_id = ?1 ORDER BY id", configurationId),
  ]);
  const body = new TextEncoder().encode(stableJson({ schema: "tc-configuration-archive-v1", configuration, categories, commodities, rules, knownWrong }));
  const sha256 = await digestHex(body);
  const objectKey = `configurations/${String(configuration.content_hash)}/${configurationId}.json`;
  await env.ARCHIVE.put(objectKey, body, {
    httpMetadata: { contentType: "application/json" },
    customMetadata: { configurationId, contentHash: String(configuration.content_hash), sha256, schema: "tc-configuration-archive-v1" },
  });
  await verifyConfigurationArchive(env, configurationId, objectKey, body.byteLength, sha256);
  const now = new Date().toISOString();
  await env.DB.prepare(
    `INSERT INTO configuration_archives
       (configuration_id, content_hash, object_key, byte_length, sha256, status, written_at, verified_at, detail_json)
     VALUES (?1, ?2, ?3, ?4, ?5, 'verified', ?6, ?6, ?7)
     ON CONFLICT(configuration_id) DO UPDATE SET
       object_key = excluded.object_key, byte_length = excluded.byte_length, sha256 = excluded.sha256,
       status = excluded.status, written_at = excluded.written_at, verified_at = excluded.verified_at,
       detail_json = excluded.detail_json`,
  ).bind(configurationId, String(configuration.content_hash), objectKey, body.byteLength, sha256, now,
    stableJson({ categories: categories.length, commodities: commodities.length, rules: rules.length, knownWrong: knownWrong.length })).run();
  return { objectKey, byteLength: body.byteLength, sha256 };
}

export async function verifyConfigurationArchive(
  env: WorkerEnv,
  configurationId: string,
  objectKey: string,
  expectedBytes: number,
  expectedSha256: string,
): Promise<{ objectKey: string; byteLength: number; sha256: string }> {
  const object = await env.ARCHIVE.get(objectKey);
  if (!object) throw new Error("configuration archive object is missing");
  const bytes = new Uint8Array(await object.arrayBuffer());
  if (bytes.byteLength !== expectedBytes) throw new Error("configuration archive byte length differs from its manifest");
  const actualSha256 = await digestHex(bytes);
  if (actualSha256 !== expectedSha256) throw new Error("configuration archive hash differs from its manifest");
  const payload = JSON.parse(new TextDecoder().decode(bytes)) as {
    schema?: unknown; configuration?: { id?: unknown; expected_rules?: unknown }; rules?: unknown[];
  };
  if (payload.schema !== "tc-configuration-archive-v1" || payload.configuration?.id !== configurationId || !Array.isArray(payload.rules)) {
    throw new Error("configuration archive rehydration envelope is invalid");
  }
  if (typeof payload.configuration.expected_rules !== "number" || payload.rules.length !== payload.configuration.expected_rules) {
    throw new Error("configuration archive rehydration rule count is incomplete");
  }
  return { objectKey, byteLength: bytes.byteLength, sha256: actualSha256 };
}

export async function compactConfiguration(env: WorkerEnv, configurationId: string, actorId: string): Promise<Record<string, unknown>> {
  const [active, rollback] = await Promise.all([
    env.DB.prepare("SELECT id FROM configuration_versions WHERE active = 1").first<{ id: string }>(),
    env.DB.prepare(
      `SELECT release.configuration_id AS id FROM releases release
        WHERE release.state IN ('published','superseded')
          AND release.configuration_id <> COALESCE((SELECT id FROM configuration_versions WHERE active = 1), '')
        ORDER BY release.published_at DESC LIMIT 1`,
    ).first<{ id: string }>(),
  ]);
  if (configurationId === active?.id || configurationId === rollback?.id) throw new Error("active and immediate rollback configurations cannot be compacted");
  const archive = await env.DB.prepare(
    "SELECT object_key, byte_length, sha256, status FROM configuration_archives WHERE configuration_id = ?1",
  ).bind(configurationId).first<{ object_key: string; byte_length: number; sha256: string; status: string }>();
  if (!archive || archive.status !== "verified") throw new Error("configuration has no verified archive");
  await verifyConfigurationArchive(env, configurationId, archive.object_key, archive.byte_length, archive.sha256);
  const counts = await env.DB.prepare(
    `SELECT (SELECT COUNT(*) FROM match_rules WHERE configuration_id = ?1) AS legacy,
            (SELECT COUNT(*) FROM configuration_match_rules WHERE configuration_id = ?1) AS membership`,
  ).bind(configurationId).first<{ legacy: number; membership: number }>();
  const compactedAt = new Date().toISOString();
  await env.DB.batch([
    env.DB.prepare("DELETE FROM match_rules WHERE configuration_id = ?1").bind(configurationId),
    env.DB.prepare("DELETE FROM configuration_match_rules WHERE configuration_id = ?1").bind(configurationId),
    env.DB.prepare(
      `INSERT INTO configuration_compactions
         (configuration_id, archive_sha256, legacy_rule_rows, membership_rows, compacted_by, compacted_at, detail_json)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
       ON CONFLICT(configuration_id) DO NOTHING`,
    ).bind(configurationId, archive.sha256, counts?.legacy ?? 0, counts?.membership ?? 0, actorId, compactedAt,
      stableJson({ objectKey: archive.object_key, rehydrationVerifiedAt: compactedAt })),
  ]);
  await env.DB.prepare(
    "DELETE FROM match_rule_definitions WHERE NOT EXISTS (SELECT 1 FROM configuration_match_rules member WHERE member.definition_id = match_rule_definitions.id)",
  ).run();
  return { configurationId, archiveSha256: archive.sha256, compactedAt, legacyRuleRows: counts?.legacy ?? 0, membershipRows: counts?.membership ?? 0 };
}
