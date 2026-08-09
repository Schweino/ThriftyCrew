import { readFile } from "node:fs/promises";
import path from "node:path";
import { scheduleDocumentSchema } from "@thriftycrew/contracts";

export async function readScheduleAuthority(platformRoot: string) {
  const file = path.join(platformRoot, "config", "schedules.json");
  const parsed = JSON.parse(await readFile(file, "utf8"));
  return scheduleDocumentSchema.parse(parsed);
}

export async function checkScheduleAuthority(platformRoot: string): Promise<Record<string, unknown>> {
  const document = await readScheduleAuthority(platformRoot);
  return {
    ok: true,
    version: document.version,
    timezone: document.timezone,
    schedules: document.schedules.length,
    executors: Object.fromEntries(
      [...new Set(document.schedules.map((schedule) => schedule.executor))]
        .sort()
        .map((executor) => [executor, document.schedules.filter((schedule) => schedule.executor === executor).length]),
    ),
  };
}
