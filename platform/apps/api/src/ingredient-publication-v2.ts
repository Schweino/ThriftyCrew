import { ingredientPublicationBatchCreateSchema, ingredientPublicationVerifySchema, ingredientResolutionProposalSchema, observationInputSchema, type ObservationInput } from "@thriftycrew/contracts";
import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import type { z } from "zod";
import type { WorkerEnv } from "./env";
import { findBatch, insertObservations } from "./database";

const INGREDIENT_TARGETED_SOURCES: Record<string, string> = {
  "aldi-omaha-446-048": "ingredient-targeted-aldi",
  "bakers-saddle-creek": "ingredient-targeted-bakers",
  "family-fare-omaha-6401": "ingredient-targeted-family-fare",
  "fareway-omaha-043": "ingredient-targeted-fareway",
  "hy-vee-omaha-1465": "ingredient-targeted-hy-vee",
  "sams-omaha": "ingredient-targeted-sams",
  "walmart-omaha": "ingredient-targeted-walmart",
};

interface PricedStoreResult {
  checkedAt: string;
  sourceUrl: string;
  productName: string;
  packageText: string;
  packagePriceMinor: number;
  normalizedBasisUnit: ObservationInput["normalizedBasisUnit"];
  normalizedBasisQtyMicros: number;
  perUnitMicros: number;
  validFrom: string | null;
  validTo: string | null;
  offerKind: "sale" | "everyday" | "markdown" | "member" | null;
  availabilityText: string | null;
  fulfillmentMode: string | null;
  sellerName: string | null;
  loyaltyRequired: boolean;
  membershipRequired: boolean;
}

export async function ingredientPublicationObservation(storeLocationId: string, commodityId: string, result: PricedStoreResult): Promise<ObservationInput> {
  const externalProductKey = await deterministicId("ingredient-targeted-product", storeLocationId, result.sourceUrl, result.productName);
  const kind = result.offerKind === "sale" || result.offerKind === "markdown" || result.offerKind === "member" ? result.offerKind : "everyday";
  const fulfillmentMode = result.fulfillmentMode === "pickup" || result.fulfillmentMode === "delivery"
    || result.fulfillmentMode === "shipping" || result.fulfillmentMode === "in_store" ? result.fulfillmentMode : "unknown";
  const rawPriceText = `$${(result.packagePriceMinor / 100).toFixed(2)}`;
  return observationInputSchema.parse({
    externalProductKey,
    name: result.productName,
    sizeText: result.packageText,
    productUrl: result.sourceUrl,
    taxonomyPath: "Grocery",
    package: { source: "ingredient-independent-qa", commodityId },
    termKey: commodityId,
    kind,
    currency: "USD",
    purchasePriceMinor: result.packagePriceMinor,
    ...(kind === "everyday" ? { regularPriceMinor: result.packagePriceMinor } : {}),
    purchaseQuantity: 1,
    packageCount: 1,
    capturedBasisUnit: result.normalizedBasisUnit,
    capturedBasisQtyMicros: result.normalizedBasisQtyMicros,
    normalizedBasisUnit: result.normalizedBasisUnit,
    normalizedBasisQtyMicros: result.normalizedBasisQtyMicros,
    perUnitMicros: result.perUnitMicros,
    loyaltyRequired: result.loyaltyRequired,
    membershipRequired: result.membershipRequired,
    rawPriceText,
    rawSizeText: result.packageText,
    capturedAt: result.checkedAt,
    ...(result.validFrom ? { validFrom: result.validFrom } : {}),
    ...(result.validTo ? { validTo: result.validTo } : {}),
    offerSnapshot: {
      version: 1,
      retailerProductId: externalProductKey,
      productName: result.productName,
      sizeText: result.packageText,
      rawPriceText,
      purchasePriceMinor: result.packagePriceMinor,
      sellerName: result.sellerName ?? undefined,
      availability: {
        status: "in_stock",
        rawText: result.availabilityText ?? undefined,
        fulfillmentMode,
        locationId: storeLocationId,
        eligible: true,
      },
      priceSemantics: {
        offerType: kind,
        condition: result.loyaltyRequired ? "loyalty" : result.membershipRequired ? "membership" : "none",
        unitPriceMinor: result.packagePriceMinor,
        qualifyingQuantity: 1,
        totalPriceMinor: result.packagePriceMinor,
        ambiguity: false,
        ...(result.validFrom ? { validFrom: result.validFrom } : {}),
        ...(result.validTo ? { validTo: result.validTo } : {}),
      },
      observedAt: result.checkedAt,
      sourceUrl: result.sourceUrl,
    },
  });
}

export async function attachIngredientProposal(db: D1Database, inputValue: unknown) {
  const input = ingredientResolutionProposalSchema.parse(inputValue);
  const proposalJson = stableJson(input.proposal);
  const proposalHash = await digestHex(proposalJson);
  const updated = await db.prepare(
    `UPDATE ingredient_pricing_jobs SET commodity_proposal_json = ?2, commodity_proposal_hash = ?3, updated_at = CURRENT_TIMESTAMP
      WHERE id = ?1 AND state = 'ready_to_publish' AND resolution_version_id IS NOT NULL`,
  ).bind(input.pricingJobId, proposalJson, proposalHash).run();
  if ((updated.meta.changes ?? 0) !== 1) throw new Error("proposal target is not a sealed available ingredient resolution");
  await db.prepare(
    `UPDATE ingredient_resolution_versions SET commodity_proposal_hash = ?2
      WHERE id = (SELECT resolution_version_id FROM ingredient_pricing_jobs WHERE id = ?1)`,
  ).bind(input.pricingJobId, proposalHash).run();
  return { pricingJobId: input.pricingJobId, proposalHash, plannerVersion: input.plannerVersion };
}

export async function createIngredientPublicationBatch(db: D1Database, inputValue: unknown) {
  const input = ingredientPublicationBatchCreateSchema.parse(inputValue);
  const gapIds = [...new Set(input.gapIds)].sort();
  const rows = await db.prepare(
    `SELECT job.id AS job_id, job.gap_id, job.resolution_version_id, job.commodity_proposal_json,
            job.commodity_proposal_hash, resolution.evidence_root_hash
       FROM ingredient_pricing_jobs job
       JOIN ingredient_resolution_versions resolution ON resolution.id = job.resolution_version_id
      WHERE job.gap_id IN (${gapIds.map(() => "?").join(",")}) AND job.state = 'ready_to_publish'
        AND job.commodity_proposal_json IS NOT NULL ORDER BY job.gap_id`,
  ).bind(...gapIds).all<Record<string, unknown>>();
  if (rows.results.length !== gapIds.length) throw new Error("every publication member requires a sealed available resolution and reviewed commodity proposal");
  const members = [];
  for (const row of rows.results) {
    const proposal = JSON.parse(String(row.commodity_proposal_json)) as { id: string };
    const checks = await db.prepare(`SELECT store_location_id, result_json FROM ingredient_store_checks
      WHERE pricing_job_id = ?1 AND state = 'qa_verified_priced' ORDER BY store_location_id`).bind(row.job_id).all<{ store_location_id: string; result_json: string }>();
    const stores = checks.results.map((check) => {
      const result = JSON.parse(check.result_json) as { perUnitMicros: number; normalizedBasisUnit: string; validFrom: string | null; validTo: string | null };
      return { storeLocationId: check.store_location_id, perUnitMicros: result.perUnitMicros,
        unit: result.normalizedBasisUnit, validFrom: result.validFrom, validTo: result.validTo };
    });
    if (stores.length < 1) throw new Error(`publication member ${String(row.gap_id)} has no QA-verified price`);
    const cheapest = [...stores].sort((left, right) => left.perUnitMicros - right.perUnitMicros || left.storeLocationId.localeCompare(right.storeLocationId))[0]!;
    const expectedPublicProjection = { id: proposal.id, cheapest: { storeLocationId: cheapest.storeLocationId, perUnitMicros: cheapest.perUnitMicros }, stores };
    members.push({ gapId: row.gap_id, resolutionVersionId: row.resolution_version_id, commodityId: proposal.id,
      proposal, proposalHash: row.commodity_proposal_hash, evidenceRootHash: row.evidence_root_hash,
      expectedPublicProjection, expectedPublicProjectionHash: await digestHex(stableJson(expectedPublicProjection)) });
  }
  const memberRootHash = await digestHex(stableJson(members));
  const batchId = await deterministicId("ingredient-publication-batch", "omaha", memberRootHash);
  const statements: D1PreparedStatement[] = [db.prepare(
    `INSERT INTO ingredient_publication_batches (id, market_id, member_root_hash, source_commit, state)
     VALUES (?1, 'omaha', ?2, ?3, 'sealed') ON CONFLICT(id) DO NOTHING`,
  ).bind(batchId, memberRootHash, input.sourceCommit)];
  for (const member of members) statements.push(db.prepare(
    `INSERT INTO ingredient_publication_members (batch_id, gap_id, resolution_version_id, commodity_id, content_hash,
       expected_public_projection_json, expected_public_projection_hash)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7) ON CONFLICT(batch_id, gap_id) DO NOTHING`,
  ).bind(batchId, member.gapId, member.resolutionVersionId, member.commodityId, member.proposalHash,
    stableJson(member.expectedPublicProjection), member.expectedPublicProjectionHash));
  statements.push(db.prepare(`INSERT INTO ingredient_publication_transition_receipts
    (id, batch_id, from_state, to_state, actor, detail_json) VALUES (?1, ?2, 'open', 'sealed', 'api', ?3)
    ON CONFLICT(batch_id, from_state, to_state, actor) DO NOTHING`).bind(`receipt_${batchId}_sealed`, batchId, stableJson({ memberRootHash, members: members.length })));
  await db.batch(statements);
  return { batchId, memberRootHash, members };
}

export async function materializeIngredientPublicationCaptures(db: D1Database, batchId: string) {
  const publication = await db.prepare("SELECT state, member_root_hash FROM ingredient_publication_batches WHERE id = ?1")
    .bind(batchId).first<{ state: string; member_root_hash: string }>();
  if (!publication || !["sealed", "release_built", "validated"].includes(publication.state)) {
    throw new Error("ingredient publication batch is not sealed for capture materialization");
  }
  const rows = await db.prepare(
    `SELECT member.commodity_id, store_check.store_location_id, store_check.result_json
       FROM ingredient_publication_members member
       JOIN ingredient_pricing_jobs job ON job.gap_id = member.gap_id
       JOIN ingredient_store_checks store_check ON store_check.pricing_job_id = job.id
      WHERE member.batch_id = ?1 AND store_check.state = 'qa_verified_priced'
      ORDER BY store_check.store_location_id, member.commodity_id`,
  ).bind(batchId).all<{ commodity_id: string; store_location_id: string; result_json: string }>();
  if (rows.results.length < 1) throw new Error("ingredient publication batch has no QA-verified prices to materialize");
  const grouped = new Map<string, typeof rows.results>();
  for (const row of rows.results) {
    const values = grouped.get(row.store_location_id) ?? [];
    values.push(row);
    grouped.set(row.store_location_id, values);
  }
  const activeConfiguration = await db.prepare("SELECT id FROM configuration_versions WHERE active = 1").first<{ id: string }>();
  if (!activeConfiguration) throw new Error("ingredient publication materialization requires an active configuration");
  const materialized = [];
  for (const [storeLocationId, storeRows] of grouped) {
    const sourceId = INGREDIENT_TARGETED_SOURCES[storeLocationId];
    if (!sourceId) throw new Error(`ingredient publication has no targeted source for ${storeLocationId}`);
    const source = await db.prepare("SELECT capture_method, price_mode FROM capture_sources WHERE id = ?1 AND store_location_id = ?2 AND active = 1")
      .bind(sourceId, storeLocationId).first<{ capture_method: string; price_mode: string }>();
    if (!source) throw new Error(`ingredient targeted source ${sourceId} is not active`);
    const captureBatchId = await deterministicId("ingredient-publication-capture", batchId, storeLocationId);
    const existing = await db.prepare("SELECT status FROM capture_batches WHERE id = ?1").bind(captureBatchId).first<{ status: string }>();
    if (existing && existing.status !== "open") {
      materialized.push({ batchId: captureBatchId, sourceId, storeLocationId, status: existing.status, idempotent: true });
      continue;
    }
    const parsedRows = storeRows.map((row) => ({ ...row, result: JSON.parse(row.result_json) as PricedStoreResult }));
    if (parsedRows.some((row) => !row.result.checkedAt || !row.result.productName || !row.result.sourceUrl
      || !Number.isInteger(row.result.packagePriceMinor) || !Number.isInteger(row.result.normalizedBasisQtyMicros)
      || !Number.isInteger(row.result.perUnitMicros))) throw new Error(`ingredient publication ${storeLocationId} result is incomplete`);
    const capturedFrom = parsedRows.map((row) => row.result.checkedAt).sort()[0]!;
    const capturedTo = parsedRows.map((row) => row.result.checkedAt).sort().at(-1)!;
    const prior = await db.prepare(
      `SELECT id, coverage_mode FROM capture_batches
        WHERE source_id = ?1 AND status IN ('promoted','superseded')
        ORDER BY captured_to DESC, promoted_at DESC, id DESC LIMIT 1`,
    ).bind(sourceId).first<{ id: string; coverage_mode: string }>();
    if (!existing) await db.prepare(
      `INSERT INTO capture_batches
         (id, source_id, coverage_mode, status, captured_from, captured_to, expected_terms, attempted_terms,
          successful_terms, empty_terms, rejected_terms, blocked_terms, market_verified, location_verified,
          price_mode_verified, price_mode, agent_id, idempotency_key, validation_summary_json, sealed_at)
       VALUES (?1, ?2, 'targeted', 'open', ?3, ?4, ?5, ?5, ?5, 0, 0, 0, 1, 1, 1, ?6,
          'ingredient-publication-materializer', ?7, '{}', CURRENT_TIMESTAMP)`,
    ).bind(captureBatchId, sourceId, capturedFrom, capturedTo, parsedRows.length, source.price_mode, `${batchId}:${storeLocationId}`).run();
    const batch = await findBatch(db, captureBatchId);
    if (!batch) throw new Error(`ingredient publication capture ${captureBatchId} was not created`);
    const observations = await Promise.all(parsedRows.map((row) => ingredientPublicationObservation(storeLocationId, row.commodity_id, row.result)));
    const inserted = await insertObservations(db, batch, observations);
    const refreshedCommodityIds = parsedRows.map((row) => row.commodity_id);
    if (prior) {
      await db.prepare(
        `INSERT OR IGNORE INTO capture_observation_memberships
           (batch_id, observation_id, term_key, observed_at, source_payload_key, evidence_object_id, provenance_json, carried)
         SELECT ?1, membership.observation_id, membership.term_key, membership.observed_at,
                membership.source_payload_key, membership.evidence_object_id, membership.provenance_json, 1
           FROM capture_observation_memberships membership
           JOIN observations observation ON observation.id = membership.observation_id
           JOIN product_versions version ON version.id = observation.product_version_id
           JOIN products product ON product.id = version.product_id
           LEFT JOIN match_decisions decision ON decision.product_id = product.id
            AND decision.configuration_id = ?3 AND decision.superseded_at IS NULL
          WHERE membership.batch_id = ?2
            AND (decision.commodity_id IS NULL OR decision.commodity_id NOT IN (SELECT value FROM json_each(?4)))`,
      ).bind(captureBatchId, prior.id, activeConfiguration.id, stableJson(refreshedCommodityIds)).run();
    }
    const membershipCount = await db.prepare("SELECT COUNT(DISTINCT observation_id) AS count FROM capture_observation_memberships WHERE batch_id = ?1")
      .bind(captureBatchId).first<{ count: number }>();
    const summary = {
      version: 1,
      materializer: "ingredient-publication-v1",
      publicationBatchId: batchId,
      memberRootHash: publication.member_root_hash,
      sourceId,
      priorBatchId: prior?.id ?? null,
      insertedObservations: inserted.accepted,
      carriedObservations: Math.max(0, Number(membershipCount?.count ?? 0) - inserted.ids.length),
      refreshedCommodityIds,
    };
    await db.prepare(
      `UPDATE capture_batches SET status = 'validated', validation_summary_json = ?2, sealed_at = CURRENT_TIMESTAMP
        WHERE id = ?1 AND status = 'open'`,
    ).bind(captureBatchId, stableJson(summary)).run();
    materialized.push({ batchId: captureBatchId, storeLocationId, status: "validated", idempotent: false, ...summary });
  }
  return { publicationBatchId: batchId, batches: materialized };
}

async function fetchProof(origin: string, commodityId: string, releaseId: string, expectedHash: string) {
  const proofUrl = new URL(`/api/v2/board/${encodeURIComponent(commodityId)}`, origin);
  proofUrl.searchParams.set("release", releaseId);
  const url = proofUrl.toString();
  const response = await fetch(url, { headers: { accept: "application/json", "cache-control": "no-cache" } });
  const body = await response.text();
  let responseReleaseId: string | null = null;
  let observedHash = await digestHex("");
  try {
    const parsed = JSON.parse(body) as { releaseId?: unknown; commodity?: { id?: unknown; cheapest?: { storeLocationId?: unknown; perUnitMicros?: unknown }; stores?: Array<Record<string, unknown>> } };
    responseReleaseId = String(parsed.releaseId ?? "") || null;
    const stores = (parsed.commodity?.stores ?? []).map((store) => ({ storeLocationId: String(store.storeLocationId), perUnitMicros: Number(store.perUnitMicros),
      unit: String(store.unit), validFrom: store.validFrom === null || store.validFrom === undefined ? null : String(store.validFrom),
      validTo: store.validTo === null || store.validTo === undefined ? null : String(store.validTo) })).sort((left, right) => left.storeLocationId.localeCompare(right.storeLocationId));
    const projection = { id: String(parsed.commodity?.id), cheapest: parsed.commodity?.cheapest ? {
      storeLocationId: String(parsed.commodity.cheapest.storeLocationId), perUnitMicros: Number(parsed.commodity.cheapest.perUnitMicros),
    } : null, stores };
    observedHash = await digestHex(stableJson(projection));
  } catch { /* invalid JSON fails verification */ }
  return { url, status: response.status, etag: response.headers.get("etag"), responseReleaseId, observedHash,
    verified: response.ok && responseReleaseId === releaseId && observedHash === expectedHash };
}

function publicProjection(commodity: Record<string, unknown>): Record<string, unknown> {
  const cheapest = commodity.cheapest && typeof commodity.cheapest === "object" && !Array.isArray(commodity.cheapest)
    ? commodity.cheapest as Record<string, unknown> : null;
  const stores = (Array.isArray(commodity.stores) ? commodity.stores : []).map((value) => {
    const store = value as Record<string, unknown>;
    return { storeLocationId: String(store.storeLocationId), perUnitMicros: Number(store.perUnitMicros), unit: String(store.unit),
      validFrom: store.validFrom === null || store.validFrom === undefined ? null : String(store.validFrom),
      validTo: store.validTo === null || store.validTo === undefined ? null : String(store.validTo) };
  }).sort((left, right) => left.storeLocationId.localeCompare(right.storeLocationId));
  return { id: String(commodity.id), cheapest: cheapest ? { storeLocationId: String(cheapest.storeLocationId), perUnitMicros: Number(cheapest.perUnitMicros) } : null, stores };
}

export async function verifyIngredientPublicationCandidate(env: Pick<WorkerEnv, "DB" | "EVIDENCE">, batchId: string, releaseId: string) {
  const release = await env.DB.prepare("SELECT state FROM releases WHERE id = ?1").bind(releaseId).first<{ state: string }>();
  if (!release || release.state !== "validated") throw new Error("ingredient publication candidate must be a validated unpublished release");
  const payloadRow = await env.DB.prepare("SELECT payload_json, object_key FROM release_payloads WHERE release_id = ?1 AND kind = 'board'")
    .bind(releaseId).first<{ payload_json: string; object_key: string | null }>();
  if (!payloadRow) throw new Error("validated release has no board payload");
  const payload = payloadRow.object_key ? await env.EVIDENCE.get(payloadRow.object_key).then((object) => object?.json()) : JSON.parse(payloadRow.payload_json);
  const commodities = (payload && typeof payload === "object" && !Array.isArray(payload) && Array.isArray((payload as { commodities?: unknown }).commodities))
    ? (payload as { commodities: Array<Record<string, unknown>> }).commodities : [];
  const byId = new Map(commodities.map((commodity) => [String(commodity.id), commodity]));
  const members = await env.DB.prepare("SELECT commodity_id, expected_public_projection_hash FROM ingredient_publication_members WHERE batch_id = ?1 ORDER BY gap_id")
    .bind(batchId).all<{ commodity_id: string; expected_public_projection_hash: string }>();
  const checks = [];
  for (const member of members.results) {
    const commodity = byId.get(member.commodity_id);
    const observedHash = commodity ? await digestHex(stableJson(publicProjection(commodity))) : null;
    checks.push({ commodityId: member.commodity_id, expectedHash: member.expected_public_projection_hash, observedHash,
      verified: observedHash === member.expected_public_projection_hash });
  }
  const verified = checks.length > 0 && checks.every((check) => check.verified);
  if (!verified) throw new Error("validated release board does not exactly match every sealed ingredient projection");
  const receiptId = await deterministicId("ingredient-publication-receipt", batchId, "sealed", "validated", releaseId);
  await env.DB.batch([
    env.DB.prepare("UPDATE ingredient_publication_batches SET state = 'validated', release_id = ?2, updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND state IN ('sealed','release_built','validated')").bind(batchId, releaseId),
    env.DB.prepare(`INSERT INTO ingredient_publication_transition_receipts
      (id, batch_id, from_state, to_state, actor, detail_json) VALUES (?1, ?2, 'sealed', 'validated', 'prepublish-verifier', ?3)
      ON CONFLICT(batch_id, from_state, to_state, actor) DO NOTHING`).bind(receiptId, batchId, stableJson({ releaseId, checks })),
  ]);
  return { batchId, releaseId, verified, checks };
}

export async function verifyIngredientPublication(env: Pick<WorkerEnv, "DB" | "PUBLIC_ORIGIN" | "GHOST_PUBLIC_ORIGIN">, batchId: string, inputValue: unknown) {
  const input: z.infer<typeof ingredientPublicationVerifySchema> = ingredientPublicationVerifySchema.parse(inputValue);
  if (!env.GHOST_PUBLIC_ORIGIN) throw new Error("Ghost public origin is required for dual-origin verification");
  const batch = await env.DB.prepare("SELECT state, member_root_hash FROM ingredient_publication_batches WHERE id = ?1").bind(batchId).first<{ state: string; member_root_hash: string }>();
  if (!batch || !["sealed", "validated", "pointer_published", "edge_verified"].includes(batch.state)) throw new Error("publication batch is not awaiting public verification");
  const members = await env.DB.prepare("SELECT gap_id, commodity_id, expected_public_projection_hash FROM ingredient_publication_members WHERE batch_id = ?1 ORDER BY gap_id")
    .bind(batchId).all<{ gap_id: string; commodity_id: string; expected_public_projection_hash: string }>();
  const statements: D1PreparedStatement[] = [];
  const proofs = [];
  const verifiedMembers: typeof members.results = [];
  for (const member of members.results) {
    const origins = [["worker", env.PUBLIC_ORIGIN], ["custom_domain", env.GHOST_PUBLIC_ORIGIN]] as const;
    let memberVerified = true;
    for (const [originKind, origin] of origins) {
      const proof = await fetchProof(origin, member.commodity_id, input.releaseId, member.expected_public_projection_hash);
      memberVerified &&= proof.verified;
      const proofId = await deterministicId("ingredient-public-proof", batchId, member.gap_id, originKind, proof.url, proof.observedHash);
      statements.push(env.DB.prepare(
        `INSERT INTO public_verification_proofs
           (id, publication_batch_id, release_id, origin_kind, url, expected_hash, observed_hash, response_status,
            etag, response_release_id, verified, checked_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, CURRENT_TIMESTAMP)
         ON CONFLICT(publication_batch_id, origin_kind, url, observed_hash) DO NOTHING`,
      ).bind(proofId, batchId, input.releaseId, originKind, proof.url, member.expected_public_projection_hash, proof.observedHash,
        proof.status, proof.etag, proof.responseReleaseId, proof.verified ? 1 : 0));
      proofs.push({ gapId: member.gap_id, originKind, ...proof });
    }
    if (memberVerified) verifiedMembers.push(member);
  }
  const allVerified = verifiedMembers.length === members.results.length && members.results.length > 0;
  if (allVerified) for (const member of verifiedMembers) {
    statements.push(env.DB.prepare("UPDATE ingredient_publication_members SET state = 'public_verified', updated_at = CURRENT_TIMESTAMP WHERE batch_id = ?1 AND gap_id = ?2").bind(batchId, member.gap_id));
    statements.push(env.DB.prepare("UPDATE ingredient_gaps SET status = 'published', published_commodity_id = ?2, updated_at = CURRENT_TIMESTAMP WHERE id = ?1 AND status = 'ready_to_publish'").bind(member.gap_id, member.commodity_id));
    statements.push(env.DB.prepare("UPDATE ingredient_pricing_jobs SET state = 'public_verified', operational_state = 'public_verified', terminal_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP WHERE gap_id = ?1 AND state = 'ready_to_publish'").bind(member.gap_id));
    statements.push(env.DB.prepare("UPDATE recipe_hold_requirements SET terminal_kind = 'available', satisfied_at = CURRENT_TIMESTAMP WHERE gap_id = ?1 AND terminal_kind IS NULL").bind(member.gap_id));
    statements.push(env.DB.prepare("DELETE FROM ingredient_pricing_inbox WHERE gap_id = ?1").bind(member.gap_id));
  }
  if (statements.length) for (let offset = 0; offset < statements.length; offset += 90) await env.DB.batch(statements.slice(offset, offset + 90));
  const remaining = await env.DB.prepare("SELECT COUNT(*) AS count FROM ingredient_publication_members WHERE batch_id = ?1 AND state != 'public_verified'").bind(batchId).first<{ count: number }>();
  const complete = allVerified && Number(remaining?.count ?? 0) === 0;
  await env.DB.prepare(`UPDATE ingredient_publication_batches SET state = ?2, release_id = ?3,
      completed_at = CASE WHEN ?2 = 'completed' THEN CURRENT_TIMESTAMP ELSE completed_at END, updated_at = CURRENT_TIMESTAMP WHERE id = ?1`)
    .bind(batchId, complete ? "completed" : "edge_verified", input.releaseId).run();
  if (complete) {
    const receiptId = await deterministicId("ingredient-publication-receipt", batchId, "pointer_published", "completed", input.releaseId);
    await env.DB.prepare(`INSERT INTO ingredient_publication_transition_receipts
      (id, batch_id, from_state, to_state, actor, detail_json) VALUES (?1, ?2, 'pointer_published', 'completed', 'dual-origin-verifier', ?3)
      ON CONFLICT(batch_id, from_state, to_state, actor) DO NOTHING`).bind(receiptId, batchId, stableJson({ releaseId: input.releaseId, proofs })).run();
  }
  return { batchId, releaseId: input.releaseId, complete, proofs };
}
