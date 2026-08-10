import { readdir, readFile } from "node:fs/promises";
import path from "node:path";

const platformRoot = path.resolve(import.meta.dirname, "..");
const policy = JSON.parse(await readFile(path.join(platformRoot, "config", "migration-policy.json"), "utf8"));

function validateMigration(name, sql, number) {
  const normalized = sql.toLowerCase().replaceAll(/\s+/g, " ");
  if (policy.forbiddenPragmas.some((pragma) => normalized.includes(`pragma ${pragma}`))) throw new Error(`${name} disables foreign-key enforcement`);
  if (policy.forbidDownMigrationFiles && /(?:^|[_-])down(?:[_-]|\.)/i.test(name)) throw new Error(`${name} is a down migration; use a forward fix or restore`);
  if (number < policy.enforcedFrom) return;
  const declaration = /^--\s*@policy\s+(expand-contract|contract)\s*$/m.exec(sql);
  if (!declaration) throw new Error(`${name} must declare -- @policy expand-contract or contract`);
  const phase = declaration[1];
  const destructive = /\bdrop\s+(?:table|column|index)\b|\bdelete\s+from\b|\btruncate\b/i.test(sql);
  if (phase === "expand-contract" && destructive) throw new Error(`${name} is an expand migration containing destructive SQL`);
  if (phase === "contract" && policy.requireRestoreProofForContract && !/^--\s*@restore-proof\s+\S+/m.test(sql)) throw new Error(`${name} contract migration requires a durable restore-proof reference`);
}

const files = (await readdir(path.join(platformRoot, "migrations"))).filter((file) => /^\d{4}_.+\.sql$/.test(file)).sort();
for (const [index, file] of files.entries()) {
  const number = Number(file.slice(0, 4));
  if (number !== index + 1) throw new Error(`migration sequence gap: expected ${String(index + 1).padStart(4, "0")}, found ${file}`);
  validateMigration(file, await readFile(path.join(platformRoot, "migrations", file), "utf8"), number);
}

let rejectedBrokenFixture = false;
try { validateMigration("9999_bad.sql", "-- @policy expand-contract\nDROP TABLE observations;", 9999); }
catch { rejectedBrokenFixture = true; }
if (!rejectedBrokenFixture) throw new Error("migration policy self-test failed to reject destructive expand SQL");

console.log(JSON.stringify({ ok: true, policyVersion: policy.version, migrations: files.length, latest: files.at(-1), brokenFixtureRejected: true }));
