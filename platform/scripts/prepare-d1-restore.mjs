import { DatabaseSync } from "node:sqlite";
import { readFile, writeFile } from "node:fs/promises";

const [inputFile, sanitizedFile, recoveryFile, rawLimit = "90000"] = process.argv.slice(2);
if (!inputFile || !sanitizedFile || !recoveryFile) {
  throw new Error("usage: node scripts/prepare-d1-restore.mjs <dump.sql> <sanitized.sql> <recovery.json> [statement-limit]");
}
const limit = Number.parseInt(rawLimit, 10);
if (!Number.isInteger(limit) || limit < 10_000) throw new Error("statement-limit must be an integer of at least 10000 bytes");

const sql = await readFile(inputFile, "utf8");
const lines = sql.split(/(?<=\n)/);
const skippedTables = new Set();
const skippedByTable = new Map();
let skippedStatements = 0;
const sanitized = lines.map((line) => {
  if (Buffer.byteLength(line, "utf8") <= limit) return line;
  const match = line.match(/^INSERT INTO "([^"]+)"/);
  if (!match) throw new Error(`oversized non-INSERT statement cannot be normalized (${Buffer.byteLength(line, "utf8")} bytes)`);
  skippedTables.add(match[1]);
  skippedByTable.set(match[1], [...(skippedByTable.get(match[1]) ?? []), line]);
  skippedStatements += 1;
  return `-- oversized INSERT for ${match[1]} restored through parameter binding\n`;
}).join("");
await writeFile(sanitizedFile, sanitized, "utf8");

const recovery = [];
for (const table of [...skippedTables].sort()) {
  const statements = skippedByTable.get(table) ?? [];
  const first = statements[0]?.match(/^INSERT INTO "[^"]+" \((.*?)\) VALUES/s);
  if (!first) throw new Error(`could not parse oversized INSERT columns for ${table}`);
  const quotedTable = `"${table.replaceAll('"', '""')}"`;
  const database = new DatabaseSync(":memory:");
  try {
    // SQLite does the SQL-literal parsing; the temporary table intentionally
    // has no constraints because the real schema arrives in sanitized.sql.
    database.exec(`CREATE TABLE ${quotedTable} (${first[1]})`);
    for (const statement of statements) database.exec(statement);
    const names = database.prepare(`PRAGMA table_info(${quotedTable})`).all().map((column) => String(column.name));
    for (const row of database.prepare(`SELECT * FROM ${quotedTable}`).all()) {
      const values = names.map((name) => {
        const value = row[name];
        if (value instanceof Uint8Array) return { $blobBase64: Buffer.from(value).toString("base64") };
        return value;
      });
      recovery.push({ table, columns: names, values });
    }
  } finally {
    database.close();
  }
}
await writeFile(recoveryFile, `${JSON.stringify({ version: 1, statementLimit: limit, skippedStatements, rows: recovery }, null, 2)}\n`, "utf8");
console.log(JSON.stringify({ ok: true, statementLimit: limit, skippedStatements, recoveryRows: recovery.length, tables: [...skippedTables].sort() }));
