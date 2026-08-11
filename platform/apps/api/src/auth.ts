import { digestHex } from "@thriftycrew/domain";
import type { MutationIdentity, MutationKeyRecord, MutationRole, WorkerEnv } from "./env";

const encoder = new TextEncoder();
const MAX_CLOCK_SKEW_MS = 5 * 60 * 1000;
const GITHUB_ISSUER = "https://token.actions.githubusercontent.com";
const GITHUB_JWKS = "https://token.actions.githubusercontent.com/.well-known/jwks";

interface GithubOidcHeader { alg?: string; kid?: string; typ?: string }
interface GithubOidcClaims {
  iss?: string;
  aud?: string | string[];
  sub?: string;
  exp?: number;
  nbf?: number;
  iat?: number;
  repository?: string;
  repository_id?: string;
  workflow_ref?: string;
  job_workflow_ref?: string;
  run_id?: string;
  run_attempt?: string;
}

interface JsonWebKeySet { keys: Array<JsonWebKey & { kid?: string }> }
let cachedGithubKeys: { expiresAt: number; value: JsonWebKeySet } | undefined;

function keyMap(env: WorkerEnv): Record<string, MutationKeyRecord> {
  if (!env.MUTATION_KEYS) return {};
  const parsed: unknown = JSON.parse(env.MUTATION_KEYS);
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("MUTATION_KEYS must be a JSON object");
  return parsed as Record<string, MutationKeyRecord>;
}

function constantTimeEqual(left: string, right: string): boolean {
  const max = Math.max(left.length, right.length);
  let difference = left.length ^ right.length;
  for (let index = 0; index < max; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0);
  }
  return difference === 0;
}

async function hmacHex(secret: string, value: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", encoder.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = await crypto.subtle.sign("HMAC", key, Uint8Array.from(encoder.encode(value)).buffer);
  return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function decodeBase64Url(value: string): Uint8Array {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  const decoded = atob(padded);
  return Uint8Array.from(decoded, (character) => character.charCodeAt(0));
}

function decodeJwtJson<T>(value: string): T {
  return JSON.parse(new TextDecoder().decode(decodeBase64Url(value))) as T;
}

function audienceIncludes(claim: string | string[] | undefined, expected: string): boolean {
  return typeof claim === "string" ? claim === expected : Array.isArray(claim) && claim.includes(expected);
}

export function githubWorkflowRole(workflowRef: string | undefined): MutationRole {
  return workflowRef?.includes("/platform-restore.yml@") ? "operator" : "engine";
}

export function isGithubReusableWorkflowCall(workflowRef: string | undefined, jobWorkflowRef: string | undefined): boolean {
  return Boolean(jobWorkflowRef && jobWorkflowRef !== workflowRef);
}

async function githubKeys(): Promise<JsonWebKeySet> {
  if (cachedGithubKeys && cachedGithubKeys.expiresAt > Date.now()) return cachedGithubKeys.value;
  const response = await fetch(GITHUB_JWKS, { headers: { accept: "application/json" } });
  if (!response.ok) throw new Error("GitHub OIDC signing keys are unavailable");
  const value = await response.json() as JsonWebKeySet;
  if (!Array.isArray(value.keys) || value.keys.length === 0) throw new Error("GitHub OIDC signing keys are invalid");
  cachedGithubKeys = { value, expiresAt: Date.now() + 60 * 60 * 1000 };
  return value;
}

export function validateGithubOidcClaims(claims: GithubOidcClaims, env: WorkerEnv, nowSeconds = Math.floor(Date.now() / 1000)): void {
  if (!env.GITHUB_OIDC_AUDIENCE || (!env.GITHUB_OIDC_REPOSITORY && !env.GITHUB_OIDC_REPOSITORY_ID)) {
    throw new Error("GitHub OIDC trust policy is not configured");
  }
  if (claims.iss !== GITHUB_ISSUER) throw new Error("invalid GitHub OIDC issuer");
  if (!audienceIncludes(claims.aud, env.GITHUB_OIDC_AUDIENCE)) throw new Error("invalid GitHub OIDC audience");
  if (!claims.exp || claims.exp <= nowSeconds - 30) throw new Error("GitHub OIDC token is expired");
  if (claims.nbf && claims.nbf > nowSeconds + 30) throw new Error("GitHub OIDC token is not active");
  if (claims.iat && claims.iat > nowSeconds + 30) throw new Error("GitHub OIDC token was issued in the future");
  if (env.GITHUB_OIDC_REPOSITORY && claims.repository !== env.GITHUB_OIDC_REPOSITORY) throw new Error("GitHub OIDC repository is not trusted");
  if (env.GITHUB_OIDC_REPOSITORY_ID && claims.repository_id !== env.GITHUB_OIDC_REPOSITORY_ID) throw new Error("GitHub OIDC repository id is not trusted");
  const trustedWorkflowRefs = env.GITHUB_OIDC_WORKFLOW_REFS
    ? JSON.parse(env.GITHUB_OIDC_WORKFLOW_REFS) as string[]
    : env.GITHUB_OIDC_WORKFLOW_REF ? [env.GITHUB_OIDC_WORKFLOW_REF] : [];
  const isStaticWorkflow = Boolean(claims.workflow_ref && trustedWorkflowRefs.includes(claims.workflow_ref));
  const isRegisteredAgentCaller = Boolean(
    claims.workflow_ref
    && claims.job_workflow_ref
    && env.GITHUB_OIDC_AGENT_RUNNER_REF
    && claims.job_workflow_ref === env.GITHUB_OIDC_AGENT_RUNNER_REF,
  );
  if (trustedWorkflowRefs.length > 0 && !isStaticWorkflow && !isRegisteredAgentCaller) throw new Error("GitHub OIDC workflow is not trusted");
  if (!claims.sub || !claims.run_id) throw new Error("GitHub OIDC identity claims are incomplete");
}

async function authenticateGithubOidc(request: Request, env: WorkerEnv, allowedRoles: readonly MutationRole[]): Promise<MutationIdentity> {
  const authorization = request.headers.get("authorization") ?? "";
  const token = authorization.startsWith("Bearer ") ? authorization.slice(7) : "";
  const segments = token.split(".");
  if (segments.length !== 3) throw new Error("invalid GitHub OIDC token");
  const header = decodeJwtJson<GithubOidcHeader>(segments[0]!);
  const claims = decodeJwtJson<GithubOidcClaims>(segments[1]!);
  if (header.alg !== "RS256" || !header.kid || (header.typ && header.typ !== "JWT")) throw new Error("unsupported GitHub OIDC token header");
  validateGithubOidcClaims(claims, env);
  const keys = await githubKeys();
  const jwk = keys.keys.find((candidate) => candidate.kid === header.kid && candidate.kty === "RSA");
  if (!jwk) throw new Error("GitHub OIDC signing key is unknown");
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
  const signed = encoder.encode(`${segments[0]}.${segments[1]}`);
  const signature = Uint8Array.from(decodeBase64Url(segments[2]!)).buffer;
  const verified = await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, signature, signed);
  if (!verified) throw new Error("invalid GitHub OIDC signature");
  let registeredAgent: { id: string; capabilities_json: string; workflow_ref: string; reusable_workflow_ref: string } | null = null;
  if (isGithubReusableWorkflowCall(claims.workflow_ref, claims.job_workflow_ref)) {
    registeredAgent = await env.DB.prepare(
      `SELECT id, capabilities_json, workflow_ref, reusable_workflow_ref
         FROM agent_registry
        WHERE active = 1 AND enabled = 1 AND workflow_ref = ?1`,
    ).bind(claims.workflow_ref ?? "").first<{ id: string; capabilities_json: string; workflow_ref: string; reusable_workflow_ref: string }>();
    if (!registeredAgent) throw new Error("GitHub caller workflow is not assigned to an enabled agent");
    if (registeredAgent.reusable_workflow_ref !== claims.job_workflow_ref) throw new Error("GitHub reusable workflow does not match the agent registry");
    if (!env.GITHUB_OIDC_AGENT_RUNNER_REF || claims.job_workflow_ref !== env.GITHUB_OIDC_AGENT_RUNNER_REF) throw new Error("GitHub reusable workflow is not approved");
  }
  const role = registeredAgent ? "engine" : githubWorkflowRole(claims.workflow_ref);
  if (!allowedRoles.includes(role)) throw new Error("GitHub Actions is not authorized for this operation");
  const timestamp = request.headers.get("x-tc-timestamp") ?? "";
  const nonce = request.headers.get("x-tc-nonce") ?? "";
  if (!/^[a-zA-Z0-9._:-]{8,160}$/.test(nonce)) throw new Error("invalid request nonce");
  const instant = Date.parse(timestamp);
  if (!Number.isFinite(instant) || Math.abs(Date.now() - instant) > MAX_CLOCK_SKEW_MS) throw new Error("request timestamp is outside the allowed window");
  const runIdentity = `github:${claims.repository_id ?? claims.repository}:${claims.run_id}:${claims.run_attempt ?? "1"}`;
  const agentId = registeredAgent?.id ?? runIdentity;
  try {
    await env.DB.prepare(
      "INSERT INTO request_nonces (agent_id, nonce, expires_at) VALUES (?1, ?2, datetime(?3, '+10 minutes'))",
    ).bind(agentId, nonce, timestamp).run();
  } catch {
    throw new Error("request nonce has already been used");
  }
  return {
    agentId,
    secret: "",
    role,
    authMethod: "github_oidc",
    githubRunId: runIdentity,
    ...(claims.workflow_ref ? { workflowRef: claims.workflow_ref } : {}),
    ...(claims.job_workflow_ref ? { jobWorkflowRef: claims.job_workflow_ref } : {}),
    ...(registeredAgent ? { registeredAgentId: registeredAgent.id, capabilities: JSON.parse(registeredAgent.capabilities_json) as string[] } : {}),
  };
}

export async function authenticateMutation(
  request: Request,
  env: WorkerEnv,
  allowedRoles: readonly MutationRole[],
): Promise<MutationIdentity> {
  if (request.headers.get("authorization")?.startsWith("Bearer ")) {
    return authenticateGithubOidc(request, env, allowedRoles);
  }
  const agentId = request.headers.get("x-tc-agent") ?? "";
  const timestamp = request.headers.get("x-tc-timestamp") ?? "";
  const nonce = request.headers.get("x-tc-nonce") ?? "";
  const receivedSignature = request.headers.get("x-tc-signature") ?? "";
  const record = keyMap(env)[agentId];
  if (!agentId || !timestamp || !nonce || !receivedSignature || !record) throw new Error("unauthorized mutation request");
  if (!allowedRoles.includes(record.role)) throw new Error("mutation role is not authorized for this operation");
  if (!/^[a-zA-Z0-9._:-]{8,160}$/.test(nonce)) throw new Error("invalid request nonce");
  const instant = Date.parse(timestamp);
  if (!Number.isFinite(instant) || Math.abs(Date.now() - instant) > MAX_CLOCK_SKEW_MS) throw new Error("request timestamp is outside the allowed window");

  const body = new Uint8Array(await request.clone().arrayBuffer());
  const bodyHash = await digestHex(body);
  const url = new URL(request.url);
  const canonical = [timestamp, nonce, request.method.toUpperCase(), url.pathname, bodyHash].join("\n");
  const expected = await hmacHex(record.secret, canonical);
  if (!constantTimeEqual(expected, receivedSignature.toLowerCase())) throw new Error("invalid mutation signature");

  try {
    await env.DB.prepare(
      "INSERT INTO request_nonces (agent_id, nonce, expires_at) VALUES (?1, ?2, datetime(?3, '+10 minutes'))",
    ).bind(agentId, nonce, timestamp).run();
  } catch {
    throw new Error("request nonce has already been used");
  }
  if (record.registeredAgent) {
    if (record.role !== "engine") throw new Error("registered local agents require the engine mutation role");
    const registered = await env.DB.prepare(
      `SELECT id, capabilities_json FROM agent_registry
        WHERE id = ?1 AND active = 1 AND enabled = 1 AND plane = 'pc'`,
    ).bind(agentId).first<{ id: string; capabilities_json: string }>();
    if (!registered) throw new Error("local agent is not assigned to an enabled PC registry entry");
    return {
      agentId,
      ...record,
      authMethod: "hmac",
      registeredAgentId: registered.id,
      capabilities: JSON.parse(registered.capabilities_json) as string[],
    };
  }
  return { agentId, ...record, authMethod: "hmac" };
}

export async function signMutationForTest(
  request: Request,
  agentId: string,
  secret: string,
  timestamp: string,
  nonce: string,
): Promise<Headers> {
  const bodyHash = await digestHex(new Uint8Array(await request.clone().arrayBuffer()));
  const url = new URL(request.url);
  const canonical = [timestamp, nonce, request.method.toUpperCase(), url.pathname, bodyHash].join("\n");
  const headers = new Headers(request.headers);
  headers.set("x-tc-agent", agentId);
  headers.set("x-tc-timestamp", timestamp);
  headers.set("x-tc-nonce", nonce);
  headers.set("x-tc-signature", await hmacHex(secret, canonical));
  return headers;
}
