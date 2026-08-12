import { afterEach, describe, expect, it, vi } from "vitest";
import { archivalCapacityStatus, archivalGrowthProjectionReliable, controlPlaneProofPass, d1DatabaseFileSize, d1TimeTravelBookmark, githubActionsDispatchEnabled, githubDispatchInputs, githubWorkflowRuns, jobStatusRequiresAlert, operationalDigestMemberKey, operationalIncidentIsNew, operationalNotificationDueAt, recoveryCheckpointTriggerKind, resumeFailedCapturePipelines, robustMonthlyGrowth, scheduleGap, weeklyRecoveryManifestDue } from "./operations";

describe("archival capacity policy", () => {
  it("arms on projected exhaustion before the static percentage threshold", () => {
    expect(archivalCapacityStatus(5_500, "2026-10-01T00:00:00.000Z", "2026-08-11T00:00:00.000Z")).toBe("armed");
    expect(archivalCapacityStatus(5_500, "2026-08-25T00:00:00.000Z", "2026-08-11T00:00:00.000Z")).toBe("critical");
  });

  it("uses a median growth rate so one spike cannot dominate a longer sample", () => {
    const history = [
      { database_bytes: 100, observed_at: "2026-08-08T00:00:00.000Z" },
      { database_bytes: 110, observed_at: "2026-08-09T00:00:00.000Z" },
      { database_bytes: 1_110, observed_at: "2026-08-10T00:00:00.000Z" },
    ];
    expect(robustMonthlyGrowth(history, 1_120, "2026-08-11T00:00:00.000Z")).toBe(300);
  });

  it("does not extrapolate migration spikes until seven distinct days establish a trend", () => {
    expect(archivalGrowthProjectionReliable([
      { observed_at: "2026-08-10T00:00:00.000Z" },
      { observed_at: "2026-08-11T10:00:00.000Z" },
    ], "2026-08-11T12:00:00.000Z")).toBe(false);
    expect(archivalGrowthProjectionReliable(Array.from({ length: 6 }, (_, index) => ({
      observed_at: `2026-08-${String(index + 5).padStart(2, "0")}T12:00:00.000Z`,
    })), "2026-08-11T12:00:00.000Z")).toBe(true);
  });
});

describe("cross-plane proof policy", () => {
  it("fails only required checks", () => {
    expect(controlPlaneProofPass([{ required: true, ok: true }, { required: false, ok: false }])).toBe(true);
    expect(controlPlaneProofPass([{ required: true, ok: false }])).toBe(false);
  });
});

describe("D1 recovery cadence", () => {
  it("uses only trigger kinds accepted by the durable job ledger", () => {
    expect(recoveryCheckpointTriggerKind(false)).toBe("schedule");
    expect(recoveryCheckpointTriggerKind(true)).toBe("operator");
  });

  it("schedules the lightweight recovery manifest for Sunday at 01:30 America/Chicago", () => {
    expect(weeklyRecoveryManifestDue(Date.parse("2026-08-16T06:30:00.000Z"))).toBe(true);
    expect(weeklyRecoveryManifestDue(Date.parse("2026-08-16T09:30:00.000Z"))).toBe(false);
    expect(weeklyRecoveryManifestDue(Date.parse("2026-08-17T06:30:00.000Z"))).toBe(false);
  });

  it("retrieves the current Time Travel bookmark through the authorized REST API", async () => {
    const fetchMock = vi.fn().mockResolvedValue(new Response(JSON.stringify({ success: true, result: { bookmark: "bookmark-123" } })));
    vi.stubGlobal("fetch", fetchMock);
    await expect(d1TimeTravelBookmark({
      D1_REST_API_TOKEN: "test-token",
      CLOUDFLARE_ACCOUNT_ID: "account",
      D1_DATABASE_ID: "database",
    } as WorkerEnv)).resolves.toBe("bookmark-123");
    expect(fetchMock.mock.calls[0]?.[0]).toContain("/accounts/account/d1/database/database/time_travel/bookmark");
  });

  it("fails closed when Time Travel credentials or a bookmark are unavailable", async () => {
    await expect(d1TimeTravelBookmark({} as WorkerEnv)).rejects.toThrow("credentials");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(JSON.stringify({ success: true, result: {} }))));
    await expect(d1TimeTravelBookmark({
      D1_REST_API_TOKEN: "x", CLOUDFLARE_ACCOUNT_ID: "a", D1_DATABASE_ID: "d",
    } as WorkerEnv)).rejects.toThrow("bookmark request failed");
  });
});

describe("capture pipeline recovery", () => {
  it("restarts a failed incomplete event pipeline with a fresh workflow instance", async () => {
    const create = vi.fn().mockResolvedValue(undefined);
    const updates: unknown[][] = [];
    const db = {
      prepare(sql: string) {
        if (sql.includes("SELECT job.batch_id")) return { all: async () => ({ results: [{ batch_id: "batch-1", attempts: 2 }] }) };
        return {
          bind: (...values: unknown[]) => ({
            run: async () => {
              updates.push(values);
              return { meta: { changes: 1 } };
            },
          }),
        };
      },
    };
    const resumed = await resumeFailedCapturePipelines({ DB: db, CAPTURE_VALIDATION_WORKFLOW: { create } } as unknown as WorkerEnv, Date.parse("2026-08-11T15:30:00.000Z"));
    expect(resumed).toBe(1);
    expect(create).toHaveBeenCalledWith(expect.objectContaining({ params: { batchId: "batch-1" } }));
    expect(updates[0]?.[0]).toBe("batch-1");
  });
});
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

describe("operational notification policy", () => {
  it("uses deterministic grace windows for digest delivery", () => {
    expect(operationalNotificationDueAt("2026-08-10T14:00:00.000Z", 15)).toBe("2026-08-10T14:15:00.000Z");
    expect(operationalNotificationDueAt("2026-08-10T14:00:00.000Z", 30)).toBe("2026-08-10T14:30:00.000Z");
  });

  it("rejects invalid digest timing evidence", () => {
    expect(() => operationalNotificationDueAt("not-a-date", 15)).toThrow(/invalid/);
    expect(() => operationalNotificationDueAt("2026-08-10T14:00:00.000Z", -1)).toThrow(/invalid/);
  });

  it("notifies once per open incident and rearms only after resolution", () => {
    expect(operationalIncidentIsNew(undefined)).toBe(true);
    expect(operationalIncidentIsNew(null)).toBe(true);
    expect(operationalIncidentIsNew("resolved")).toBe(true);
    expect(operationalIncidentIsNew("open")).toBe(false);
    expect(operationalIncidentIsNew("needs_operator")).toBe(false);
  });

  it("keys digest acknowledgement to the incident deadline, not mutable triage timestamps", () => {
    expect(operationalDigestMemberKey("schedule-gap:daily", "2026-08-10T14:15:00.000Z"))
      .toBe("schedule-gap:daily@2026-08-10T14:15:00.000Z");
    expect(operationalDigestMemberKey("schedule-gap:daily", "2026-08-11T14:15:00.000Z"))
      .not.toBe(operationalDigestMemberKey("schedule-gap:daily", "2026-08-10T14:15:00.000Z"));
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

  it("uses a newer monitoring start as warm-up after authority changes", () => {
    expect(scheduleGap("2026-08-10T08:00:00.000Z", "2026-08-10T11:00:00.000Z", checkedAt, 120)).toEqual({
      stale: false,
      ageMinutes: 60,
      basis: "monitoring-grace",
    });
  });

  it("uses durable run evidence after warm-up and fails closed without a valid timestamp", () => {
    expect(scheduleGap("2026-08-10T11:30:00.000Z", "2026-08-10T11:00:00.000Z", checkedAt, 120)).toEqual({
      stale: false,
      ageMinutes: 30,
      basis: "run",
    });
    expect(scheduleGap("invalid", "2026-08-10T11:00:00.000Z", checkedAt, 120)).toEqual({
      stale: false,
      ageMinutes: 60,
      basis: "monitoring-grace",
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
  it("defaults automatic hosted-runner dispatch to fail closed", () => {
    expect(githubActionsDispatchEnabled({})).toBe(false);
    expect(githubActionsDispatchEnabled({ GITHUB_ACTIONS_DISPATCH_ENABLED: "0" })).toBe(false);
    expect(githubActionsDispatchEnabled({ GITHUB_ACTIONS_DISPATCH_ENABLED: "1" })).toBe(true);
  });

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
