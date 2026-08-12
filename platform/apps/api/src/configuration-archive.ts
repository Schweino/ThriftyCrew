import { digestHex, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

export interface ArchivedConfigurationPayload {
  schema: "tc-configuration-archive-v1" | "tc-configuration-archive-v2";
  configuration: Record<string, unknown> & { id: string; expected_rules: number };
  categories: Array<Record<string, unknown>>;
  commodities: Array<Record<string, unknown> & { id: string; match_priority?: number }>;
  rules: Array<Record<string, unknown> & { id: string; commodity_id: string; kind: string; pattern: string; reason: string; priority: number }>;
  knownWrong: Array<Record<string, unknown>>;
}

export interface VerifiedConfigurationArchive {
  objectKey: string;
  byteLength: number;
  sha256: string;
  schemaVersion: 1 | 2;
  payload: ArchivedConfigurationPayload;
}

async function keysetRows(env: WorkerEnv, sql: string, configurationId: string): Promise<Array<Record<string, unknown>>> {
  const rows: Array<Record<string, unknown>> = [];
  const pageSize = 5_000;
  let cursor = "";
  for (;;) {
    const page = await env.DB.prepare(`SELECT * FROM (${sql}) page WHERE page.id > ?2 ORDER BY page.id LIMIT ?3`)
      .bind(configurationId, cursor, pageSize).all<Record<string, unknown>>();
    rows.push(...page.results);
    if (page.results.length < pageSize) return rows;
    const next = page.results.at(-1)?.id;
    if (typeof next !== "string" || next <= cursor) throw new Error("configuration archive keyset did not advance");
    cursor = next;
  }
}

export async function archiveConfiguration(env: WorkerEnv, configurationId: string): Promise<{ objectKey: string; byteLength: number; sha256: string; schemaVersion: 2 }> {
  const existing = await env.DB.prepare(
    "SELECT object_key, byte_length, sha256, status FROM configuration_archives WHERE configuration_id = ?1",
  ).bind(configurationId).first<{ object_key: string; byte_length: number; sha256: string; status: string }>();
  if (existing?.status === "verified") {
    try {
      const verified = await verifyConfigurationArchive(env, configurationId, existing.object_key, existing.byte_length, existing.sha256);
      if (verified.schemaVersion === 2) return { objectKey: verified.objectKey, byteLength: verified.byteLength, sha256: verified.sha256, schemaVersion: 2 };
      const compacted = await env.DB.prepare("SELECT configuration_id FROM configuration_compactions WHERE configuration_id = ?1").bind(configurationId).first();
      if (compacted) throw new Error("legacy compacted configuration must be rehydrated before its archive can be upgraded");
    }
    catch (error) {
      const compacted = await env.DB.prepare("SELECT configuration_id FROM configuration_compactions WHERE configuration_id = ?1").bind(configurationId).first();
      if (compacted) throw new Error(`compacted configuration archive failed recovery verification: ${error instanceof Error ? error.message : "unknown verification failure"}`);
      // An uncompacted D1 representation remains authoritative and can safely rewrite the damaged object.
    }
  }
  const configuration = await env.DB.prepare(
    "SELECT id, source_commit, content_hash, expected_categories, expected_commodities, expected_rules, expected_known_wrong FROM configuration_versions WHERE id = ?1",
  ).bind(configurationId).first<Record<string, unknown>>();
  if (!configuration) throw new Error("configuration archive source does not exist");
  const normalized = await env.DB.prepare(
    "SELECT COUNT(*) AS rows FROM configuration_match_rules WHERE configuration_id = ?1",
  ).bind(configurationId).first<{ rows: number }>();
  const ruleSql = (normalized?.rows ?? 0) > 0
    ? `SELECT definition.id, definition.commodity_id, definition.kind, definition.pattern, definition.reason, definition.priority
         FROM configuration_match_rules member JOIN match_rule_definitions definition ON definition.id = member.definition_id
        WHERE member.configuration_id = ?1`
    : "SELECT id, commodity_id, kind, pattern, reason, priority FROM match_rules WHERE configuration_id = ?1";
  const [categories, commodities, rules, knownWrong] = await Promise.all([
    keysetRows(env, "SELECT category.id, category.label, category.sort_order FROM configuration_categories member JOIN categories category ON category.id = member.category_id WHERE member.configuration_id = ?1", configurationId),
    keysetRows(env, "SELECT id, label, basis_unit, category_id, active, band_min_micros, band_max_micros, match_priority FROM commodities WHERE configuration_id = ?1", configurationId),
    keysetRows(env, ruleSql, configurationId),
    keysetRows(env, "SELECT id, commodity_id, store_location_id, external_product_key, normalized_name, ruling, evidence FROM known_wrong_rules WHERE configuration_id = ?1", configurationId),
  ]);
  const body = new TextEncoder().encode(stableJson({ schema: "tc-configuration-archive-v2", configuration, categories, commodities, rules, knownWrong }));
  const sha256 = await digestHex(body);
  const objectKey = `configurations/${String(configuration.content_hash)}/${configurationId}.json`;
  await env.ARCHIVE.put(objectKey, body, {
    httpMetadata: { contentType: "application/json" },
    customMetadata: { configurationId, contentHash: String(configuration.content_hash), sha256, schema: "tc-configuration-archive-v2" },
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
  return { objectKey, byteLength: body.byteLength, sha256, schemaVersion: 2 };
}

export async function verifyConfigurationArchive(
  env: WorkerEnv,
  configurationId: string,
  objectKey: string,
  expectedBytes: number,
  expectedSha256: string,
): Promise<VerifiedConfigurationArchive> {
  const object = await env.ARCHIVE.get(objectKey);
  if (!object) throw new Error("configuration archive object is missing");
  const bytes = new Uint8Array(await object.arrayBuffer());
  if (bytes.byteLength !== expectedBytes) throw new Error("configuration archive byte length differs from its manifest");
  const actualSha256 = await digestHex(bytes);
  if (actualSha256 !== expectedSha256) throw new Error("configuration archive hash differs from its manifest");
  const payload = JSON.parse(new TextDecoder().decode(bytes)) as ArchivedConfigurationPayload;
  const schemaVersion = payload.schema === "tc-configuration-archive-v2" ? 2 : payload.schema === "tc-configuration-archive-v1" ? 1 : 0;
  if (!schemaVersion || payload.configuration?.id !== configurationId || !Array.isArray(payload.rules)
    || !Array.isArray(payload.commodities) || !Array.isArray(payload.categories) || !Array.isArray(payload.knownWrong)) {
    throw new Error("configuration archive rehydration envelope is invalid");
  }
  if (typeof payload.configuration.expected_rules !== "number" || payload.rules.length !== payload.configuration.expected_rules) {
    throw new Error("configuration archive rehydration rule count is incomplete");
  }
  if (schemaVersion === 2 && payload.commodities.some((commodity) => !Number.isInteger(commodity.match_priority) || Number(commodity.match_priority) < 0)) {
    throw new Error("configuration archive v2 is missing commodity match priority");
  }
  return { objectKey, byteLength: bytes.byteLength, sha256: actualSha256, schemaVersion, payload };
}

export async function rehydrateConfiguration(env: WorkerEnv, configurationId: string, actorId: string): Promise<Record<string, unknown>> {
  const compacted = await env.DB.prepare(
    "SELECT archive_sha256 FROM configuration_compactions WHERE configuration_id = ?1",
  ).bind(configurationId).first<{ archive_sha256: string }>();
  if (!compacted) return { configurationId, rehydrated: false, idempotent: true };
  const archive = await env.DB.prepare(
    "SELECT object_key, byte_length, sha256, status FROM configuration_archives WHERE configuration_id = ?1",
  ).bind(configurationId).first<{ object_key: string; byte_length: number; sha256: string; status: string }>();
  if (!archive || archive.status !== "verified" || archive.sha256 !== compacted.archive_sha256) throw new Error("compacted configuration archive identity is unavailable");
  const verified = await verifyConfigurationArchive(env, configurationId, archive.object_key, archive.byte_length, archive.sha256);
  const statements: D1PreparedStatement[] = [];
  for (const rule of verified.payload.rules) {
    statements.push(env.DB.prepare(`
      INSERT INTO match_rule_definitions (id, commodity_id, kind, pattern, reason, priority)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      ON CONFLICT(id) DO UPDATE SET commodity_id = excluded.commodity_id, kind = excluded.kind,
        pattern = excluded.pattern, reason = excluded.reason, priority = excluded.priority
    `).bind(rule.id, rule.commodity_id, rule.kind, rule.pattern, rule.reason, rule.priority));
    statements.push(env.DB.prepare(
      "INSERT OR IGNORE INTO configuration_match_rules (configuration_id, definition_id) VALUES (?1, ?2)",
    ).bind(configurationId, rule.id));
  }
  if (verified.schemaVersion === 2) {
    for (const commodity of verified.payload.commodities) statements.push(env.DB.prepare(
      "UPDATE commodities SET match_priority = ?3 WHERE id = ?1 AND configuration_id = ?2",
    ).bind(commodity.id, configurationId, commodity.match_priority));
  }
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  const counts = await env.DB.prepare(`
    SELECT version.expected_rules,
           (SELECT COUNT(*) FROM configuration_match_rules member WHERE member.configuration_id = version.id) AS rules
      FROM configuration_versions version WHERE version.id = ?1
  `).bind(configurationId).first<{ expected_rules: number; rules: number }>();
  if (!counts || counts.rules !== counts.expected_rules) throw new Error(`configuration rehydration rule count mismatch: expected ${counts?.expected_rules ?? "missing"}, restored ${counts?.rules ?? 0}`);
  await env.DB.prepare("DELETE FROM configuration_compactions WHERE configuration_id = ?1").bind(configurationId).run();
  const upgraded = await archiveConfiguration(env, configurationId);
  return { configurationId, rehydrated: true, idempotent: false, rules: counts.rules, actorId, archive: upgraded };
}

export async function compactConfiguration(env: WorkerEnv, configurationId: string, actorId: string): Promise<Record<string, unknown>> {
  const [active, rollback, capturePipeline] = await Promise.all([
    env.DB.prepare("SELECT id FROM configuration_versions WHERE active = 1").first<{ id: string }>(),
    env.DB.prepare(
      `SELECT release.configuration_id AS id FROM releases release
        WHERE release.state IN ('published','superseded')
          AND release.configuration_id <> COALESCE((SELECT id FROM configuration_versions WHERE active = 1), '')
        ORDER BY release.published_at DESC LIMIT 1`,
    ).first<{ id: string }>(),
    env.DB.prepare(
      `SELECT batch_id FROM capture_validation_jobs
        WHERE configuration_id = ?1 AND pipeline_completed_at IS NULL LIMIT 1`,
    ).bind(configurationId).first<{ batch_id: string }>(),
  ]);
  if (configurationId === active?.id || configurationId === rollback?.id) throw new Error("active and immediate rollback configurations cannot be compacted");
  if (capturePipeline) throw new Error(`configuration is pinned by incomplete capture pipeline ${capturePipeline.batch_id}`);
  const currentArchive = await archiveConfiguration(env, configurationId);
  if (currentArchive.schemaVersion !== 2) throw new Error("configuration archive v2 is required before compaction");
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
