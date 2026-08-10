import { afterEach, describe, expect, it, vi } from "vitest";
import { d1DatabaseFileSize, githubDispatchInputs, githubWorkflowRuns, jobStatusRequiresAlert, scheduleGap } from "./operations";
import type { WorkerEnv } from "./env";

const configuredEnv = {
  GITHUB_DISPATCH_TOKEN: "test-token",
  GITHUB_REPOSITORY: "owner/private-repo",
  GITHUB_WORKFLOW_FILE: "daily-engine.yml",
} as WorkerEnv;

afterEach(() => vi.unstubAllGlobals());

describe("job terminal alerts", () => {
  it("alerts on failed, timed-out, and missed runs but not expected terminal states", () => {
    expect(["failed", "timed_out", "missed"].every(jobStatusRequiresAlert)).toBe(true);
    expect(["completed", "cancelled", "started", "scheduled"].some(jobStatusRequiresAlert)).toBe(false);
  });
});

describe("schedule gap lifecycle", () => {
  const checkedAt = Date.parse("2026-08-10T12:00:00.000Z");

  it("uses the monitoring start as a grace window before the first run", () => {
    expect(scheduleGap(null, "2026-08-10T11:00:00.000Z", checkedAt, 120)).toEqual({
      stale: false,
      ageMinutes: 60,
      basis: "monitoring-grace",
    });
  });

  it("uses durable run evidence once it exists and fails closed without either timestamp", () => {
    expect(scheduleGap("2026-08-10T08:00:00.000Z", "2026-08-10T11:00:00.000Z", checkedAt, 120)).toEqual({
      stale: true,
      ageMinutes: 240,
      basis: "run",
    });
    expect(scheduleGap(null, null, checkedAt, 120)).toEqual({ stale: true, ageMinutes: null, basis: "unknown" });
  });
});

describe("D1 database size metadata", () => {
  it("uses the authorized Cloudflare metadata endpoint instead of forbidden Worker PRAGMAs", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ success: true, result: { file_size: 318_574_592 } })));
    vi.stubGlobal("fetch", fetchMock);
    const size = await d1DatabaseFileSize({
      D1_REST_API_TOKEN: "test-token",
      CLOUDFLARE_ACCOUNT_ID: "account",
      D1_DATABASE_ID: "database",
    } as WorkerEnv);
    expect(size).toBe(318_574_592);
    expect(fetchMock.mock.calls[0]?.[0]).toContain("/accounts/account/d1/database/database?fields=file_size");
  });

  it("fails closed when metadata credentials or file size are unavailable", async () => {
    await expect(d1DatabaseFileSize({} as WorkerEnv)).rejects.toThrow("credentials");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(JSON.stringify({ success: true, result: {} }))));
    await expect(d1DatabaseFileSize({ D1_REST_API_TOKEN: "x", CLOUDFLARE_ACCOUNT_ID: "a", D1_DATABASE_ID: "d" } as WorkerEnv)).rejects.toThrow("metadata request failed");
  });
});

describe("GitHub recovery dispatch inputs", () => {
  it("does not send unsupported inputs to thin agent or restore workflows", () => {
    expect(githubDispatchInputs("agent-source-sentinel-investigator.yml", "source-sentinel-daily", "gap")).toEqual({});
    expect(githubDispatchInputs("platform-restore.yml", "restore-drill-quarterly", "gap")).toEqual({});
  });

  it("preserves registered legacy and platform recovery input contracts", () => {
    expect(githubDispatchInputs("platform-agents.yml", "triage-review", "gap")).toEqual({ inputs: { agent_job: "triage-review" } });
    expect(githubDispatchInputs("platform-v3.yml", "daily-engine", "gap")).toEqual({ inputs: { recovery_job: "daily-engine", recovery_reason: "gap" } });
  });
});

describe("githubWorkflowRuns", () => {
  it("returns only sanitized run, job, and step metadata", async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ workflow_runs: [{
        id: 42, event: "workflow_dispatch", status: "completed", conclusion: "failure", head_sha: "abc",
        created_at: "2026-08-09T12:00:00Z", updated_at: "2026-08-09T12:01:00Z", html_url: "https://github.test/run/42",
        logs_url: "must-not-leak",
      }] }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ jobs: [{
        id: 7, name: "verify", status: "completed", conclusion: "failure", started_at: "2026-08-09T12:00:00Z",
        completed_at: "2026-08-09T12:01:00Z", runner_name: "must-not-leak", steps: [{ name: "test", status: "completed", conclusion: "failure", number: 3 }],
      }] }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify([{
        path: ".github/workflows/test.yml", start_line: 12, end_line: 12, annotation_level: "failure", title: "Process completed", message: "exit code 1",
        raw_details: "must-not-leak",
      }]), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await githubWorkflowRuns(configuredEnv, 1);

    expect(result).toEqual({ runs: [{
      id: 42, event: "workflow_dispatch", status: "completed", conclusion: "failure", headSha: "abc",
      createdAt: "2026-08-09T12:00:00Z", updatedAt: "2026-08-09T12:01:00Z", url: "https://github.test/run/42",
      jobs: [{ id: 7, name: "verify", status: "completed", conclusion: "failure", startedAt: "2026-08-09T12:00:00Z",
        completedAt: "2026-08-09T12:01:00Z", steps: [{ name: "test", status: "completed", conclusion: "failure", number: 3 }],
        annotations: [{ path: ".github/workflows/test.yml", startLine: 12, endLine: 12, level: "failure", title: "Process completed", message: "exit code 1" }],
        diagnosticTail: [], diagnosticError: null }],
    }] });
    expect(fetchMock.mock.calls[0]?.[0]).toContain("daily-engine.yml/runs?per_page=1");
    expect(fetchMock.mock.calls[1]?.[0]).toContain("actions/runs/42/jobs?per_page=20");
    expect(fetchMock.mock.calls[2]?.[0]).toContain("check-runs/7/annotations?per_page=50");
  });

  it("rejects missing configuration and GitHub API failures", async () => {
    await expect(githubWorkflowRuns({} as WorkerEnv)).rejects.toThrow("not configured");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response("forbidden", { status: 403 })));
    await expect(githubWorkflowRuns(configuredEnv)).rejects.toThrow("returned 403");
  });

  it("falls back to a short redacted failed-job log tail when annotations are forbidden", async () => {
    const lines = Array.from({ length: 70 }, (_, index) => `line ${index}`);
    lines.push("token=github_pat_SENSITIVEVALUE", "##[error]adapter failed");
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ workflow_runs: [{ id: 42, conclusion: "failure" }] }), { status: 200 }))
      .mockResolvedValueOnce(new Response(JSON.stringify({ jobs: [{ id: 7, conclusion: "failure" }] }), { status: 200 }))
      .mockResolvedValueOnce(new Response("forbidden", { status: 403 }))
      .mockResolvedValueOnce(new Response(lines.join("\n"), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await githubWorkflowRuns(configuredEnv, 1);
    const job = (result.runs[0]?.jobs as Array<{ diagnosticTail: string[] }>)[0];

    expect(job?.diagnosticTail).toHaveLength(60);
    expect(job?.diagnosticTail.at(-2)).toBe("token=[REDACTED]");
    expect(job?.diagnosticTail.at(-1)).toBe("##[error]adapter failed");
    expect(fetchMock.mock.calls[3]?.[0]).toContain("actions/jobs/7/logs");
  });

  it("keeps early failure context when a long cleanup tail follows", async () => {
    const lines = [
      "setup",
      "adapter starting",
      "TC_LOCAL_MUTATION_SECRET=must-not-leak",
      "##[error]required production date 2026-08-09 was not captured",
      "adapter stopped",
      ...Array.from({ length: 100 }, (_, index) => `cleanup ${index}`),
    ];
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(new Response(JSON.stringify({ workflow_runs: [{ id: 11, status: "completed", conclusion: "failure" }] })))
      .mockResolvedValueOnce(new Response(JSON.stringify({ jobs: [{ id: 12, name: "scheduled operation", status: "completed", conclusion: "failure" }] })))
      .mockResolvedValueOnce(new Response("forbidden", { status: 403 }))
      .mockResolvedValueOnce(new Response(lines.join("\n")));
    vi.stubGlobal("fetch", fetchMock);

    const result = await githubWorkflowRuns(configuredEnv, 1);
    const job = (result.runs[0]?.jobs as Array<{ diagnosticTail: string[] }>)[0];
    expect(job?.diagnosticTail.length).toBeLessThanOrEqual(60);
    expect(job?.diagnosticTail).toContain("TC_LOCAL_MUTATION_SECRET=[REDACTED]");
    expect(job?.diagnosticTail).toContain("##[error]required production date 2026-08-09 was not captured");
    expect(job?.diagnosticTail.at(-1)).toBe("cleanup 99");
  });
});
