import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

export async function backfillReleaseReasons(env: WorkerEnv, limit = 200): Promise<{ processed: number; remaining: number }> {
  const rows = await env.DB.prepare(
    `SELECT release_id, commodity_id, store_location_id, reason_json
       FROM release_cells WHERE reason_hash IS NULL
      ORDER BY release_id, commodity_id, store_location_id LIMIT ?1`,
  ).bind(limit).all<{ release_id: string; commodity_id: string; store_location_id: string; reason_json: string }>();
  const statements: D1PreparedStatement[] = [];
  for (const row of rows.results) {
    const reason = stableJson(JSON.parse(row.reason_json));
    const hash = await digestHex(reason);
    statements.push(env.DB.prepare(
      `INSERT OR IGNORE INTO release_reason_blobs (content_hash, reason_json, byte_length) VALUES (?1, ?2, ?3)`,
    ).bind(hash, reason, new TextEncoder().encode(reason).byteLength));
    statements.push(env.DB.prepare(
      `UPDATE release_cells SET reason_json = '{}', reason_hash = ?4
        WHERE release_id = ?1 AND commodity_id = ?2 AND store_location_id = ?3 AND reason_hash IS NULL`,
    ).bind(row.release_id, row.commodity_id, row.store_location_id, hash));
  }
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  const remaining = (await env.DB.prepare("SELECT COUNT(*) AS count FROM release_cells WHERE reason_hash IS NULL").first<{ count: number }>())?.count ?? 0;
  return { processed: rows.results.length, remaining };
}

export async function backfillProductEntities(env: WorkerEnv, limit = 200): Promise<{ processed: number; remaining: number }> {
  const rows = await env.DB.prepare(
    `SELECT p.id AS product_id, pv.name, pv.size_text,
            json_extract(pv.identity_json, '$.brand') AS brand,
            json_extract(pv.identity_json, '$.gtin') AS gtin,
            json_extract(pv.identity_json, '$.upc') AS upc
       FROM products p JOIN product_versions pv ON pv.product_id = p.id
      WHERE NOT EXISTS (SELECT 1 FROM product_entity_links link WHERE link.product_id = p.id)
        AND (json_extract(pv.identity_json, '$.gtin') IS NOT NULL OR json_extract(pv.identity_json, '$.upc') IS NOT NULL)
      GROUP BY p.id ORDER BY p.id LIMIT ?1`,
  ).bind(limit).all<{ product_id: string; name: string; size_text: string; brand: string | null; gtin: string | null; upc: string | null }>();
  const statements: D1PreparedStatement[] = [];
  for (const row of rows.results) {
    const value = row.gtin ?? row.upc!;
    const method = row.gtin ? "gtin" : "upc";
    const entityId = await deterministicId("entity", value.padStart(14, "0"));
    statements.push(env.DB.prepare(
      `INSERT INTO product_entities (id, canonical_name, canonical_brand, canonical_size_text, confidence)
       VALUES (?1, ?2, ?3, ?4, 'strong') ON CONFLICT(id) DO UPDATE SET updated_at = CURRENT_TIMESTAMP`,
    ).bind(entityId, row.name, row.brand, row.size_text));
    statements.push(env.DB.prepare(
      `INSERT OR IGNORE INTO product_entity_identifiers (identifier_type, identifier_value, entity_id) VALUES (?1, ?2, ?3)`,
    ).bind(method, value, entityId));
    statements.push(env.DB.prepare(
      `INSERT OR IGNORE INTO product_entity_links (product_id, entity_id, link_method, confidence_millis, evidence_json)
       VALUES (?1, ?2, ?3, 1000, ?4)`,
    ).bind(row.product_id, entityId, method, stableJson({ identifierType: method, identifierValue: value, backfill: true })));
  }
  for (let offset = 0; offset < statements.length; offset += 75) await env.DB.batch(statements.slice(offset, offset + 75));
  const remaining = (await env.DB.prepare(
    `SELECT COUNT(DISTINCT p.id) AS count FROM products p JOIN product_versions pv ON pv.product_id = p.id
      WHERE NOT EXISTS (SELECT 1 FROM product_entity_links link WHERE link.product_id = p.id)
        AND (json_extract(pv.identity_json, '$.gtin') IS NOT NULL OR json_extract(pv.identity_json, '$.upc') IS NOT NULL)`,
  ).first<{ count: number }>())?.count ?? 0;
  return { processed: rows.results.length, remaining };
}

export async function buildProductEntitySuggestions(env: WorkerEnv, limit = 100): Promise<{ created: number }> {
  const rows = await env.DB.prepare(
    `SELECT left_product.id AS left_product_id, right_product.id AS right_product_id,
            left_version.normalized_name, left_version.size_text
       FROM products left_product
       JOIN product_versions left_version ON left_version.product_id = left_product.id
       JOIN product_versions right_version ON right_version.normalized_name = left_version.normalized_name
         AND right_version.size_text = left_version.size_text
       JOIN products right_product ON right_product.id = right_version.product_id
         AND right_product.store_location_id <> left_product.store_location_id
         AND left_product.id < right_product.id
      WHERE NOT EXISTS (SELECT 1 FROM product_entity_links link WHERE link.product_id IN (left_product.id, right_product.id))
        AND NOT EXISTS (SELECT 1 FROM product_entity_suggestions suggestion
          WHERE suggestion.left_product_id = left_product.id AND suggestion.right_product_id = right_product.id)
      GROUP BY left_product.id, right_product.id ORDER BY left_product.id, right_product.id LIMIT ?1`,
  ).bind(limit).all<{ left_product_id: string; right_product_id: string; normalized_name: string; size_text: string }>();
  const statements: D1PreparedStatement[] = [];
  for (const row of rows.results) {
    const id = await deterministicId("entity-suggestion", row.left_product_id, row.right_product_id);
    statements.push(env.DB.prepare(
      `INSERT OR IGNORE INTO product_entity_suggestions
         (id, left_product_id, right_product_id, score_millis, evidence_json)
       VALUES (?1, ?2, ?3, 900, ?4)`,
    ).bind(id, row.left_product_id, row.right_product_id, stableJson({ method: "exact-normalized-name-and-size", normalizedName: row.normalized_name, sizeText: row.size_text })));
  }
  for (let offset = 0; offset < statements.length; offset += 80) await env.DB.batch(statements.slice(offset, offset + 80));
  return { created: rows.results.length };
}
