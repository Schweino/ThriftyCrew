import { ingredientPublicationBatchCreateSchema, ingredientPublicationVerifySchema, ingredientResolutionProposalSchema } from "@thriftycrew/contracts";
import { deterministicId, digestHex, stableJson } from "@thriftycrew/domain";
import type { z } from "zod";
import type { WorkerEnv } from "./env";

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
  const members = rows.results.map((row) => ({ gapId: row.gap_id, resolutionVersionId: row.resolution_version_id,
    commodityId: (JSON.parse(String(row.commodity_proposal_json)) as { id: string }).id,
    proposal: JSON.parse(String(row.commodity_proposal_json)),
    proposalHash: row.commodity_proposal_hash, evidenceRootHash: row.evidence_root_hash }));
  const memberRootHash = await digestHex(stableJson(members));
  const batchId = await deterministicId("ingredient-publication-batch", "omaha", memberRootHash);
  const statements: D1PreparedStatement[] = [db.prepare(
    `INSERT INTO ingredient_publication_batches (id, market_id, member_root_hash, source_commit, state)
     VALUES (?1, 'omaha', ?2, ?3, 'sealed') ON CONFLICT(id) DO NOTHING`,
  ).bind(batchId, memberRootHash, input.sourceCommit)];
  for (const member of members) statements.push(db.prepare(
    `INSERT INTO ingredient_publication_members (batch_id, gap_id, resolution_version_id, commodity_id, content_hash)
     VALUES (?1, ?2, ?3, ?4, ?5) ON CONFLICT(batch_id, gap_id) DO NOTHING`,
  ).bind(batchId, member.gapId, member.resolutionVersionId, member.commodityId, member.proposalHash));
  await db.batch(statements);
  return { batchId, memberRootHash, members };
}

async function fetchProof(origin: string, commodityId: string, releaseId: string) {
  const url = new URL(`/api/v2/board/${encodeURIComponent(commodityId)}`, origin).toString();
  const response = await fetch(url, { headers: { accept: "application/json", "cache-control": "no-cache" } });
  const body = await response.text();
  let responseReleaseId: string | null = null;
  try { responseReleaseId = String((JSON.parse(body) as { releaseId?: unknown }).releaseId ?? "") || null; } catch { /* invalid JSON fails verification */ }
  const observedHash = await digestHex(body);
  return { url, status: response.status, etag: response.headers.get("etag"), responseReleaseId, observedHash,
    verified: response.ok && responseReleaseId === releaseId };
}

export async function verifyIngredientPublication(env: Pick<WorkerEnv, "DB" | "PUBLIC_ORIGIN" | "GHOST_PUBLIC_ORIGIN">, batchId: string, inputValue: unknown) {
  const input: z.infer<typeof ingredientPublicationVerifySchema> = ingredientPublicationVerifySchema.parse(inputValue);
  if (!env.GHOST_PUBLIC_ORIGIN) throw new Error("Ghost public origin is required for dual-origin verification");
  const batch = await env.DB.prepare("SELECT state, member_root_hash FROM ingredient_publication_batches WHERE id = ?1").bind(batchId).first<{ state: string; member_root_hash: string }>();
  if (!batch || !["sealed", "pointer_published", "edge_verified"].includes(batch.state)) throw new Error("publication batch is not awaiting public verification");
  const members = await env.DB.prepare("SELECT gap_id, commodity_id FROM ingredient_publication_members WHERE batch_id = ?1 ORDER BY gap_id").bind(batchId).all<{ gap_id: string; commodity_id: string }>();
  const statements: D1PreparedStatement[] = [];
  const proofs = [];
  for (const member of members.results) {
    const origins = [["worker", env.PUBLIC_ORIGIN], ["custom_domain", env.GHOST_PUBLIC_ORIGIN]] as const;
    let memberVerified = true;
    for (const [originKind, origin] of origins) {
      const proof = await fetchProof(origin, member.commodity_id, input.releaseId);
      memberVerified &&= proof.verified;
      const proofId = await deterministicId("ingredient-public-proof", batchId, member.gap_id, originKind, proof.observedHash);
      statements.push(env.DB.prepare(
        `INSERT INTO public_verification_proofs
           (id, publication_batch_id, release_id, origin_kind, url, expected_hash, observed_hash, response_status,
            etag, response_release_id, verified, checked_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, CURRENT_TIMESTAMP)
         ON CONFLICT(publication_batch_id, origin_kind, url, observed_hash) DO NOTHING`,
      ).bind(proofId, batchId, input.releaseId, originKind, proof.url, batch.member_root_hash, proof.observedHash,
        proof.status, proof.etag, proof.responseReleaseId, proof.verified ? 1 : 0));
      proofs.push({ gapId: member.gap_id, originKind, ...proof });
    }
    if (memberVerified) {
      statements.push(env.DB.prepare("UPDATE ingredient_publication_members SET state = 'public_verified', updated_at = CURRENT_TIMESTAMP WHERE batch_id = ?1 AND gap_id = ?2").bind(batchId, member.gap_id));
      statements.push(env.DB.prepare("UPDATE ingredient_gaps SET status = 'published', published_commodity_id = ?3, updated_at = CURRENT_TIMESTAMP WHERE id = ?2 AND status = 'ready_to_publish'").bind(batchId, member.gap_id, member.commodity_id));
      statements.push(env.DB.prepare("UPDATE ingredient_pricing_jobs SET state = 'public_verified', updated_at = CURRENT_TIMESTAMP WHERE gap_id = ?1 AND state = 'ready_to_publish'").bind(member.gap_id));
      statements.push(env.DB.prepare("UPDATE recipe_hold_requirements SET terminal_kind = 'available', satisfied_at = CURRENT_TIMESTAMP WHERE gap_id = ?1 AND terminal_kind IS NULL").bind(member.gap_id));
      statements.push(env.DB.prepare("DELETE FROM ingredient_pricing_inbox WHERE gap_id = ?1").bind(member.gap_id));
    }
  }
  if (statements.length) for (let offset = 0; offset < statements.length; offset += 90) await env.DB.batch(statements.slice(offset, offset + 90));
  const remaining = await env.DB.prepare("SELECT COUNT(*) AS count FROM ingredient_publication_members WHERE batch_id = ?1 AND state != 'public_verified'").bind(batchId).first<{ count: number }>();
  const complete = Number(remaining?.count ?? 0) === 0;
  await env.DB.prepare(`UPDATE ingredient_publication_batches SET state = ?2, release_id = ?3,
      completed_at = CASE WHEN ?2 = 'completed' THEN CURRENT_TIMESTAMP ELSE completed_at END, updated_at = CURRENT_TIMESTAMP WHERE id = ?1`)
    .bind(batchId, complete ? "completed" : "edge_verified", input.releaseId).run();
  return { batchId, releaseId: input.releaseId, complete, proofs };
}
