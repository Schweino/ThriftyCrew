import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vitest";

const STORES = ["aldi-omaha-446-048", "bakers-saddle-creek", "family-fare-omaha-6401", "fareway-omaha-043",
  "hy-vee-omaha-1465", "sams-omaha", "walmart-omaha"];

function fixture() {
  const db = new DatabaseSync(":memory:");
  db.exec(`PRAGMA foreign_keys=ON;
    CREATE TABLE ingredient_entities(id TEXT PRIMARY KEY);
    CREATE TABLE catalog_ingredient_versions(version_id TEXT PRIMARY KEY,ingredient_id TEXT NOT NULL,definition_hash TEXT NOT NULL);
    CREATE TABLE catalog_ingredient_current(ingredient_id TEXT PRIMARY KEY,current_version_id TEXT NOT NULL,pointer_generation INTEGER NOT NULL,updated_at TEXT);
    CREATE TABLE catalog_backfill_runs_v4(run_id TEXT PRIMARY KEY);
    CREATE TABLE catalog_backfill_ingredients_v4(run_id TEXT,commodity_id TEXT,ingredient_id TEXT,definition_version_id TEXT,
      terminal_evidence_count INTEGER,updated_at TEXT,PRIMARY KEY(run_id,commodity_id));
    CREATE TABLE pipeline_agent_work_items_v4(id TEXT PRIMARY KEY,agent_id TEXT,entity_type TEXT,entity_id TEXT,dedupe_key TEXT UNIQUE,
      priority INTEGER,state TEXT,available_at TEXT DEFAULT CURRENT_TIMESTAMP,lease_owner TEXT,lease_generation INTEGER DEFAULT 0,
      lease_expires_at TEXT,attempt_count INTEGER DEFAULT 0,input_ref_hash TEXT,result_ref_hash TEXT,correlation_id TEXT,created_at TEXT DEFAULT CURRENT_TIMESTAMP,
      started_at TEXT,heartbeat_at TEXT,terminal_at TEXT,blocked_at TEXT,metrics_json TEXT DEFAULT '{}',input_json TEXT);
    CREATE TABLE catalog_backfill_cells_v4(run_id TEXT,commodity_id TEXT,ingredient_id TEXT,definition_version_id TEXT,store_location_id TEXT,
      semantic_state TEXT,evidence_state TEXT,producer_work_item_id TEXT,verifier_work_item_id TEXT,terminal_result_json TEXT,
      terminal_result_hash TEXT,updated_at TEXT,PRIMARY KEY(run_id,commodity_id,store_location_id));`);
  for (const migration of ["0078_catalog_backfill_definition_corrections.sql",
    "0079_catalog_backfill_definition_correction_fence.sql", "0080_catalog_backfill_definition_correction_apply.sql"]) {
    db.exec(readFileSync(new URL(`../../../migrations/${migration}`, import.meta.url), "utf8"));
  }
  db.exec(`INSERT INTO ingredient_entities VALUES('ingredient');
    INSERT INTO catalog_ingredient_versions VALUES('old','ingredient','${"a".repeat(64)}'),('new','ingredient','${"b".repeat(64)}');
    INSERT INTO catalog_ingredient_current VALUES('ingredient','old',3,CURRENT_TIMESTAMP);
    INSERT INTO catalog_backfill_runs_v4 VALUES('run');
    INSERT INTO catalog_backfill_ingredients_v4 VALUES('run','almonds','ingredient','old',1,CURRENT_TIMESTAMP);`);
  for (const [index, store] of STORES.entries()) {
    const verifier = index === 0 ? `'verifier-0'` : "NULL";
    db.exec(`INSERT INTO pipeline_agent_work_items_v4(id,agent_id,entity_type,entity_id,dedupe_key,priority,state,input_ref_hash,correlation_id,input_json)
      VALUES('producer-${index}','agent-${index}','cell','ingredient','old-${index}',100,'${index === 0 ? "succeeded" : "queued"}','${"c".repeat(64)}','run','{}');
      ${index === 0 ? `INSERT INTO pipeline_agent_work_items_v4(id,agent_id,entity_type,entity_id,dedupe_key,priority,state,input_ref_hash,correlation_id,input_json)
        VALUES('verifier-0','qa','cell','ingredient','verify-0',100,'claimed','${"d".repeat(64)}','run','{}');` : ""}
      INSERT INTO catalog_backfill_cells_v4 VALUES('run','almonds','ingredient','old','${store}','legacy_unknown',
        '${index === 0 ? "producer_ready" : "queued"}','producer-${index}',${verifier},NULL,NULL,CURRENT_TIMESTAMP);
      INSERT INTO catalog_backfill_definition_correction_stage_v4(correction_id,run_id,commodity_id,ingredient_id,
        old_definition_version_id,new_definition_version_id,old_pointer_generation,new_pointer_generation,store_location_id,
        old_evidence_state,old_producer_work_item_id,old_verifier_work_item_id,old_terminal_result_hash,old_producer_state,
        old_producer_result_ref_hash,old_producer_lease_owner,old_producer_lease_generation,old_producer_lease_expires_at,
        old_verifier_state,old_verifier_result_ref_hash,old_verifier_lease_owner,old_verifier_lease_generation,old_verifier_lease_expires_at,
        new_work_item_id,new_agent_id,new_dedupe_key,new_input_ref_hash,new_input_json)
      SELECT 'correction','run','almonds','ingredient','old','new',3,4,'${store}',c.evidence_state,c.producer_work_item_id,
        c.verifier_work_item_id,c.terminal_result_hash,p.state,p.result_ref_hash,p.lease_owner,p.lease_generation,p.lease_expires_at,
        v.state,v.result_ref_hash,v.lease_owner,v.lease_generation,v.lease_expires_at,'new-${index}','agent-${index}','new-dedupe-${index}',
        '${"e".repeat(64)}','{}' FROM catalog_backfill_cells_v4 c JOIN pipeline_agent_work_items_v4 p ON p.id=c.producer_work_item_id
        LEFT JOIN pipeline_agent_work_items_v4 v ON v.id=c.verifier_work_item_id WHERE c.store_location_id='${store}';`);
  }
  return db;
}

function apply(db: DatabaseSync, options: { oldHash?: string; newGeneration?: number } = {}) {
  db.exec(`INSERT INTO catalog_backfill_definition_corrections_v4(correction_id,run_id,commodity_id,ingredient_id,
    old_definition_version_id,new_definition_version_id,old_definition_hash,new_definition_hash,old_pointer_generation,
    new_pointer_generation,rollback_json,reason) VALUES('correction','run','almonds','ingredient','old','new',
    '${options.oldHash ?? "a".repeat(64)}','${"b".repeat(64)}',3,${options.newGeneration ?? 4},'{}','durable authored identity correction');`);
}

describe("atomic catalog definition correction migration", () => {
  it("applies all seven swaps in the same statement", () => {
    const db = fixture(); apply(db);
    expect(db.prepare("SELECT COUNT(*) n FROM catalog_backfill_cells_v4 WHERE definition_version_id='new' AND evidence_state='queued'").get()).toEqual({ n: 7 });
    expect(db.prepare("SELECT COUNT(*) n FROM pipeline_agent_work_items_v4 WHERE state='superseded'").get()).toEqual({ n: 8 });
    expect(db.prepare("SELECT current_version_id,pointer_generation FROM catalog_ingredient_current").get()).toEqual({ current_version_id: "new", pointer_generation: 4 });
  });

  it("leaves every old cell and work item untouched after a lost pointer CAS", () => {
    const db = fixture(); db.exec("UPDATE catalog_ingredient_current SET pointer_generation=4");
    expect(() => apply(db)).toThrow(/pointer fence/);
    expect(db.prepare("SELECT COUNT(*) n FROM catalog_backfill_cells_v4 WHERE definition_version_id='old'").get()).toEqual({ n: 7 });
    expect(db.prepare("SELECT COUNT(*) n FROM pipeline_agent_work_items_v4 WHERE state='superseded'").get()).toEqual({ n: 0 });
    expect(db.prepare("SELECT COUNT(*) n FROM catalog_backfill_definition_corrections_v4").get()).toEqual({ n: 0 });
  });

  it("cannot partially supersede six cells when one staged cell changed", () => {
    const db = fixture(); db.exec("UPDATE catalog_backfill_cells_v4 SET evidence_state='needs_operator' WHERE store_location_id='sams-omaha'");
    expect(() => apply(db)).toThrow(/snapshot fence/);
    expect(db.prepare("SELECT COUNT(*) n FROM catalog_backfill_cells_v4 WHERE definition_version_id='old'").get()).toEqual({ n: 7 });
    expect(db.prepare("SELECT COUNT(*) n FROM pipeline_agent_work_items_v4 WHERE state='superseded'").get()).toEqual({ n: 0 });
    expect(db.prepare("SELECT COUNT(*) n FROM pipeline_agent_work_items_v4 WHERE id LIKE 'new-%'").get()).toEqual({ n: 0 });
  });

  it("rejects a forged old definition hash without mutation", () => {
    const db = fixture();
    expect(() => apply(db, { oldHash: "f".repeat(64) })).toThrow(/old definition hash/);
    expect(db.prepare("SELECT COUNT(*) n FROM catalog_backfill_cells_v4 WHERE definition_version_id='old'").get()).toEqual({ n: 7 });
  });

  it("rejects a pointer generation jump without mutation", () => {
    const db = fixture();
    expect(() => apply(db, { newGeneration: 5 })).toThrow(/advance exactly once/);
    expect(db.prepare("SELECT COUNT(*) n FROM pipeline_agent_work_items_v4 WHERE state='superseded'").get()).toEqual({ n: 0 });
  });
});
