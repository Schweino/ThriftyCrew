import { readFile } from "node:fs/promises";

const [recoveryFile] = process.argv.slice(2);
const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
const databaseId = process.env.D1_DATABASE_ID;
const token = process.env.D1_REST_API_TOKEN;
if (!recoveryFile || !accountId || !databaseId || !token) {
  throw new Error("usage: set CLOUDFLARE_ACCOUNT_ID, D1_DATABASE_ID, D1_REST_API_TOKEN and pass <recovery.json>");
}
const document = JSON.parse(await readFile(recoveryFile, "utf8"));
if (![1, 2].includes(document.version) || !Array.isArray(document.rows)) throw new Error("unsupported recovery document");
if (document.version === 2 && !Array.isArray(document.updates)) throw new Error("version 2 recovery document requires updates");
const endpoint = `https://api.cloudflare.com/client/v4/accounts/${accountId}/d1/database/${databaseId}/query`;
const quote = (value) => `"${String(value).replaceAll('"', '""')}"`;
const request = async (sql, params, label) => {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ sql, params }),
  });
  const body = await response.json();
  if (!response.ok || body.success !== true || body.result?.some?.((result) => result.success === false)) {
    throw new Error(`parameterized restore failed for ${label}: HTTP ${response.status} ${JSON.stringify(body.errors ?? body.result ?? [])}`);
  }
};
let restored = 0;
for (const row of document.rows) {
  const params = row.values.map((value) => value && typeof value === "object" && "$blobBase64" in value
    ? Array.from(Buffer.from(value.$blobBase64, "base64"))
    : value);
  const placeholders = params.map((_, index) => `?${index + 1}`).join(", ");
  const statement = `INSERT INTO ${quote(row.table)} (${row.columns.map(quote).join(", ")}) VALUES (${placeholders})`;
  await request(statement, params, row.table);
  restored += 1;
}
let updated = 0;
for (const update of document.updates ?? []) {
  if (!Array.isArray(update.setColumns) || !Array.isArray(update.setValues) || update.setColumns.length !== update.setValues.length || update.setColumns.length === 0) {
    throw new Error(`invalid recovery update for ${update.table}`);
  }
  if (!Array.isArray(update.keyColumns) || !Array.isArray(update.keyValues) || update.keyColumns.length !== update.keyValues.length || update.keyColumns.length === 0) {
    throw new Error(`invalid recovery update key for ${update.table}`);
  }
  const params = [...update.setValues, ...update.keyValues];
  const setters = update.setColumns.map((column, index) => `${quote(column)} = ?${index + 1}`).join(", ");
  const predicates = update.keyColumns.map((column, index) => `${quote(column)} = ?${update.setValues.length + index + 1}`).join(" AND ");
  const statement = `UPDATE ${quote(update.table)} SET ${setters} WHERE ${predicates}`;
  await request(statement, params, update.table);
  updated += 1;
}
console.log(JSON.stringify({ ok: true, restored, updated }));
