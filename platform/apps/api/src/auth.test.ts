import { describe, expect, it } from "vitest";
import { authenticateMutation, githubWorkflowRole, isGithubReusableWorkflowCall, signMutationForTest, validateGithubOidcClaims } from "./auth";
import type { WorkerEnv } from "./env";

function nonceDatabase(): D1Database {
  const seen = new Set<string>();
  return {
    prepare() {
      let values: unknown[] = [];
      return {
        bind(...bound: unknown[]) { values = bound; return this; },
        async run() {
          const key = `${String(values[0])}\u001f${String(values[1])}`;
          if (seen.has(key)) throw new Error("unique constraint");
          seen.add(key);
          return { success: true };
        },
      };
    },
  } as unknown as D1Database;
}

function environment(): WorkerEnv {
  return {
    DB: nonceDatabase(),
    EVIDENCE: {} as R2Bucket,
    BACKUPS: {} as R2Bucket,
    BACKUPS_SECONDARY: {} as R2Bucket,
    ARCHIVE: {} as R2Bucket,
    BACKUP_WORKFLOW: {} as Workflow,
    RESTORE_WORKFLOW: {} as Workflow,
    ASSETS: {} as Fetcher,
    APP_ENV: "test",
    PUBLIC_ORIGIN: "https://example.test",
    MUTATION_KEYS: JSON.stringify({
      "capture-agent": { secret: "capture-secret", role: "capture", sourceIds: ["aldi-storefront"] },
      "engine-agent": { secret: "engine-secret", role: "engine" },
    }),
  };
}

async function signedRequest(agentId: string, secret: string, nonce: string): Promise<Request> {
  const request = new Request("https://example.test/internal/capture-batches", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ sourceId: "aldi-storefront" }),
  });
  const timestamp = new Date().toISOString();
  return new Request(request, { headers: await signMutationForTest(request, agentId, secret, timestamp, nonce) });
}

describe("mutation authentication", () => {
  it("accepts a correctly scoped signature and records its nonce", async () => {
    const identity = await authenticateMutation(
      await signedRequest("capture-agent", "capture-secret", "nonce_12345678"),
      environment(),
      ["capture", "operator"],
    );
    expect(identity).toMatchObject({ agentId: "capture-agent", role: "capture", sourceIds: ["aldi-storefront"] });
  });

  it("rejects replay of the same nonce", async () => {
    const env = environment();
    const request = await signedRequest("capture-agent", "capture-secret", "nonce_replay_1234");
    await authenticateMutation(request, env, ["capture"]);
    await expect(authenticateMutation(request, env, ["capture"])).rejects.toThrow(/already been used/);
  });

  it("rejects a valid signature from the wrong role", async () => {
    await expect(authenticateMutation(
      await signedRequest("capture-agent", "capture-secret", "nonce_wrong_role"),
      environment(),
      ["engine"],
    )).rejects.toThrow(/role is not authorized/);
  });

  it("rejects a body signed with the wrong secret", async () => {
    await expect(authenticateMutation(
      await signedRequest("capture-agent", "wrong-secret", "nonce_bad_sig_123"),
      environment(),
      ["capture"],
    )).rejects.toThrow(/invalid mutation signature/);
  });
});

describe("GitHub OIDC trust policy", () => {
  it("grants operator role only to the restore workflow", () => {
    expect(githubWorkflowRole("Schweino/SimpleMoneyPlaybook/.github/workflows/platform-restore.yml@refs/heads/main")).toBe("operator");
    expect(githubWorkflowRole("Schweino/SimpleMoneyPlaybook/.github/workflows/platform-v3.yml@refs/heads/main")).toBe("engine");
    expect(githubWorkflowRole("Schweino/SimpleMoneyPlaybook/.github/workflows/agent-triage-reviewer.yml@refs/heads/main")).toBe("engine");
  });

  it("distinguishes a direct workflow token from a reusable agent runner token", () => {
    const platform = "Schweino/SimpleMoneyPlaybook/.github/workflows/platform-v3.yml@refs/heads/main";
    const thinAgent = "Schweino/SimpleMoneyPlaybook/.github/workflows/agent-triage-reviewer.yml@refs/heads/main";
    const runner = "Schweino/SimpleMoneyPlaybook/.github/workflows/platform-agent-runner.yml@refs/heads/main";

    expect(isGithubReusableWorkflowCall(platform, platform)).toBe(false);
    expect(isGithubReusableWorkflowCall(platform, undefined)).toBe(false);
    expect(isGithubReusableWorkflowCall(thinAgent, runner)).toBe(true);
  });

  it("binds issuer, audience, repository, and workflow", () => {
    const now = Math.floor(Date.now() / 1000);
    expect(() => validateGithubOidcClaims({
      iss: "https://token.actions.githubusercontent.com",
      aud: "tc-grocery-v3",
      sub: "repo:Schweino/SimpleMoneyPlaybook:ref:refs/heads/main",
      exp: now + 300,
      iat: now,
      repository: "Schweino/SimpleMoneyPlaybook",
      workflow_ref: "Schweino/SimpleMoneyPlaybook/.github/workflows/platform-v3.yml@refs/heads/main",
      run_id: "1234",
    }, {
      ...environment(),
      GITHUB_OIDC_AUDIENCE: "tc-grocery-v3",
      GITHUB_OIDC_REPOSITORY: "Schweino/SimpleMoneyPlaybook",
      GITHUB_OIDC_WORKFLOW_REF: "Schweino/SimpleMoneyPlaybook/.github/workflows/platform-v3.yml@refs/heads/main",
    }, now)).not.toThrow();
  });

  it("rejects a token from another repository", () => {
    const now = Math.floor(Date.now() / 1000);
    expect(() => validateGithubOidcClaims({
      iss: "https://token.actions.githubusercontent.com",
      aud: "tc-grocery-v3",
      sub: "repo:attacker/repo:ref:refs/heads/main",
      exp: now + 300,
      repository: "attacker/repo",
      run_id: "1",
    }, {
      ...environment(),
      GITHUB_OIDC_AUDIENCE: "tc-grocery-v3",
      GITHUB_OIDC_REPOSITORY: "Schweino/SimpleMoneyPlaybook",
    }, now)).toThrow(/repository is not trusted/);
  });

  it("accepts only an explicitly listed workflow", () => {
    const now = Math.floor(Date.now() / 1000);
    const base = {
      iss: "https://token.actions.githubusercontent.com",
      aud: "tc-grocery-v3",
      sub: "repo:Schweino/SimpleMoneyPlaybook:ref:refs/heads/main",
      exp: now + 300,
      iat: now,
      repository: "Schweino/SimpleMoneyPlaybook",
      run_id: "1234",
    };
    const env = {
      ...environment(),
      GITHUB_OIDC_AUDIENCE: "tc-grocery-v3",
      GITHUB_OIDC_REPOSITORY: "Schweino/SimpleMoneyPlaybook",
      GITHUB_OIDC_WORKFLOW_REFS: JSON.stringify([
        "Schweino/SimpleMoneyPlaybook/.github/workflows/platform-v3.yml@refs/heads/main",
        "Schweino/SimpleMoneyPlaybook/.github/workflows/platform-agents.yml@refs/heads/main",
      ]),
    };
    expect(() => validateGithubOidcClaims({ ...base, workflow_ref: "Schweino/SimpleMoneyPlaybook/.github/workflows/platform-agents.yml@refs/heads/main" }, env, now)).not.toThrow();
    expect(() => validateGithubOidcClaims({ ...base, workflow_ref: "Schweino/SimpleMoneyPlaybook/.github/workflows/rogue.yml@refs/heads/main" }, env, now)).toThrow(/workflow is not trusted/);
  });

  it("requires the approved reusable runner for thin agent callers", () => {
    const now = Math.floor(Date.now() / 1000);
    const claims = {
      iss: "https://token.actions.githubusercontent.com", aud: "tc-grocery-v3",
      sub: "repo:Schweino/SimpleMoneyPlaybook:ref:refs/heads/main", exp: now + 300, iat: now,
      repository: "Schweino/SimpleMoneyPlaybook", run_id: "1234",
      workflow_ref: "Schweino/SimpleMoneyPlaybook/.github/workflows/agent-triage-reviewer.yml@refs/heads/main",
      job_workflow_ref: "Schweino/SimpleMoneyPlaybook/.github/workflows/platform-agent-runner.yml@refs/heads/main",
    };
    const env = {
      ...environment(), GITHUB_OIDC_AUDIENCE: "tc-grocery-v3", GITHUB_OIDC_REPOSITORY: "Schweino/SimpleMoneyPlaybook",
      GITHUB_OIDC_WORKFLOW_REFS: JSON.stringify(["Schweino/SimpleMoneyPlaybook/.github/workflows/platform-v3.yml@refs/heads/main"]),
      GITHUB_OIDC_AGENT_RUNNER_REF: "Schweino/SimpleMoneyPlaybook/.github/workflows/platform-agent-runner.yml@refs/heads/main",
    };
    expect(() => validateGithubOidcClaims(claims, env, now)).not.toThrow();
    expect(() => validateGithubOidcClaims({ ...claims, job_workflow_ref: "Schweino/SimpleMoneyPlaybook/.github/workflows/rogue.yml@refs/heads/main" }, env, now)).toThrow(/workflow is not trusted/);
  });
});
