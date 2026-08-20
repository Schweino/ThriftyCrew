"""Core store layer for the ThriftyCrew knowledge graph.

Design rules this module enforces (from the implementation plan):

* **Provenance first.** You cannot assert a fact without a provenance id. Every
  write method takes one, and `record_provenance` is the only way to mint one.
* **Additive.** Writes are upserts; nothing is destructively deleted by the
  pipeline. Retraction is an explicit, provenanced act (`retract_edge`).
* **Deterministic.** All ids come from `ids.py`. Re-running an import is a no-op
  rather than a duplicate.
* **The DB is an index.** `export_json()` writes the durable, git-tracked JSON;
  `rebuild.py` reconstructs the DB from it. Truth lives in the JSON.
* **No implicit clock.** Timestamps are passed in. A replayed run reproduces
  byte-identical ids and rows.
"""

from __future__ import annotations

import io
import json
import os
import sqlite3
from contextlib import contextmanager
from typing import Any, Iterable, Sequence

from ids import (edge_id, event_id, hash_obj, provenance_id)

HERE = os.path.dirname(os.path.abspath(__file__))
GRAPH_DIR = os.path.abspath(os.path.join(HERE, ".."))
REPO_ROOT = os.path.abspath(os.path.join(GRAPH_DIR, ".."))
DB_PATH = os.path.join(GRAPH_DIR, "sqlite", "graph.db")
SCHEMA_PATH = os.path.join(GRAPH_DIR, "sqlite", "schema.sql")

NODE_TYPES = {
    "Store", "Commodity", "Category", "ProductSKU", "AdCycle", "AdPage",
    "Recipe", "IngredientMapping", "KnownWrong", "Override", "CategoryExclude",
    "AuditFinding", "Incident",
}

PREDICATES = {
    "sold_at", "priced_as", "instance_of", "in_category", "excluded_from",
    "known_wrong_for", "overrides", "maps_to", "uses_ingredient",
    "belongs_to_cycle", "do_not_merge", "same_as", "flagged_by",
}


def read_json(path: str) -> Any:
    """Read JSON tolerating the UTF-8 BOM that PowerShell's ConvertTo-Json emits."""
    with io.open(path, encoding="utf-8-sig") as fh:
        return json.load(fh)


def write_json(path: str, obj: Any) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with io.open(path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(obj, fh, indent=2, ensure_ascii=False, sort_keys=True)
        fh.write("\n")


class GraphDB:
    """Thin, explicit wrapper over SQLite. No ORM, no magic."""

    def __init__(self, path: str = DB_PATH, create: bool = True,
                 restore_learning: bool = True):
        self.path = path
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fresh = not os.path.exists(path)
        self.conn = sqlite3.connect(path)
        self.conn.row_factory = sqlite3.Row
        self.conn.execute("PRAGMA foreign_keys = ON")
        if fresh or create:
            self.init_schema()
        # A fresh database restores its learning records automatically. Making
        # this depend on someone remembering a flag is how the records were lost
        # in the first place -- durability that has to be opted into is not
        # durability. Cheap: it is a no-op once the tables are populated.
        if restore_learning and not any(self.learning_counts().values()):
            self.import_learning()

    def init_schema(self) -> None:
        with io.open(SCHEMA_PATH, encoding="utf-8") as fh:
            self.conn.executescript(fh.read())
        self.conn.commit()

    # -- lifecycle ---------------------------------------------------------
    def close(self) -> None:
        self.conn.commit()
        self.conn.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if exc[0] is None:
            self.conn.commit()
        self.close()
        return False

    @contextmanager
    def tx(self):
        try:
            yield self.conn
            self.conn.commit()
        except Exception:
            self.conn.rollback()
            raise

    # -- provenance --------------------------------------------------------
    def record_provenance(self, source_document: str, extraction_method: str,
                          timestamp: str, model: str | None = None,
                          prompt_version: str | None = None,
                          raw_output_hash: str | None = None,
                          run: str | None = None) -> str:
        """Mint (or reuse) a provenance row. Returns its id.

        This is the ONLY way to create a provenance id — every fact-writing
        method below demands one, which is how the plan's "provenance is
        non-negotiable" rule becomes structural rather than aspirational.
        """
        pid = provenance_id(source_document, extraction_method, timestamp, raw_output_hash)
        self.conn.execute(
            """INSERT INTO provenance
                 (id, source_document, extraction_method, model, prompt_version,
                  timestamp, raw_output_hash, run_id)
               VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO NOTHING""",
            (pid, source_document, extraction_method, model, prompt_version,
             timestamp, raw_output_hash, run),
        )
        return pid

    # -- nodes -------------------------------------------------------------
    def upsert_node(self, node_id: str, ntype: str, canonical_name: str,
                    timestamp: str, description: str | None = None,
                    properties: dict | None = None,
                    provenance: str | None = None) -> str:
        if ntype not in NODE_TYPES:
            raise ValueError(f"unknown node type {ntype!r}; add it to NODE_TYPES and schema.md")
        props = json.dumps(properties or {}, sort_keys=True, ensure_ascii=False)
        self.conn.execute(
            """INSERT INTO nodes
                 (id, type, canonical_name, description, properties_json,
                  provenance_id, created_at, updated_at)
               VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                 canonical_name = excluded.canonical_name,
                 description    = COALESCE(excluded.description, nodes.description),
                 properties_json= excluded.properties_json,
                 updated_at     = excluded.updated_at""",
            (node_id, ntype, canonical_name, description, props, provenance,
             timestamp, timestamp),
        )
        return node_id

    def get_node(self, node_id: str) -> dict | None:
        r = self.conn.execute("SELECT * FROM nodes WHERE id=?", (node_id,)).fetchone()
        return dict(r) if r else None

    def nodes_of_type(self, ntype: str) -> list[dict]:
        rows = self.conn.execute(
            "SELECT * FROM nodes WHERE type=? ORDER BY id", (ntype,)).fetchall()
        return [dict(r) for r in rows]

    # -- edges -------------------------------------------------------------
    def upsert_edge(self, source: str, predicate: str, target: str,
                    timestamp: str, properties: dict | None = None,
                    provenance: str | None = None, confidence: float = 1.0) -> str:
        if predicate not in PREDICATES:
            raise ValueError(f"unknown predicate {predicate!r}; add it to PREDICATES and schema.md")
        eid = edge_id(source, predicate, target)
        props = json.dumps(properties or {}, sort_keys=True, ensure_ascii=False)
        self.conn.execute(
            """INSERT INTO edges
                 (id, source_id, target_id, predicate, properties_json,
                  provenance_id, confidence, created_at)
               VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(source_id, target_id, predicate) DO UPDATE SET
                 properties_json = excluded.properties_json,
                 confidence      = excluded.confidence,
                 provenance_id   = excluded.provenance_id""",
            (eid, source, target, predicate, props, provenance, confidence, timestamp),
        )
        return eid

    def retract_edge(self, source: str, predicate: str, target: str,
                     timestamp: str, run: str, reason: str) -> None:
        """Explicit, logged retraction. The pipeline never silently deletes."""
        eid = edge_id(source, predicate, target)
        self.log_event(run=run, timestamp=timestamp, etype="state_transition",
                       decision="retract_edge",
                       detail={"edge": eid, "source": source, "predicate": predicate,
                               "target": target, "reason": reason})
        self.conn.execute("DELETE FROM edges WHERE id=?", (eid,))

    def neighbors(self, node_id: str, predicate: str | None = None,
                  direction: str = "out") -> list[dict]:
        col, other = ("source_id", "target_id") if direction == "out" else ("target_id", "source_id")
        q = f"SELECT e.*, n.canonical_name AS other_name, n.type AS other_type " \
            f"FROM edges e JOIN nodes n ON n.id = e.{other} WHERE e.{col}=?"
        args: list[Any] = [node_id]
        if predicate:
            q += " AND e.predicate=?"
            args.append(predicate)
        return [dict(r) for r in self.conn.execute(q, args).fetchall()]

    # -- aliases -----------------------------------------------------------
    def add_alias(self, node_id: str, alias: str, source: str, timestamp: str,
                  kind: str = "include", is_regex: bool = False,
                  confidence: float = 1.0, provenance: str | None = None) -> None:
        self.conn.execute(
            """INSERT INTO aliases
                 (node_id, alias, kind, is_regex, source, confidence, provenance_id, created_at)
               VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(node_id, alias, kind) DO UPDATE SET
                 confidence = excluded.confidence,
                 source     = excluded.source""",
            (node_id, alias, kind, 1 if is_regex else 0, source, confidence,
             provenance, timestamp),
        )

    def aliases_for(self, node_id: str, kind: str | None = None) -> list[dict]:
        q = "SELECT * FROM aliases WHERE node_id=?"
        args: list[Any] = [node_id]
        if kind:
            q += " AND kind=?"
            args.append(kind)
        return [dict(r) for r in self.conn.execute(q, args).fetchall()]

    # -- price observations ------------------------------------------------
    def add_observation(self, obs: dict) -> str:
        """Insert a PriceObservation. `obs` must carry id + provenance_id."""
        required = {"id", "commodity_id", "store_id", "provenance_id", "observed_at"}
        missing = required - set(obs)
        if missing:
            raise ValueError(f"observation missing required fields: {sorted(missing)}")
        self.conn.execute(
            """INSERT INTO price_observations
                 (id, commodity_id, store_id, product_name, price, unit_price, unit,
                  size_text, is_sale, price_type, ad_cycle_id, provenance_id,
                  confidence, observed_at, source_file, match_status, match_reason)
               VALUES (:id,:commodity_id,:store_id,:product_name,:price,:unit_price,:unit,
                       :size_text,:is_sale,:price_type,:ad_cycle_id,:provenance_id,
                       :confidence,:observed_at,:source_file,:match_status,:match_reason)
               ON CONFLICT(id) DO UPDATE SET
                 price      = excluded.price,
                 unit_price = excluded.unit_price,
                 -- Re-import must never clobber an adjudication. The importer
                 -- speaks with authority only when its SOURCE asserts the
                 -- commodity (it then sends a non-'unadjudicated' status);
                 -- a raw candidate arriving as 'unadjudicated' says nothing,
                 -- and overwriting an llm_/escalated/include_hit verdict with
                 -- it silently destroyed the entire adjudication history on
                 -- every routine re-import (caught 2026-08-20: a midday
                 -- import erased that morning's 25 model verdicts).
                 confidence = CASE WHEN excluded.match_status != 'unadjudicated'
                                   THEN excluded.confidence
                                   ELSE price_observations.confidence END,
                 match_status = CASE WHEN excluded.match_status != 'unadjudicated'
                                     THEN excluded.match_status
                                     ELSE price_observations.match_status END,
                 match_reason = CASE WHEN excluded.match_status != 'unadjudicated'
                                     THEN excluded.match_reason
                                     ELSE price_observations.match_reason END""",
            {
                "product_name": None, "price": None, "unit_price": None, "unit": None,
                "size_text": None, "is_sale": 0, "price_type": None, "ad_cycle_id": None,
                # confidence defaults to NULL ("nobody asserted anything"), for
                # the same reason match_status defaults to 'unadjudicated': an
                # importer that KNOWS must say so explicitly, and an importer
                # that doesn't must not look like it did.
                "confidence": None, "source_file": None,
                # Default is 'unadjudicated' so a lane that does NOT already know the
                # commodity cannot skip the resolver by omission. Only importers whose
                # source asserts the commodity id may pass 'include_hit' explicitly.
                "match_status": "unadjudicated", "match_reason": None,
                **obs,
            },
        )
        return obs["id"]

    def current_cell(self, commodity_id: str, store_id: str) -> dict | None:
        r = self.conn.execute(
            """SELECT * FROM price_observations
               WHERE commodity_id=? AND store_id=?
               ORDER BY observed_at DESC LIMIT 1""",
            (commodity_id, store_id)).fetchone()
        return dict(r) if r else None

    def board_matrix(self) -> dict[tuple[str, str], dict]:
        """The graph's answer to 'the board': one surviving observation per
        cell. v_current_cell guarantees exactly one row per (commodity, store)
        — this dict comprehension must never again paper over duplicates by
        last-write-wins key collision, which it silently did for 9,138 rows
        while the view returned same-day ties."""
        rows = self.conn.execute("SELECT * FROM v_current_cell").fetchall()
        return {(r["commodity_id"], r["store_id"]): dict(r) for r in rows}

    # -- decision log ------------------------------------------------------
    def log_event(self, run: str, timestamp: str, etype: str,
                  step_id: str | None = None, model: str | None = None,
                  input_hash: str | None = None, output_hash: str | None = None,
                  confidence: float | None = None, decision: str | None = None,
                  detail: dict | None = None,
                  provenance_ids: Sequence[str] | None = None) -> str:
        detail = detail or {}
        eid = event_id(run, step_id, etype, hash_obj([decision, detail, output_hash]))
        self.conn.execute(
            """INSERT INTO decision_log
                 (event_id, run_id, timestamp, type, step_id, model, input_hash,
                  output_hash, confidence, decision, detail_json, provenance_ids)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(event_id) DO NOTHING""",
            (eid, run, timestamp, etype, step_id, model, input_hash, output_hash,
             confidence, decision,
             json.dumps(detail, sort_keys=True, ensure_ascii=False, default=str),
             json.dumps(list(provenance_ids or []))),
        )
        # Mirror to the durable, git-tracked JSONL trail.
        self._append_jsonl(run, {
            "event_id": eid, "run_id": run, "timestamp": timestamp, "type": etype,
            "step_id": step_id, "model": model, "input_hash": input_hash,
            "output_hash": output_hash, "confidence": confidence,
            "decision": decision, "detail": detail,
            "provenance_ids": list(provenance_ids or []),
        })
        return eid

    @staticmethod
    def _append_jsonl(run: str, record: dict) -> None:
        safe = run.replace(":", "_")
        path = os.path.join(GRAPH_DIR, "provenance", f"{safe}.jsonl")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with io.open(path, "a", encoding="utf-8", newline="\n") as fh:
            fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True, default=str) + "\n")

    # -- stats / export ----------------------------------------------------
    def stats(self) -> dict:
        c = self.conn
        out = {
            "nodes": c.execute("SELECT COUNT(*) FROM nodes").fetchone()[0],
            "edges": c.execute("SELECT COUNT(*) FROM edges").fetchone()[0],
            "aliases": c.execute("SELECT COUNT(*) FROM aliases").fetchone()[0],
            "observations": c.execute("SELECT COUNT(*) FROM price_observations").fetchone()[0],
            "provenance": c.execute("SELECT COUNT(*) FROM provenance").fetchone()[0],
            "events": c.execute("SELECT COUNT(*) FROM decision_log").fetchone()[0],
        }
        out["by_type"] = {r[0]: r[1] for r in c.execute(
            "SELECT type, COUNT(*) FROM nodes GROUP BY type ORDER BY 2 DESC").fetchall()}
        out["by_predicate"] = {r[0]: r[1] for r in c.execute(
            "SELECT predicate, COUNT(*) FROM edges GROUP BY predicate ORDER BY 2 DESC").fetchall()}
        return out

    def export_json(self, out_dir: str | None = None) -> dict[str, int]:
        """Write the durable, git-tracked JSON that the DB is an index OF.

        Observations are intentionally NOT exported wholesale: they are high
        volume and reconstructable from the tracked store captures. Their
        provenance rows ARE exported, so the audit trail survives.
        """
        out_dir = out_dir or GRAPH_DIR
        written = {}
        for table, fname in (("nodes", "nodes/nodes.json"),
                             ("edges", "edges/edges.json"),
                             ("aliases", "aliases/aliases.json"),
                             ("provenance", "provenance/provenance.json")):
            rows = [dict(r) for r in self.conn.execute(
                f"SELECT * FROM {table} ORDER BY 1").fetchall()]
            write_json(os.path.join(out_dir, fname), rows)
            written[table] = len(rows)
        written.update(self.export_learning(out_dir))
        return written

    # -- durability of irreplaceable tables --------------------------------
    # These are the structures in the graph that cannot be reconstructed from
    # anything else. Nodes, edges, aliases and observations all rebuild from
    # the legacy estate and the tracked captures; a learning proposal, the
    # verdict a reviewer gave it, and a scored evaluation run exist nowhere but
    # here. Leaving them in a gitignored, rebuildable database meant a routine
    # delete-and-rebuild silently destroyed the safety record of what the loop
    # proposed, what was approved, and what the gold set said before and after.
    # That is exactly the "a memory the pipeline cannot read is not a memory"
    # failure the estate already learned once with prose audit findings.
    #
    # eval_runs is here for the same reason (added 2026-08-20): the README's
    # own rule is "re-score after any prompt/model/resolver change and record
    # the run — eval_runs keeps model + prompt version so a regression can be
    # attributed", and stage1_analyze reads the latest run's errors. A history
    # that the sanctioned `rm graph.db` deletes is not a history.

    LEARNING_TABLES = (
        ("learning_proposals", "learning/proposals.json"),
        ("approved_patches", "learning/approved-patches.json"),
        ("eval_runs", "eval/eval-runs.json"),
    )

    def export_learning(self, out_dir: str | None = None) -> dict[str, int]:
        """Write learning records to tracked JSON. Called after every write."""
        out_dir = out_dir or GRAPH_DIR
        written = {}
        for table, fname in self.LEARNING_TABLES:
            rows = [dict(r) for r in self.conn.execute(
                f"SELECT * FROM {table} ORDER BY 1").fetchall()]
            write_json(os.path.join(out_dir, fname), rows)
            written[table] = len(rows)
        return written

    def import_learning(self, out_dir: str | None = None) -> dict[str, int]:
        """Restore learning records from tracked JSON into a fresh database."""
        out_dir = out_dir or GRAPH_DIR
        restored = {}
        for table, fname in self.LEARNING_TABLES:
            path = os.path.join(out_dir, fname)
            if not os.path.exists(path):
                restored[table] = 0
                continue
            try:
                rows = read_json(path)
            except (json.JSONDecodeError, OSError):
                restored[table] = 0
                continue
            n = 0
            for row in rows or []:
                cols = ", ".join(row.keys())
                marks = ", ".join(f":{k}" for k in row)
                self.conn.execute(
                    f"INSERT INTO {table} ({cols}) VALUES ({marks}) "
                    f"ON CONFLICT(id) DO NOTHING", row)
                n += 1
            restored[table] = n
        self.conn.commit()
        return restored

    def learning_counts(self) -> dict[str, int]:
        return {t: self.conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
                for t, _ in self.LEARNING_TABLES}


def open_db(create: bool = True) -> GraphDB:
    return GraphDB(create=create)
