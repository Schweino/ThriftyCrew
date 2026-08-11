import { readFile, readdir } from "node:fs/promises";
import path from "node:path";
import { scheduleDocumentSchema, transitionInventorySchema, type ScheduleDocument } from "@thriftycrew/contracts";

export async function readScheduleAuthority(platformRoot: string) {
  const file = path.join(platformRoot, "config", "schedules.json");
  return scheduleDocumentSchema.parse(JSON.parse(await readFile(file, "utf8")));
}

export function workflowCrons(source: string): string[] {
  return [...source.matchAll(/^\s*-\s*cron:\s*["']([^"']+)["']/gm)].map((match) => match[1] as string);
}

export function automaticWorkflowTriggers(source: string): string[] {
  const lines = source.split(/\r?\n/);
  const triggers = new Set<string>();
  let inOn = false;
  for (const line of lines) {
    if (/^on:\s*\{/.test(line)) {
      for (const trigger of ["push", "pull_request", "schedule"]) {
        if (new RegExp(`\\b${trigger.replace("_", "_")}\\s*:`).test(line)) triggers.add(trigger);
      }
      continue;
    }
    if (/^on:\s*$/.test(line)) { inOn = true; continue; }
    if (inOn && /^\S/.test(line)) inOn = false;
    if (inOn) {
      const match = /^\s{2}(push|pull_request|schedule):/.exec(line);
      if (match?.[1]) triggers.add(match[1]);
    }
  }
  return [...triggers].sort();
}

export function scheduleDiff(expectedValues: Iterable<string>, actualValues: Iterable<string>): { missing: string[]; rogue: string[] } {
  const expected = new Set(expectedValues);
  const actual = new Set(actualValues);
  return {
    missing: [...expected].filter((value) => !actual.has(value)).sort(),
    rogue: [...actual].filter((value) => !expected.has(value)).sort(),
  };
}

async function verifyGithubSchedules(platformRoot: string, document: ScheduleDocument): Promise<Record<string, unknown>> {
  const incomeRoot = path.resolve(platformRoot, "..");
  const byWorkflow = new Map<string, Set<string>>();
  for (const schedule of document.schedules.filter((entry) => entry.executor === "github-actions" && entry.lifecycle !== "retired" && !entry.suspended)) {
    const expected = byWorkflow.get(schedule.workflowFile!) ?? new Set<string>();
    expected.add(schedule.cron);
    byWorkflow.set(schedule.workflowFile!, expected);
  }
  const verified: Record<string, unknown> = {};
  for (const [workflowFile, expected] of byWorkflow) {
    const source = await readFile(path.join(incomeRoot, workflowFile), "utf8");
    const actual = new Set(workflowCrons(source));
    const { missing, rogue } = scheduleDiff(expected, actual);
    if (missing.length || rogue.length) throw new Error(`${workflowFile} schedule drift: ${JSON.stringify({ missing, rogue })}`);
    verified[workflowFile] = [...actual].sort();
  }
  const workflowDirectory = path.join(incomeRoot, ".github", "workflows");
  for (const file of (await readdir(workflowDirectory)).filter((name) => /\.ya?ml$/i.test(name))) {
    const source = await readFile(path.join(workflowDirectory, file), "utf8");
    const automatic = automaticWorkflowTriggers(source);
    if (automatic.length) throw new Error(`${file} violates manual-fallback GitHub Actions policy: ${automatic.join(", ")}`);
  }
  return verified;
}

async function verifyWorkerSchedules(platformRoot: string, document: ScheduleDocument): Promise<string[]> {
  const source = await readFile(path.join(platformRoot, "wrangler.jsonc"), "utf8");
  const match = /"crons"\s*:\s*\[([^\]]*)\]/s.exec(source);
  const actual = match ? [...match[1]!.matchAll(/["']([^"']+)["']/g)].map((value) => value[1] as string) : [];
  const expected = document.schedules
    .filter((entry) => entry.executor === "worker-cron" && entry.lifecycle !== "retired" && !entry.suspended)
    .map((entry) => entry.triggerCron ?? entry.cron);
  const { missing, rogue } = scheduleDiff(expected, actual);
  if (missing.length || rogue.length) throw new Error(`wrangler cron drift: ${JSON.stringify({ missing, rogue })}`);
  return actual;
}

async function verifyWindowsInventory(platformRoot: string, document: ScheduleDocument): Promise<string[]> {
  const registry = JSON.parse(await readFile(path.resolve(platformRoot, "..", "grocery", "expected-automations.json"), "utf8")) as {
    windows_tasks?: Array<{ name?: string }>;
    startup_entries?: Array<{ name?: string }>;
  };
  const actual = new Set((registry.windows_tasks ?? []).map((entry) => entry.name).filter((name): name is string => Boolean(name)));
  const expected = new Set(document.schedules.filter((entry) => entry.executor === "pc" && entry.lifecycle !== "retired" && !entry.suspended).map((entry) => entry.windowsTask!));
  const { missing, rogue } = scheduleDiff(expected, actual);
  if (missing.length || rogue.length) throw new Error(`Windows task registry drift: ${JSON.stringify({ missing, rogue })}`);
  return [...actual].sort();
}

async function verifyStartupInventory(platformRoot: string, document: ScheduleDocument): Promise<string[]> {
  const registry = JSON.parse(await readFile(path.resolve(platformRoot, "..", "grocery", "expected-automations.json"), "utf8")) as {
    startup_entries?: Array<{ name?: string }>;
  };
  const actual = new Set((registry.startup_entries ?? []).map((entry) => entry.name).filter((name): name is string => Boolean(name)));
  const expected = new Set(document.schedules.filter((entry) => entry.executor === "pc-startup" && entry.lifecycle !== "retired" && !entry.suspended).map((entry) => entry.startupEntry!));
  const { missing, rogue } = scheduleDiff(expected, actual);
  if (missing.length || rogue.length) throw new Error(`PC startup registry drift: ${JSON.stringify({ missing, rogue })}`);
  return [...actual].sort();
}

async function verifyCodexAutomations(platformRoot: string, document: ScheduleDocument): Promise<Record<string, unknown>> {
  const verified: Record<string, unknown> = {};
  for (const schedule of document.schedules.filter((entry) => entry.executor === "codex-automation" && entry.lifecycle !== "retired")) {
    const authorityFile = path.join(platformRoot, schedule.automationFile!);
    const authority = JSON.parse(await readFile(authorityFile, "utf8")) as { id?: string; cron?: string; timezone?: string; promptFile?: string };
    if (authority.id !== schedule.id || authority.cron !== schedule.cron || authority.timezone !== document.timezone || !authority.promptFile) {
      throw new Error(`Codex automation authority drift for ${schedule.id}`);
    }
    await readFile(path.join(platformRoot, authority.promptFile), "utf8");
    verified[schedule.id] = { authorityFile: schedule.automationFile, promptFile: authority.promptFile };
  }
  return verified;
}

export async function checkScheduleAuthority(platformRoot: string): Promise<Record<string, unknown>> {
  const document = await readScheduleAuthority(platformRoot);
  const inventory = transitionInventorySchema.parse(JSON.parse(await readFile(path.join(platformRoot, "config", "transition-inventory.json"), "utf8")));
  const inventoryScheduleIds = new Set(inventory.executors.map((entry) => entry.scheduleId).filter(Boolean));
  const unknownInventorySchedules = [...inventoryScheduleIds].filter((id) => !document.schedules.some((entry) => entry.id === id));
  if (unknownInventorySchedules.length) throw new Error(`transition inventory has unknown schedules: ${unknownInventorySchedules.join(", ")}`);
  const transitionSchedules = document.schedules.filter((entry) => entry.lifecycle === "transition");
  const transitionByInventoryId = new Map(transitionSchedules.map((entry) => [entry.inventoryId, entry]));
  const inventoryIds = new Set(inventory.executors.map((entry) => entry.id));
  const missingInventory = transitionSchedules.filter((entry) => !entry.inventoryId || !inventoryIds.has(entry.inventoryId)).map((entry) => entry.id);
  const rogueInventory = inventory.executors.filter((entry) => entry.lifecycle === "transition" && !transitionByInventoryId.has(entry.id)).map((entry) => entry.id);
  if (missingInventory.length || rogueInventory.length) throw new Error(`transition inventory drift: ${JSON.stringify({ missingInventory, rogueInventory })}`);
  const gateIds = new Set(inventory.evidenceGates.map((gate) => gate.id));
  for (const schedule of transitionSchedules) {
    const inventoryEntry = inventory.executors.find((entry) => entry.id === schedule.inventoryId);
    if (!inventoryEntry || inventoryEntry.scheduleId !== schedule.id || inventoryEntry.scope !== schedule.inventoryScope || inventoryEntry.retirementGate !== schedule.retirementGate) {
      throw new Error(`transition inventory identity drift for ${schedule.id}`);
    }
    if (!gateIds.has(schedule.retirementGate!)) throw new Error(`transition schedule ${schedule.id} references unknown evidence gate ${schedule.retirementGate}`);
  }
  const [github, workerCrons, windowsTasks, startupEntries, codexAutomations] = await Promise.all([
    verifyGithubSchedules(platformRoot, document),
    verifyWorkerSchedules(platformRoot, document),
    verifyWindowsInventory(platformRoot, document),
    verifyStartupInventory(platformRoot, document),
    verifyCodexAutomations(platformRoot, document),
  ]);
  return {
    ok: true,
    version: document.version,
    timezone: document.timezone,
    schedules: document.schedules.length,
    active: document.schedules.filter((entry) => entry.lifecycle === "active").length,
    transition: document.schedules.filter((entry) => entry.lifecycle === "transition").length,
    retired: document.schedules.filter((entry) => entry.lifecycle === "retired").length,
    executors: Object.fromEntries([...new Set(document.schedules.map((schedule) => schedule.executor))].sort().map((executor) => [executor, document.schedules.filter((schedule) => schedule.executor === executor).length])),
    verified: { github, workerCrons, windowsTasks, startupEntries, codexAutomations, transitionInventoryVersion: inventory.version },
  };
}
