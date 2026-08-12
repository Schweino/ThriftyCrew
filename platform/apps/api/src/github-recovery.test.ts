import { afterEach, describe, expect, it, vi } from "vitest";
import type { WorkerEnv } from "./env";

const operations = vi.hoisted(() => ({
  githubActionsDispatchEnabled: vi.fn((env: WorkerEnv) => env.GITHUB_ACTIONS_DISPATCH_ENABLED === "1"),
  raiseOperationalAlert: vi.fn().mockResolvedValue(undefined),
  resolveOperationalAlert: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("./operations", () => operations);

import { classifyGithubFailure, handleGithubActionsWebhook, processGithubWorkflowRun, verifyGithubWebhookSignature } from "./github-recovery";

afterEach(() => {
  vi.unstubAllGlobals();
  vi.clearAllMocks();
});

function webhookDatabase(insertChanges = 1): { db: D1Database; calls: Array<{ sql: string; bindings: unknown[] }> } {
  const calls: Array<{ sql: string; bindings: unknown[] }> = [];
  return {
    calls,
    db: {
      prepare(sql: string) {
        return {
          bind(...bindings: unknown[]) {
            return {
              async run() {
                calls.push({ sql, bindings });
                return { meta: { changes: sql.includes("INSERT OR IGNORE") ? insertChanges : 1 } };
              },
            };
          },
        };
      },
    } as unknown as D1Database,
  };
}

describe("GitHub webhook authentication", () => {
  it("matches GitHub's published HMAC-SHA256 fixture and rejects tampering", async () => {
    const body = new TextEncoder().encode("Hello, World!");
    const signature = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17";
    await expect(verifyGithubWebhookSignature("It's a Secret to Everybody", body, signature)).resolves.toBe(true);
    await expect(verifyGithubWebhookSignature("It's a Secret to Everybody", new TextEncoder().encode("Hello, World?"), signature)).resolves.toBe(false);
    await expect(verifyGithubWebhookSignature("It's a Secret to Everybody", body, null)).resolves.toBe(false);
  });

  it("accepts GitHub's signed ping without touching the recovery ledger", async () => {
    const body = new TextEncoder().encode(JSON.stringify({ zen: "Keep it logically awesome." }));
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode("webhook-secret"), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
    const digest = await crypto.subtle.sign("HMAC", key, body);
    const signature = `sha256=${Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
    const response = await handleGithubActionsWebhook(new Request("https://example.test/webhooks/github/actions", {
      method: "POST",
      headers: { "x-github-event": "ping", "x-github-delivery": "delivery-1", "x-hub-signature-256": signature },
      body,
    }), { GITHUB_WEBHOOK_SECRET: "webhook-secret" } as never, { waitUntil: () => undefined });
    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({ ok: true, event: "ping" });
  });

  it("rejects an unsigned delivery before processing JSON", async () => {
    const response = await handleGithubActionsWebhook(new Request("https://example.test/webhooks/github/actions", {
      method: "POST",
      headers: { "x-github-event": "workflow_run" },
      body: "not-json",
    }), { GITHUB_WEBHOOK_SECRET: "webhook-secret" } as never, { waitUntil: () => undefined });
    expect(response.status).toBe(401);
  });
});

describe("repository-wide GitHub Actions recovery policy", () => {
  it("retries transient backend failures once", () => {
    expect(classifyGithubFailure({
      conclusion: "failure",
      event: "schedule",
      runAttempt: 1,
      diagnostics: ["POST /internal/capture-batches/example/seal returned 500: Internal error"],
    })).toEqual({ action: "retry", reason: "diagnostics indicate a transient service, network, or runner failure" });
  });

  it("retries GitHub infrastructure conclusions without log parsing", () => {
    expect(classifyGithubFailure({ conclusion: "timed_out", event: "push", runAttempt: 1, diagnostics: [] }).action).toBe("retry");
    expect(classifyGithubFailure({ conclusion: "startup_failure", event: "pull_request", runAttempt: 1, diagnostics: [] }).action).toBe("retry");
  });

  it("does not hide deterministic code or authorization failures behind retries", () => {
    expect(classifyGithubFailure({ conclusion: "failure", event: "push", runAttempt: 1, diagnostics: ["AssertionError: expected 1 to be 2"] }).action).toBe("alert");
    expect(classifyGithubFailure({ conclusion: "failure", event: "workflow_dispatch", runAttempt: 1, diagnostics: ["HTTP 403 Forbidden"] }).action).toBe("alert");
    expect(classifyGithubFailure({ conclusion: "failure", event: "workflow_dispatch", runAttempt: 1, diagnostics: ["The job was not started because your spending limit needs to be increased"] }).action).toBe("alert");
  });

  it("gives operational runs one bounded recovery attempt when diagnostics are unavailable", () => {
    expect(classifyGithubFailure({ conclusion: "failure", event: "workflow_dispatch", runAttempt: 1, diagnostics: [] }).action).toBe("retry");
    expect(classifyGithubFailure({ conclusion: "failure", event: "schedule", runAttempt: 2, diagnostics: [], maxAttempts: 2 })).toEqual({
      action: "alert",
      reason: "automatic retry limit of 2 attempts reached",
    });
  });

  it("records but ignores non-failure conclusions", () => {
    expect(classifyGithubFailure({ conclusion: "success", event: "push", runAttempt: 1, diagnostics: [] }).action).toBe("ignore");
    expect(classifyGithubFailure({ conclusion: "cancelled", event: "workflow_dispatch", runAttempt: 1, diagnostics: [] }).action).toBe("ignore");
  });
});

describe("GitHub workflow-run recovery processing", () => {
  it("deduplicates a workflow attempt before calling GitHub", async () => {
    const { db } = webhookDatabase(0);
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const result = await processGithubWorkflowRun({
      DB: db,
      GITHUB_REPOSITORY: "owner/repo",
      GITHUB_DISPATCH_TOKEN: "token",
      GITHUB_ACTIONS_DISPATCH_ENABLED: "1",
    } as WorkerEnv, "delivery-redelivery", {
      action: "completed",
      repository: { full_name: "owner/repo" },
      workflow_run: { id: 42, run_attempt: 1, event: "schedule", conclusion: "failure" },
    });
    expect(result).toEqual({ duplicate: true, decision: "duplicate" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("requests one failed-job rerun for a transient failure and records only sanitized metadata", async () => {
    const { db, calls } = webhookDatabase();
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ jobs: [{ id: 7, name: "scheduled-operation", conclusion: "failure" }] })))
      .mockResolvedValueOnce(new Response(JSON.stringify([{ title: "Process completed", message: "exit code 1" }])))
      .mockResolvedValueOnce(new Response("POST /internal/example/seal returned 500: Internal error"))
      .mockResolvedValueOnce(new Response(null, { status: 201 }));
    vi.stubGlobal("fetch", fetchMock);
    const result = await processGithubWorkflowRun({
      DB: db,
      GITHUB_REPOSITORY: "owner/repo",
      GITHUB_DISPATCH_TOKEN: "token",
      GITHUB_ACTIONS_DISPATCH_ENABLED: "1",
    } as WorkerEnv, "delivery-1", {
      action: "completed",
      repository: { full_name: "owner/repo" },
      workflow: { id: 9, name: "Platform", path: ".github/workflows/platform.yml" },
      workflow_run: { id: 42, run_attempt: 1, event: "schedule", conclusion: "failure", html_url: "https://github.test/run/42" },
    });
    expect(result).toEqual({ decision: "retry-requested" });
    expect(fetchMock.mock.calls[3]?.[0]).toBe("https://api.github.com/repos/owner/repo/actions/runs/42/rerun-failed-jobs");
    expect(operations.raiseOperationalAlert).toHaveBeenCalledOnce();
    const persisted = calls.filter((call) => call.sql.startsWith("UPDATE alert_deliveries")).at(-1)?.bindings[2];
    expect(String(persisted)).toContain("scheduled-operation");
    expect(String(persisted)).not.toContain("Internal error");
  });

  it("retains transient failures without rerunning when local execution is authoritative", async () => {
    const { db } = webhookDatabase();
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ jobs: [] })));
    vi.stubGlobal("fetch", fetchMock);
    const result = await processGithubWorkflowRun({
      DB: db,
      GITHUB_REPOSITORY: "owner/repo",
      GITHUB_DISPATCH_TOKEN: "token",
      GITHUB_ACTIONS_DISPATCH_ENABLED: "0",
    } as WorkerEnv, "delivery-local-plane", {
      action: "completed",
      repository: { full_name: "owner/repo" },
      workflow_run: { id: 44, run_attempt: 1, event: "workflow_dispatch", conclusion: "failure" },
    });
    expect(result).toEqual({ decision: "ignored-local-authority" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("resolves the deferred alert when a later attempt succeeds", async () => {
    const { db } = webhookDatabase();
    const result = await processGithubWorkflowRun({ DB: db, GITHUB_REPOSITORY: "owner/repo" } as WorkerEnv, "delivery-2", {
      action: "completed",
      repository: { full_name: "owner/repo" },
      workflow_run: { id: 42, run_attempt: 2, event: "schedule", conclusion: "success" },
    });
    expect(result).toEqual({ decision: "recovered" });
    expect(operations.resolveOperationalAlert).toHaveBeenCalledWith(expect.anything(), "github-run:42", expect.objectContaining({ runAttempt: 2 }));
  });
});
