import { deterministicId, stableJson } from "@thriftycrew/domain";
import type { WorkerEnv } from "./env";

export interface PromotionCalendarRow {
  store_location_id: string;
  store_name: string;
  capture_lane: "headless" | "browser";
  current_valid_from: string | null;
  current_valid_to: string | null;
}

export interface PromotionRequestSpec {
  id: string;
  storeLocationId: string;
  requestKind: "prefetch" | "activate" | "expire" | "post_verify";
  captureLane: "headless" | "browser";
  validFrom: string;
  validTo: string;
  dueAt: string;
}

const HOUR = 60 * 60_000;

export async function promotionRequestPlan(calendar: PromotionCalendarRow, observedAt: string): Promise<PromotionRequestSpec[]> {
  if (!calendar.current_valid_from || !calendar.current_valid_to) return [];
  const now = Date.parse(observedAt);
  const from = Date.parse(calendar.current_valid_from);
  const to = Date.parse(calendar.current_valid_to);
  if (![now, from, to].every(Number.isFinite) || to <= from) throw new Error(`Invalid promotion calendar for ${calendar.store_location_id}`);
  const events: Array<[PromotionRequestSpec["requestKind"], number]> = [
    ["prefetch", from - 6 * HOUR],
    ["activate", from],
    ["post_verify", from + HOUR],
    ["expire", to],
  ];
  // Retain a one-day catch-up envelope after Worker/PC downtime. Older start
  // events from an already-running weekly ad are historical, not overdue work.
  return Promise.all(events.filter(([, due]) => due >= now - 24 * HOUR).map(async ([requestKind, due]) => ({
    id: await deterministicId("promotion-request", calendar.store_location_id, requestKind, calendar.current_valid_from!, calendar.current_valid_to!),
    storeLocationId: calendar.store_location_id,
    requestKind,
    captureLane: calendar.capture_lane,
    validFrom: calendar.current_valid_from!,
    validTo: calendar.current_valid_to!,
    dueAt: new Date(due).toISOString(),
  })));
}

export async function runPromotionLifecycle(env: WorkerEnv, scheduledTime: number): Promise<{
  runId: string; status: "pass" | "action_required"; queued: number; expiredCurrentCells: number;
  futureCurrentCells: number; overdue: number;
}> {
  const observedAt = new Date(scheduledTime).toISOString();
  const runId = await deterministicId("promotion-boundary-run", observedAt.slice(0, 16));
  const existing = await env.DB.prepare("SELECT status, queued_requests, expired_current_cells, future_current_cells, overdue_requests FROM promotion_boundary_runs WHERE id = ?1")
    .bind(runId).first<{ status: "pass" | "action_required"; queued_requests: number; expired_current_cells: number; future_current_cells: number; overdue_requests: number }>();
  if (existing) return { runId, status: existing.status, queued: existing.queued_requests, expiredCurrentCells: existing.expired_current_cells, futureCurrentCells: existing.future_current_cells, overdue: existing.overdue_requests };

  const calendars = await env.DB.prepare(
    `SELECT store_location_id, store_name, capture_lane, current_valid_from, current_valid_to
       FROM retailer_ad_calendars ORDER BY store_location_id`,
  ).all<PromotionCalendarRow>();
  const plans = (await Promise.all(calendars.results.map((calendar) => promotionRequestPlan(calendar, observedAt)))).flat();
  let queued = 0;
  for (const plan of plans) {
    const inserted = await env.DB.prepare(
      `INSERT OR IGNORE INTO promotion_capture_requests
         (id, store_location_id, request_kind, capture_lane, window_valid_from, window_valid_to, due_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)`,
    ).bind(plan.id, plan.storeLocationId, plan.requestKind, plan.captureLane, plan.validFrom, plan.validTo, plan.dueAt).run();
    queued += inserted.meta.changes ?? 0;
  }
  const [windowState, overdue] = await Promise.all([
    env.DB.prepare(
      `SELECT
         SUM(CASE WHEN observation.valid_to IS NOT NULL AND julianday(observation.valid_to) <= julianday(?1) THEN 1 ELSE 0 END) AS expired,
         SUM(CASE WHEN observation.valid_from IS NOT NULL AND julianday(observation.valid_from) > julianday(?1) THEN 1 ELSE 0 END) AS future
       FROM current_releases current
       JOIN release_cells cell ON cell.release_id = current.release_id AND cell.status = 'priced'
       JOIN observations observation ON observation.id = cell.observation_id
      WHERE current.market_id = 'omaha'`,
    ).bind(observedAt).first<{ expired: number | null; future: number | null }>(),
    env.DB.prepare(
      `SELECT COUNT(*) AS count FROM promotion_capture_requests
        WHERE status IN ('queued','leased') AND julianday(due_at) <= julianday(?1, '-60 minutes')`,
    ).bind(observedAt).first<{ count: number }>(),
  ]);
  const expiredCurrentCells = windowState?.expired ?? 0;
  const futureCurrentCells = windowState?.future ?? 0;
  const overdueCount = overdue?.count ?? 0;
  const status = expiredCurrentCells || futureCurrentCells || overdueCount ? "action_required" as const : "pass" as const;
  await env.DB.prepare(
    `INSERT INTO promotion_boundary_runs
       (id, observed_at, queued_requests, expired_current_cells, future_current_cells, overdue_requests, status, detail_json)
     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
  ).bind(runId, observedAt, queued, expiredCurrentCells, futureCurrentCells, overdueCount, status,
    stableJson({ calendars: calendars.results.length, planned: plans.length })).run();
  return { runId, status, queued, expiredCurrentCells, futureCurrentCells, overdue: overdueCount };
}
