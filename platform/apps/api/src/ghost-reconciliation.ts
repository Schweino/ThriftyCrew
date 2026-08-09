import { deterministicId, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

interface GhostPost { id: string; slug: string; visibility: string; updated_at: string }
interface RotationIntent { recipe_slug: string; intended_visibility: "public" | "members" | "paid" }

const encoder = new TextEncoder();

export function mayShowFreeBadge(intendedVisibility: string, verifiedGhostVisibility: string): boolean {
  return intendedVisibility === "public" && verifiedGhostVisibility === "public";
}

function base64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function ghostToken(adminKey: string): Promise<string> {
  const [id, secretHex] = adminKey.split(":");
  if (!id || !secretHex || !/^[a-fA-F0-9]+$/.test(secretHex) || secretHex.length % 2 !== 0) throw new Error("Ghost Admin key is malformed");
  const now = Math.floor(Date.now() / 1000);
  const header = base64Url(encoder.encode(JSON.stringify({ alg: "HS256", typ: "JWT", kid: id })));
  const payload = base64Url(encoder.encode(JSON.stringify({ iat: now, exp: now + 300, aud: "/admin/" })));
  const keyBytes = Uint8Array.from(secretHex.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = new Uint8Array(await crypto.subtle.sign("HMAC", key, encoder.encode(`${header}.${payload}`)));
  return `${header}.${payload}.${base64Url(signature)}`;
}

async function ghostRequest<T>(env: WorkerEnv, pathname: string, init: RequestInit = {}): Promise<T> {
  if (!env.GHOST_ADMIN_ORIGIN || !env.GHOST_ADMIN_KEY) throw new Error("Ghost reconciliation is not configured");
  const headers = new Headers(init.headers);
  headers.set("authorization", `Ghost ${await ghostToken(env.GHOST_ADMIN_KEY)}`);
  headers.set("accept-version", "v5.0");
  if (init.body) headers.set("content-type", "application/json");
  const response = await fetch(new URL(pathname, env.GHOST_ADMIN_ORIGIN), { ...init, headers });
  if (!response.ok) throw new Error(`Ghost ${init.method ?? "GET"} ${pathname} returned ${response.status}`);
  return response.json() as Promise<T>;
}

async function readPost(env: WorkerEnv, slug: string): Promise<GhostPost> {
  const response = await ghostRequest<{ posts: GhostPost[] }>(env, `/ghost/api/admin/posts/slug/${encodeURIComponent(slug)}/`);
  const post = response.posts[0];
  if (!post) throw new Error(`Ghost post ${slug} was not found`);
  return post;
}

async function setVisibility(env: WorkerEnv, post: GhostPost, visibility: string): Promise<void> {
  await ghostRequest(env, `/ghost/api/admin/posts/${encodeURIComponent(post.id)}/`, {
    method: "PUT",
    body: JSON.stringify({ posts: [{ visibility, updated_at: post.updated_at }] }),
  });
}

export async function reconcileGhostRotation(env: WorkerEnv, releaseId: string): Promise<{
  reconciliationId: string;
  status: "verified" | "failed";
  safePublicSlugs: string[];
  mismatches: Array<{ slug: string; intended: string; actual: string | null; error?: string }>;
}> {
  const release = await env.DB.prepare("SELECT state FROM releases WHERE id = ?1").bind(releaseId).first<{ state: string }>();
  if (!release || !["published", "superseded"].includes(release.state)) throw new Error("Ghost rotation can only reconcile a published release");
  const intents = await env.DB.prepare(
    "SELECT recipe_slug, intended_visibility FROM release_free_rotation WHERE release_id = ?1 ORDER BY recipe_slug",
  ).bind(releaseId).all<RotationIntent>();
  if (intents.results.length === 0) throw new Error("release has no free-rotation intent");
  const reconciliationId = `ghost_${crypto.randomUUID()}`;
  await env.DB.prepare(
    `INSERT INTO ghost_rotation_reconciliations (id, release_id, status, expected_count)
     VALUES (?1, ?2, 'started', ?3)`,
  ).bind(reconciliationId, releaseId, intents.results.length).run();

  const safePublicSlugs: string[] = [];
  const mismatches: Array<{ slug: string; intended: string; actual: string | null; error?: string }> = [];
  let examined = 0;
  for (const intent of intents.results) {
    try {
      let post = await readPost(env, intent.recipe_slug);
      if (post.visibility !== intent.intended_visibility) {
        await setVisibility(env, post, intent.intended_visibility);
        post = await readPost(env, intent.recipe_slug);
      }
      examined += 1;
      if (post.visibility !== intent.intended_visibility) {
        mismatches.push({ slug: intent.recipe_slug, intended: intent.intended_visibility, actual: post.visibility });
      }
      // Badge truth is the intersection of release intent and verified Ghost
      // truth. Consumers may remove badges missing from this list, never infer
      // or add a badge from intent alone.
      if (mayShowFreeBadge(intent.intended_visibility, post.visibility)) safePublicSlugs.push(intent.recipe_slug);
    } catch (error) {
      mismatches.push({ slug: intent.recipe_slug, intended: intent.intended_visibility, actual: null, error: error instanceof Error ? error.message : "unknown error" });
    }
  }
  const status = mismatches.length === 0 && examined === intents.results.length ? "verified" : "failed";
  await env.DB.prepare(
    `UPDATE ghost_rotation_reconciliations
        SET status = ?2, examined_count = ?3, mismatch_count = ?4, detail_json = ?5, finished_at = CURRENT_TIMESTAMP
      WHERE id = ?1`,
  ).bind(reconciliationId, status, examined, mismatches.length, stableJson({ safePublicSlugs, mismatches })).run();
  if (status === "failed") {
    const triageId = await deterministicId("triage", "operational_alert", reconciliationId);
    await env.DB.prepare(
      `INSERT INTO triage_items
         (id, source_kind, source_ref, severity, status, title, evidence_json)
       VALUES (?1, 'operational_alert', ?2, 'hard', 'open', ?3, ?4)`,
    ).bind(triageId, reconciliationId, `Ghost rotation reconciliation failed for ${releaseId}`, stableJson({ mismatches })).run();
  }
  return { reconciliationId, status, safePublicSlugs, mismatches };
}

export async function runGhostClobberDrill(env: WorkerEnv, releaseId: string): Promise<{
  passed: boolean;
  slug: string;
  before: string;
  clobbered: string;
  after: string;
  reconciliationId: string;
  mismatches: Array<{ slug: string; intended: string; actual: string | null; error?: string }>;
}> {
  const intent = await env.DB.prepare(
    `SELECT recipe_slug FROM release_free_rotation
      WHERE release_id = ?1 AND intended_visibility = 'public'
      ORDER BY recipe_slug LIMIT 1`,
  ).bind(releaseId).first<{ recipe_slug: string }>();
  if (!intent) throw new Error("release has no public rotation entry for the Ghost clobber drill");
  const original = await readPost(env, intent.recipe_slug);
  if (original.visibility !== "public") throw new Error(`Ghost post ${intent.recipe_slug} must be public before the clobber drill`);
  let reconciliationId = "not-started";
  let mismatches: Array<{ slug: string; intended: string; actual: string | null; error?: string }> = [];
  let clobbered = original.visibility;
  let after = original.visibility;
  try {
    await setVisibility(env, original, "paid");
    clobbered = (await readPost(env, intent.recipe_slug)).visibility;
    if (clobbered !== "paid") throw new Error(`Ghost clobber was not observable for ${intent.recipe_slug}`);
    const reconciliation = await reconcileGhostRotation(env, releaseId);
    reconciliationId = reconciliation.reconciliationId;
    mismatches = reconciliation.mismatches;
    after = (await readPost(env, intent.recipe_slug)).visibility;
    return {
      passed: reconciliation.status === "verified" && after === "public",
      slug: intent.recipe_slug,
      before: original.visibility,
      clobbered,
      after,
      reconciliationId,
      mismatches,
    };
  } catch (error) {
    // A chaos drill must never strand customer visibility in the injected
    // fault state. Re-read for Ghost's optimistic-lock timestamp and restore.
    const current = await readPost(env, intent.recipe_slug);
    if (current.visibility !== original.visibility) await setVisibility(env, current, original.visibility);
    throw error;
  }
}
