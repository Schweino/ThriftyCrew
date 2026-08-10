export interface CaptureSealTerm {
  termKey: string;
  ordinal: number;
  outcome: string;
  rowCount: number;
  reason?: string | undefined;
}

export interface CaptureTermInsert {
  sql: string;
  bindings: Array<string | number | null>;
}

export function buildCaptureTermInserts(batchId: string, terms: readonly CaptureSealTerm[]): CaptureTermInsert[] {
  const inserts: CaptureTermInsert[] = [];
  // Six bindings per term means 16 rows (96 bindings) stays below D1's
  // documented maximum of 100 bound parameters per SQL statement.
  for (let offset = 0; offset < terms.length; offset += 16) {
    const chunk = terms.slice(offset, offset + 16);
    inserts.push({
      sql: `INSERT INTO capture_terms (batch_id, term_key, ordinal, outcome, row_count, reason)
            VALUES ${chunk.map(() => "(?, ?, ?, ?, ?, ?)").join(", ")}
            ON CONFLICT(batch_id, term_key) DO UPDATE SET
              ordinal = excluded.ordinal,
              outcome = excluded.outcome,
              row_count = excluded.row_count,
              reason = excluded.reason`,
      bindings: chunk.flatMap((term) => [batchId, term.termKey, term.ordinal, term.outcome, term.rowCount, term.reason ?? null]),
    });
  }
  return inserts;
}
