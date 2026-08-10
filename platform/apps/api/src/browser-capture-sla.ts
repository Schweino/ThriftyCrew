export const STRICT_BROWSER_SLA_START = "2026-08-12";

export const REQUIRED_BROWSER_CAPTURE_SOURCES = [
  "direct-aldi-browser",
  "direct-fareway-browser",
  "direct-sams-browser",
  "direct-walmart-browser",
] as const;

export interface BrowserCaptureSlaRow {
  source_id: string;
  batch_id: string;
  captured_to: string;
  coverage_mode: string;
  status: string;
  has_screenshot: number;
  has_manifest: number;
  has_raw_payload: number;
  has_match: number;
}

export interface BrowserCaptureSlaAssessment {
  cycleStart: string;
  cycleEnd: string;
  deadlineLocal: string;
  enforced: boolean;
  deadlineExpired: boolean;
  ready: boolean;
  readySources: string[];
  missing: Array<{ sourceId: string; reasons: string[]; batchId?: string }>;
}

function addDays(dateKey: string, days: number): string {
  const [year, month, day] = dateKey.split("-").map(Number);
  if (!year || !month || !day) throw new Error(`invalid date key ${dateKey}`);
  return new Date(Date.UTC(year, month - 1, day + days)).toISOString().slice(0, 10);
}

export function chicagoClock(instant: Date): { dateKey: string; weekday: number; hour: number; minute: number; sqlModifier: string } {
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-CA", {
    timeZone: "America/Chicago",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
    timeZoneName: "shortOffset",
  }).formatToParts(instant).map((part) => [part.type, part.value]));
  const dateKey = `${parts.year}-${parts.month}-${parts.day}`;
  const offset = /^GMT([+-]\d{1,2})(?::(\d{2}))?$/.exec(parts.timeZoneName ?? "");
  const offsetHours = Number(offset?.[1] ?? -6);
  const offsetMinutes = Number(offset?.[2] ?? 0) * Math.sign(offsetHours || 1);
  const totalMinutes = offsetHours * 60 + offsetMinutes;
  return {
    dateKey,
    weekday: new Date(`${dateKey}T12:00:00.000Z`).getUTCDay(),
    hour: Number(parts.hour),
    minute: Number(parts.minute),
    sqlModifier: `${totalMinutes >= 0 ? "+" : ""}${totalMinutes} minutes`,
  };
}

export function browserCaptureCycleWindow(instant: Date): {
  cycleStart: string;
  cycleEnd: string;
  deadlineLocal: string;
  enforced: boolean;
  deadlineExpired: boolean;
  sqlModifier: string;
} {
  const clock = chicagoClock(instant);
  const cycleStart = addDays(clock.dateKey, -((clock.weekday - 3 + 7) % 7));
  const cycleEnd = addDays(cycleStart, 6);
  const deadlineDay = addDays(cycleStart, 3);
  const deadlineExpired = clock.weekday === 6 && clock.hour >= 12
    || clock.weekday === 0 || clock.weekday === 1 || clock.weekday === 2;
  return {
    cycleStart,
    cycleEnd,
    deadlineLocal: `${deadlineDay}T12:00:00 America/Chicago`,
    enforced: cycleStart >= STRICT_BROWSER_SLA_START,
    deadlineExpired,
    sqlModifier: clock.sqlModifier,
  };
}

export function assessBrowserCaptureSla(rows: readonly BrowserCaptureSlaRow[], instant: Date): BrowserCaptureSlaAssessment {
  const window = browserCaptureCycleWindow(instant);
  const bySource = new Map(rows.map((row) => [row.source_id, row]));
  const readySources: string[] = [];
  const missing: BrowserCaptureSlaAssessment["missing"] = [];
  for (const sourceId of REQUIRED_BROWSER_CAPTURE_SOURCES) {
    const row = bySource.get(sourceId);
    const reasons: string[] = [];
    if (!row) reasons.push("no capture batch in cycle");
    else {
      if (row.coverage_mode !== "full") reasons.push(`coverage is ${row.coverage_mode}`);
      if (row.status !== "promoted" && row.status !== "superseded") reasons.push(`batch is ${row.status}`);
      if (row.has_screenshot !== 1) reasons.push("screenshot evidence missing");
      if (row.has_manifest !== 1) reasons.push("session manifest missing");
      if (row.has_raw_payload !== 1) reasons.push("projected raw evidence missing");
      if (row.has_match !== 1) reasons.push("passed matching missing");
    }
    if (reasons.length === 0) readySources.push(sourceId);
    else missing.push({ sourceId, reasons, ...(row ? { batchId: row.batch_id } : {}) });
  }
  return {
    cycleStart: window.cycleStart,
    cycleEnd: window.cycleEnd,
    deadlineLocal: window.deadlineLocal,
    enforced: window.enforced,
    deadlineExpired: window.deadlineExpired,
    ready: missing.length === 0,
    readySources,
    missing,
  };
}

export async function readBrowserCaptureSla(db: D1Database, instant = new Date()): Promise<BrowserCaptureSlaAssessment> {
  const window = browserCaptureCycleWindow(instant);
  const placeholders = REQUIRED_BROWSER_CAPTURE_SOURCES.map((_, index) => `?${index + 1}`).join(",");
  const rows = await db.prepare(
    `WITH ranked AS (
       SELECT batch.source_id, batch.id AS batch_id, batch.captured_to, batch.coverage_mode, batch.status,
              ROW_NUMBER() OVER (PARTITION BY batch.source_id ORDER BY batch.captured_to DESC, batch.id DESC) AS ordinal
         FROM capture_batches batch
        WHERE batch.source_id IN (${placeholders})
          AND date(batch.captured_to, ?5) BETWEEN ?6 AND ?7
     )
     SELECT ranked.source_id, ranked.batch_id, ranked.captured_to, ranked.coverage_mode, ranked.status,
            EXISTS (SELECT 1 FROM evidence_objects evidence WHERE evidence.batch_id = ranked.batch_id AND evidence.kind = 'screenshot') AS has_screenshot,
            EXISTS (SELECT 1 FROM evidence_objects evidence WHERE evidence.batch_id = ranked.batch_id AND evidence.kind = 'manifest') AS has_manifest,
            EXISTS (SELECT 1 FROM evidence_objects evidence WHERE evidence.batch_id = ranked.batch_id AND evidence.kind = 'raw_payload') AS has_raw_payload,
            EXISTS (SELECT 1 FROM match_runs matching WHERE matching.batch_id = ranked.batch_id AND matching.status = 'passed') AS has_match
       FROM ranked WHERE ordinal = 1 ORDER BY source_id`,
  ).bind(...REQUIRED_BROWSER_CAPTURE_SOURCES, window.sqlModifier, window.cycleStart, window.cycleEnd).all<BrowserCaptureSlaRow>();
  return assessBrowserCaptureSla(rows.results, instant);
}
