import { milestoneEvidenceSummary } from "./milestone-evidence";

interface GateState { gate: string; required: number; achieved: number; complete: boolean; periods: string[] }

export async function transitionReadiness(db: D1Database): Promise<Array<Record<string, unknown>>> {
  const summary = await milestoneEvidenceSummary(db) as { gates?: GateState[]; entitlements?: { complete?: boolean; required?: string[]; verified?: string[] } };
  const gates = new Map((summary.gates ?? []).map((gate) => [gate.gate, gate]));
  const schedules = await db.prepare(
    `SELECT job, retirement_gate, executor, authority_executor, lifecycle, active
       FROM job_schedules WHERE lifecycle = 'transition' ORDER BY job`,
  ).all<{ job: string; retirement_gate: string; executor: string; authority_executor: string | null; lifecycle: string; active: number }>();
  return schedules.results.map((schedule) => {
    const evidence = schedule.retirement_gate === "entitlement-state"
      ? { gate: schedule.retirement_gate, complete: summary.entitlements?.complete === true, ...(summary.entitlements ?? {}) }
      : gates.get(schedule.retirement_gate) ?? { gate: schedule.retirement_gate, complete: false, reason: "gate is not recognized" };
    return { ...schedule, eligible: evidence.complete === true, evidence };
  });
}

