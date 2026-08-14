export const captureBatchProductsQuery = `WITH ranked AS (
       SELECT p.id AS product_id, p.external_key, p.store_location_id,
              pv.name, pv.normalized_name, pv.taxonomy_path,
              o.normalized_basis_unit, o.normalized_basis_qty_micros,
              decision.commodity_id AS active_commodity_id,
              decision.configuration_id AS active_configuration_id,
              ROW_NUMBER() OVER (PARTITION BY p.id ORDER BY o.captured_at DESC, member.observed_at DESC, o.id DESC) AS ordinal
         FROM capture_batch_observations member
         JOIN observations o ON o.id = member.observation_id
         JOIN product_versions pv ON pv.id = o.product_version_id
         JOIN products p ON p.id = pv.product_id
         LEFT JOIN match_decisions decision ON decision.product_id = p.id AND decision.superseded_at IS NULL
        WHERE member.batch_id = ?1
     )
     SELECT product_id, external_key, store_location_id, name, normalized_name,
            taxonomy_path, normalized_basis_unit, normalized_basis_qty_micros,
            active_commodity_id, active_configuration_id
       FROM ranked WHERE ordinal = 1 ORDER BY product_id`;
