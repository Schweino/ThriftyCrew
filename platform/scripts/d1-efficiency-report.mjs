import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));
const policy = JSON.parse(await readFile(new URL("../config/efficiency-budgets.json", import.meta.url), "utf8"));

function fingerprint(query) {
  return createHash("sha256").update(query.replaceAll(/\s+/g, " ").trim()).digest("hex").slice(0, 16);
}

export function evaluateD1Efficiency(insights, budgets = policy.budgets) {
  const operational = insights.filter((item) => !/^\s*(?:CREATE|ALTER|DROP|PRAGMA)\b/i.test(item.query));
  const queries = [...new Map(operational.map((item) => [fingerprint(item.query), { ...item, fingerprint: fingerprint(item.query) }])).values()];
  const findings = [];
  for (const query of queries) {
    if (query.avgRowsRead > budgets.averageRowsReadPerQuery) findings.push({
      fingerprint: query.fingerprint, metric: "averageRowsReadPerQuery", observed: query.avgRowsRead, budget: budgets.averageRowsReadPerQuery,
    });
    if (query.avgDurationMs > budgets.averageDurationMs) findings.push({
      fingerprint: query.fingerprint, metric: "averageDurationMs", observed: query.avgDurationMs, budget: budgets.averageDurationMs,
    });
    if (query.totalRowsWritten > budgets.totalRowsWrittenPerFingerprint) findings.push({
      fingerprint: query.fingerprint, metric: "totalRowsWrittenPerFingerprint", observed: query.totalRowsWritten, budget: budgets.totalRowsWrittenPerFingerprint,
    });
  }
  return {
    ok: findings.length === 0,
    findings,
    queries: queries.map(({ query, ...metrics }) => ({ ...metrics, query: query.replaceAll(/\s+/g, " ").trim().slice(0, 240) })),
  };
}

function readInsights(sortBy, period) {
  const wrangler = fileURLToPath(new URL("../bin/wrangler.js", import.meta.resolve("wrangler")));
  const result = spawnSync(process.execPath, [wrangler, "d1", "insights", policy.database, "--time-period", period,
    "--sort-type", "sum", "--sort-by", sortBy, "--limit", String(policy.queryLimit), "--json"], { cwd: root, encoding: "utf8" });
  if (result.status !== 0) throw new Error(result.stderr || `wrangler d1 insights failed for ${sortBy}`);
  return JSON.parse(result.stdout);
}

if (process.argv.includes("--self-test")) {
  const report = evaluateD1Efficiency([{
    query: "SELECT * FROM observations", avgRowsRead: 6_000_000, totalRowsRead: 6_000_000,
    avgRowsWritten: 0, totalRowsWritten: 0, avgDurationMs: 100, totalDurationMs: 100,
    numberOfTimesRun: 1, queryEfficiency: 0,
  }]);
  if (report.ok || report.findings[0]?.metric !== "averageRowsReadPerQuery") throw new Error("efficiency budget self-test failed");
  const maintenance = evaluateD1Efficiency([{
    query: "CREATE INDEX example ON observations(batch_id)", avgRowsRead: 9_000_000, totalRowsRead: 9_000_000,
    avgRowsWritten: 9_000_000, totalRowsWritten: 9_000_000, avgDurationMs: 9_000, totalDurationMs: 9_000,
    numberOfTimesRun: 1, queryEfficiency: 0,
  }]);
  if (!maintenance.ok || maintenance.queries.length !== 0) throw new Error("efficiency budget must exclude one-time schema maintenance");
  console.log(JSON.stringify({ ok: true, selfTest: true }));
} else {
  const periodArgument = process.argv.find((value) => /^\d+[mhd]$/.test(value));
  const period = periodArgument ?? policy.defaultPeriod;
  const report = evaluateD1Efficiency([...readInsights("reads", period), ...readInsights("writes", period)]);
  console.log(JSON.stringify({ ...report, period, policyVersion: policy.version }, null, 2));
  if (!report.ok && process.argv.includes("--enforce")) process.exitCode = 2;
}
