import { readFile, readdir } from "node:fs/promises";
import path from "node:path";

export const SERVER_CAPTURE_STORES = ["bakers", "family-fare", "hy-vee"] as const;
export type ServerCaptureStore = typeof SERVER_CAPTURE_STORES[number];

const FILE_PREFIX: Record<ServerCaptureStore, string> = {
  bakers: "bakers",
  "family-fare": "family-fare",
  "hy-vee": "hyvee",
};

export function parseServerCaptureStore(value: string): ServerCaptureStore {
  const normalized = value.trim().toLowerCase();
  if (normalized === "hyvee") return "hy-vee";
  if ((SERVER_CAPTURE_STORES as readonly string[]).includes(normalized)) return normalized as ServerCaptureStore;
  throw new Error(`unsupported server capture store ${value}`);
}

export function omahaDateKey(instant: Date): string {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Chicago",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(instant).map((part) => [part.type, part.value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

export async function findLatestRegularCapture(regularDirectory: string, store: ServerCaptureStore): Promise<string> {
  const prefix = FILE_PREFIX[store];
  const pattern = new RegExp(`^${prefix}-regular-(\\d{4}-\\d{2}-\\d{2})[.]json$`);
  const candidates = (await readdir(regularDirectory))
    .flatMap((name) => {
      const match = name.match(pattern);
      return match ? [{ name, date: match[1]! }] : [];
    })
    .sort((left, right) => right.date.localeCompare(left.date) || right.name.localeCompare(left.name));
  if (!candidates[0]) throw new Error(`no regular capture exists for ${store} in ${regularDirectory}`);
  return path.join(regularDirectory, candidates[0].name);
}

function rowCaptureDates(document: Record<string, unknown>): string[] {
  const rows = Array.isArray(document.deals) ? document.deals : [];
  return rows.flatMap((row) => {
    if (!row || typeof row !== "object") return [];
    const value = (row as Record<string, unknown>).as_of;
    return typeof value === "string" && /^\d{4}-\d{2}-\d{2}/.test(value) ? [value.slice(0, 10)] : [];
  });
}

export async function readFreshRegularCapture(
  file: string,
  options: { now?: Date; maximumAgeHours?: number; requiredDate?: string } = {},
): Promise<{ document: Record<string, unknown>; newestCaptureDate: string; oldestCaptureDate: string; rows: number }> {
  const document = JSON.parse((await readFile(file, "utf8")).replace(/^\uFEFF/, "")) as Record<string, unknown>;
  const deals = Array.isArray(document.deals) ? document.deals : [];
  if (deals.length === 0) throw new Error(`${file} contains no deals`);
  const dates = rowCaptureDates(document).sort();
  const generated = typeof document.generated === "string" && /^\d{4}-\d{2}-\d{2}/.test(document.generated)
    ? document.generated.slice(0, 10)
    : undefined;
  const newestCaptureDate = dates.at(-1) ?? generated;
  const oldestCaptureDate = dates[0] ?? generated;
  if (!newestCaptureDate || !oldestCaptureDate) throw new Error(`${file} has no capture dates`);
  if (options.requiredDate && newestCaptureDate !== options.requiredDate) {
    throw new Error(`${file} did not capture the required production date ${options.requiredDate}; newest is ${newestCaptureDate}`);
  }
  const now = options.now ?? new Date();
  const captureEnd = Date.parse(`${newestCaptureDate}T23:59:59-05:00`);
  const ageHours = (now.getTime() - captureEnd) / 3_600_000;
  if (!Number.isFinite(ageHours) || ageHours > (options.maximumAgeHours ?? 36)) {
    throw new Error(`${file} is stale: newest captured date ${newestCaptureDate}`);
  }
  if (ageHours < -24) throw new Error(`${file} has an implausible future capture date ${newestCaptureDate}`);
  return { document, newestCaptureDate, oldestCaptureDate, rows: deals.length };
}
