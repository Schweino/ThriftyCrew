import { stableJson } from "@thriftycrew/domain";

export interface OperationLease {
  resource: string;
  holderId: string;
  ownerKind: "job" | "workflow" | "deployment" | "maintenance";
  fence: number;
  acquiredAt: string;
  heartbeatAt: string;
  expiresAt: string;
}

interface LeaseRow {
  resource: string;
  holder_id: string;
  owner_kind: OperationLease["ownerKind"];
  fence: number;
  acquired_at: string;
  heartbeat_at: string;
  expires_at: string;
}

function leaseFromRow(row: LeaseRow): OperationLease {
  return {
    resource: row.resource,
    holderId: row.holder_id,
    ownerKind: row.owner_kind,
    fence: row.fence,
    acquiredAt: row.acquired_at,
    heartbeatAt: row.heartbeat_at,
    expiresAt: row.expires_at,
  };
}

export function leaseExpiry(now: string, leaseMinutes: number): string {
  if (!Number.isInteger(leaseMinutes) || leaseMinutes < 1 || leaseMinutes > 10_080) throw new Error("lease duration is outside policy");
  const epoch = Date.parse(now);
  if (!Number.isFinite(epoch)) throw new Error("lease timestamp is invalid");
  return new Date(epoch + leaseMinutes * 60_000).toISOString();
}

export async function acquireOperationLease(
  db: D1Database,
  input: {
    resource: string;
    holderId: string;
    ownerKind: OperationLease["ownerKind"];
    leaseMinutes: number;
    now?: string;
    metadata?: Record<string, unknown>;
  },
): Promise<OperationLease | null> {
  const now = input.now ?? new Date().toISOString();
  if (input.ownerKind !== "deployment") {
    const deployment = await db.prepare(
      "SELECT holder_id FROM operation_leases WHERE resource = 'control:deployment' AND released_at IS NULL AND expires_at > ?1",
    ).bind(now).first();
    if (deployment) return null;
  }
  if (input.resource !== "workflow:d1-maintenance") {
    const maintenance = await db.prepare(
      "SELECT holder_id FROM operation_leases WHERE resource = 'workflow:d1-maintenance' AND released_at IS NULL AND expires_at > ?1",
    ).bind(now).first();
    if (maintenance) return null;
  } else {
    const activeJob = await db.prepare(
      "SELECT holder_id FROM operation_leases WHERE owner_kind = 'job' AND released_at IS NULL AND expires_at > ?1 LIMIT 1",
    ).bind(now).first();
    if (activeJob) return null;
  }
  const expiresAt = leaseExpiry(now, input.leaseMinutes);
  const row = await db.prepare(
    `INSERT INTO operation_leases
       (resource, holder_id, owner_kind, fence, acquired_at, heartbeat_at, expires_at, released_at, metadata_json)
     VALUES (?1, ?2, ?3, 1, ?4, ?4, ?5, NULL, ?6)
     ON CONFLICT(resource) DO UPDATE SET
       holder_id = excluded.holder_id,
       owner_kind = excluded.owner_kind,
       fence = CASE WHEN operation_leases.holder_id = excluded.holder_id
                    THEN operation_leases.fence ELSE operation_leases.fence + 1 END,
       acquired_at = CASE WHEN operation_leases.holder_id = excluded.holder_id
                          THEN operation_leases.acquired_at ELSE excluded.acquired_at END,
       heartbeat_at = excluded.heartbeat_at,
       expires_at = excluded.expires_at,
       released_at = NULL,
       metadata_json = excluded.metadata_json
     WHERE operation_leases.holder_id = excluded.holder_id
        OR operation_leases.released_at IS NOT NULL
        OR operation_leases.expires_at <= excluded.acquired_at
     RETURNING resource, holder_id, owner_kind, fence, acquired_at, heartbeat_at, expires_at`,
  ).bind(input.resource, input.holderId, input.ownerKind, now, expiresAt, stableJson(input.metadata ?? {})).first<LeaseRow>();
  return row ? leaseFromRow(row) : null;
}

export async function renewOperationLease(
  db: D1Database,
  resource: string,
  holderId: string,
  fence: number,
  leaseMinutes: number,
  now = new Date().toISOString(),
): Promise<boolean> {
  const result = await db.prepare(
    `UPDATE operation_leases
        SET heartbeat_at = ?4, expires_at = ?5
      WHERE resource = ?1 AND holder_id = ?2 AND fence = ?3
        AND released_at IS NULL AND expires_at > ?4`,
  ).bind(resource, holderId, fence, now, leaseExpiry(now, leaseMinutes)).run();
  return result.meta.changes === 1;
}

export async function releaseOperationLease(
  db: D1Database,
  resource: string,
  holderId: string,
  fence: number,
  now = new Date().toISOString(),
): Promise<boolean> {
  const result = await db.prepare(
    `UPDATE operation_leases SET heartbeat_at = ?4, released_at = ?4
      WHERE resource = ?1 AND holder_id = ?2 AND fence = ?3 AND released_at IS NULL`,
  ).bind(resource, holderId, fence, now).run();
  return result.meta.changes === 1;
}

export async function activeDeploymentBlockers(db: D1Database, now = new Date().toISOString()): Promise<Array<Record<string, unknown>>> {
  const rows = await db.prepare(
    `SELECT resource, holder_id, owner_kind, fence, acquired_at, heartbeat_at, expires_at, metadata_json
       FROM operation_leases
      WHERE released_at IS NULL AND expires_at > ?1 AND owner_kind IN ('job', 'workflow', 'maintenance')
      ORDER BY acquired_at`,
  ).bind(now).all<Record<string, unknown>>();
  return rows.results.filter((row) => {
    try { return (JSON.parse(String(row.metadata_json ?? "{}")) as { deploymentSafe?: boolean }).deploymentSafe !== true; }
    catch { return true; }
  });
}
