export const RESTORE_COUNT_TABLES = [
  "capture_batches",
  "observations",
  "products",
  "releases",
  "release_cells",
  "job_runs",
] as const;

export type RestoreCountTable = (typeof RESTORE_COUNT_TABLES)[number];
export type RestoreCounts = Record<RestoreCountTable, number>;

export interface SqlInsert {
  table: string;
  columns: string[];
  values: Array<string | null>;
}

function parseSqlValues(input: string): Array<string | null> | null {
  const values: Array<string | null> = [];
  let index = 0;
  while (index < input.length) {
    while (input[index] === " ") index += 1;
    if (input[index] === "'") {
      index += 1;
      let value = "";
      let closed = false;
      while (index < input.length) {
        if (input[index] !== "'") {
          value += input[index];
          index += 1;
          continue;
        }
        if (input[index + 1] === "'") {
          value += "'";
          index += 2;
          continue;
        }
        index += 1;
        closed = true;
        break;
      }
      if (!closed) return null;
      values.push(value);
    } else {
      const comma = input.indexOf(",", index);
      const end = comma === -1 ? input.length : comma;
      const token = input.slice(index, end).trim();
      if (!token) return null;
      values.push(token.toUpperCase() === "NULL" ? null : token);
      index = end;
    }
    while (input[index] === " ") index += 1;
    if (index === input.length) break;
    if (input[index] !== ",") return null;
    index += 1;
  }
  return values;
}

export function inspectSqlInsert(line: string): SqlInsert | null {
  const match = line.match(/^INSERT INTO "([^"]+)" \((.+)\) VALUES\((.*)\);$/);
  if (!match) return null;
  const table = match[1];
  const rawColumns = match[2];
  const rawValues = match[3];
  if (!table || !rawColumns || rawValues === undefined) return null;
  const columns = [...rawColumns.matchAll(/"([^"]+)"/g)].map((entry) => entry[1]!);
  const values = parseSqlValues(rawValues);
  if (!values || columns.length !== values.length) return null;
  return { table, columns, values };
}

function sqlString(value: string): string {
  return `'${value.replaceAll("'", "''")}'`;
}

export function normalizeCaptureBatchLine(line: string): { line: string; deferredUpdate?: string } {
  const insert = inspectSqlInsert(line);
  if (!insert || insert.table !== "capture_batches") return { line };
  const idIndex = insert.columns.indexOf("id");
  const supersededByIndex = insert.columns.indexOf("superseded_by");
  const id = insert.values[idIndex];
  const supersededBy = insert.values[supersededByIndex];
  if (typeof id !== "string" || typeof supersededBy !== "string" || supersededByIndex !== insert.values.length - 1) return { line };
  const lastValue = line.match(/^(.*),('(?:[^']|'')*')\);$/);
  if (!lastValue) return { line };
  return {
    line: `${lastValue[1]},NULL);`,
    deferredUpdate: `UPDATE "capture_batches" SET "superseded_by"=${sqlString(supersededBy)} WHERE "id"=${sqlString(id)};`,
  };
}

export function emptyRestoreCounts(): RestoreCounts {
  return Object.fromEntries(RESTORE_COUNT_TABLES.map((table) => [table, 0])) as RestoreCounts;
}

export function utf8LengthExceeds(value: string, limitBytes: number): boolean {
  if (value.length <= Math.floor(limitBytes / 4)) return false;
  return new TextEncoder().encode(value).byteLength > limitBytes;
}
