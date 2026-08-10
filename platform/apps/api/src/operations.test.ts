import { afterEach, describe, expect, it, vi } from "vitest";
import { githubWorkflowRuns } from "./operations";
import type { WorkerEnv } from "./env";

const configuredEnv = {
  GITHUB_DISPATCH_TOKEN: "test-token",
  GITHUB_REPOSITORY: "owner/private-repo",
  GITHUB_WORKFLOW_FILE: "daily-engine.yml",
} as WorkerEnv;

afterEach(() => vi.unstubAllGlobals());

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
      }] }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await githubWorkflowRuns(configuredEnv, 1);

    expect(result).toEqual({ runs: [{
      id: 42, event: "workflow_dispatch", status: "completed", conclusion: "failure", headSha: "abc",
      createdAt: "2026-08-09T12:00:00Z", updatedAt: "2026-08-09T12:01:00Z", url: "https://github.test/run/42",
      jobs: [{ id: 7, name: "verify", status: "completed", conclusion: "failure", startedAt: "2026-08-09T12:00:00Z",
        completedAt: "2026-08-09T12:01:00Z", steps: [{ name: "test", status: "completed", conclusion: "failure", number: 3 }] }],
    }] });
    expect(fetchMock.mock.calls[0]?.[0]).toContain("daily-engine.yml/runs?per_page=1");
    expect(fetchMock.mock.calls[1]?.[0]).toContain("actions/runs/42/jobs?per_page=20");
  });

  it("rejects missing configuration and GitHub API failures", async () => {
    await expect(githubWorkflowRuns({} as WorkerEnv)).rejects.toThrow("not configured");
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response("forbidden", { status: 403 })));
    await expect(githubWorkflowRuns(configuredEnv)).rejects.toThrow("returned 403");
  });
});
