import { readFile } from "node:fs/promises";

const [recoveryFile] = process.argv.slice(2);
const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
const databaseId = process.env.D1_DATABASE_ID;
const token = process.env.D1_REST_API_TOKEN;
if (!recoveryFile || !accountId || !databaseId || !token) {
  throw new Error("usage: set CLOUDFLARE_ACCOUNT_ID, D1_DATABASE_ID, D1_REST_API_TOKEN and pass <recovery.json>");
}
const document = JSON.parse(await readFile(recoveryFile, "utf8"));
if (document.version !== 1 || !Array.isArray(document.rows)) throw new Error("unsupported recovery document");
const endpoint = `https://api.cloudflare.com/client/v4/accounts/${accountId}/d1/database/${databaseId}/query`;
let restored = 0;
for (const row of document.rows) {
  const quote = (value) => `"${String(value).replaceAll('"', '""')}"`;
  const params = row.values.map((value) => value && typeof value === "object" && "$blobBase64" in value
    ? Array.from(Buffer.from(value.$blobBase64, "base64"))
    : value);
  const placeholders = params.map((_, index) => `?${index + 1}`).join(", ");
  const statement = `INSERT OR REPLACE INTO ${quote(row.table)} (${row.columns.map(quote).join(", ")}) VALUES (${placeholders})`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
    body: JSON.stringify({ sql: statement, params }),
  });
  const body = await response.json();
  if (!response.ok || body.success !== true || body.result?.some?.((result) => result.success === false)) {
    throw new Error(`parameterized restore failed for ${row.table}: HTTP ${response.status} ${JSON.stringify(body.errors ?? body.result ?? [])}`);
  }
  restored += 1;
}
console.log(JSON.stringify({ ok: true, restored }));
