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
import re
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


class GraphDBMissing(FileNotFoundError):
    """The database file is not there and the caller did not say it may be created."""


class GraphDB:
    """Thin, explicit wrapper over SQLite. No ORM, no magic."""

    def __init__(self, path: str | None = None, create: bool = True,
                 restore_learning: bool = True, allow_new: bool = False):
        # `path=None` reads the module's DB_PATH at CALL time rather than binding it at definition,
        # so a harness can point the whole module at a copy by setting graphdb.DB_PATH.
        path = path or DB_PATH
        self.path = path
        self.restore_skipped: dict[str, int] = {}
        # A MISSING DATABASE IS REFUSED UNLESS THE CALLER SAYS IT MAY BE CREATED (2026-09-18, backlog
        # I229). sqlite3.connect() creates any path it is handed, so every open_db() script used to
        # build a fresh, empty graph.db wherever it ran - a worktree has none - restore the learning
        # records into it, and then answer every question from an index holding no nodes, no edges
        # and no observations: an agreeing zero from a database nobody meant to make. `create` is
        # NOT that flag; it re-runs the idempotent schema script on an existing file and has always
        # defaulted True. Only the two roads that build the index from nothing pass allow_new:
        # graph/import/import_all.py (the daily chain's graph-gates lane) and graph/lib/rebuild.py.
        if not allow_new and not os.path.exists(path):
            raise GraphDBMissing(
                f"graph database not found at {path} - refusing to create an empty one. "
                f"Build it with graph/import/import_all.py or graph/lib/rebuild.py, or pass "
                f"allow_new=True for a scratch database.")
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
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
    # ALL OR NOTHING IS A CLAIM ABOUT THE DATABASE, AND ITS UNIT IS THE UNIT OF CORRECTNESS (2026-09-18,
    # code review against ~/.claude/skills/database-craft/transactions-and-recovery.md section 3).
    # `close()` commits, which every explicit caller relies on. `__exit__` used to call it on the ERROR
    # path too, so a `with open_db()` block that raised still committed whatever it had written before
    # the raise: a half-applied write became the day's index, internally consistent and wrong, which is
    # the failure row that section names as the dangerous one because nothing raises afterwards.
    def close(self) -> None:
        self.conn.commit()
        self.conn.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if exc[0] is None:
            self.close()
        else:
            self.conn.rollback()
            self.conn.close()
        return False

    def run_step(self, fn, *args, **kwargs):
        """Run `fn(self, *args, **kwargs)` as ONE all-or-nothing unit: commit if it returns, roll back if
        it raises. Returns (ok, result, error).

        The unit of atomicity is the unit of correctness (`transactions-and-recovery.md` 3). For the graph
        import that unit is ONE importer's data set: a known-wrong set loaded halfway is wrong, while
        yesterday's full set left untouched is still right. Before this, graph/import/import_all.py logged
        a failed importer and carried on without a rollback, so the NEXT importer's commit saved the failed
        one's partial writes. A step that commits internally (importers.import_known_wrong's retro sweep
        does, at its very end) is only as atomic as the writes after that commit."""
        try:
            result = fn(self, *args, **kwargs)
        except Exception as e:                              # noqa: BLE001
            self.conn.rollback()
            return False, None, e
        self.conn.commit()
        return True, result, None

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
                 --
                 -- And a KNOWN_WRONG ruling outranks even an asserting source.
                 -- The retro sweep runs with the seed importers; lane importers
                 -- that assert include_hit run after it, and 'the capture is
                 -- keyed by commodity id' is a claim about the PRICE belonging
                 -- to the product, not the product belonging to the commodity
                 -- (the coconut-oil incident's exact lesson). Caught same day:
                 -- FOCO Coconut Juice was demoted by the sweep, then re-blessed
                 -- include_hit by the fareway lane minutes later.
                 confidence = CASE WHEN price_observations.match_status = 'known_wrong'
                                   THEN price_observations.confidence
                                   WHEN excluded.match_status != 'unadjudicated'
                                   THEN excluded.confidence
                                   ELSE price_observations.confidence END,
                 match_status = CASE WHEN price_observations.match_status = 'known_wrong'
                                     THEN price_observations.match_status
                                     WHEN excluded.match_status != 'unadjudicated'
                                     THEN excluded.match_status
                                     ELSE price_observations.match_status END,
                 match_reason = CASE WHEN price_observations.match_status = 'known_wrong'
                                     THEN price_observations.match_reason
                                     WHEN excluded.match_status != 'unadjudicated'
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
        """Mirror one decision to the durable, git-tracked JSONL trail.

        SHARDED BY DAY, NOT BY RUN (changed 2026-08-21). It used to write
        provenance/{run_id}.jsonl - one FILE per run - which produced 162 tracked
        files on 2026-08-20 alone and 38 more by mid-morning on the 21st. 140 of
        those 201 files held a SINGLE LINE. Every runtime here commits and pushes,
        RUNTIME-MAP.md calls the git bus delicate, and OVERHAUL-4 exists to shrink
        it; ~200 new tracked files a day from a system nothing serves yet would
        have added roughly 5,000 a month.

        NOTHING IS LOST, and that is why this is the right fix rather than
        gitignoring the trail. graph/.gitignore states outright that "the durable
        record of a run lives in graph/provenance/*.jsonl (tracked)" - so ignoring
        it would delete the audit trail the design depends on, which is the
        `shrinking output leaves orphans` mistake. Every record already carries its
        own run_id and timestamp, so the FILENAME was pure redundancy: grouping by
        run is recoverable from the content with a grep, and grouping by day is
        what anyone actually reads.

        The day comes from the RECORD's own timestamp, never the wall clock. A
        replayed or backfilled event belongs in the day it happened, not the day it
        was written - the same `dates written, not measured` rule the price estate
        follows, where laundering a date surfaces later as a wrong fact.
        """
        day = ""
        ts = str(record.get("timestamp") or "")
        if len(ts) >= 10 and ts[4] == "-" and ts[7] == "-":
            day = ts[:10]
        if not day:
            # Fall back to the timestamp embedded in the run id ("run:kind:20260820T181640").
            m = re.search(r"(\d{4})(\d{2})(\d{2})T\d{6}", run or "")
            if m:
                day = f"{m.group(1)}-{m.group(2)}-{m.group(3)}"
        if not day:
            # UNDATED, not "today". Silently filing an undated record under the
            # current date is exactly the laundering the docstring warns about.
            day = "undated"
        path = os.path.join(GRAPH_DIR, "provenance", f"{day}.jsonl")
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

    # cell_state and question_verdicts are DERIVED (pipeline/state.py rebuilds
    # both from observations), but they are tracked anyway and for a different
    # reason than the rest: cell_state's git history IS the price history. Every
    # commit diff is a dated record of what changed, which is what let the
    # estate stop paying 6,500 observation rows a day to store a past nothing
    # queried. Losing the file would not lose today's answer — it would lose
    # every yesterday. question_verdicts rides along because it is the memory
    # that makes the supersede-prune safe to run at all.
    LEARNING_TABLES = (
        ("learning_proposals", "learning/proposals.json"),
        ("approved_patches", "learning/approved-patches.json"),
        ("eval_runs", "eval/eval-runs.json"),
        ("cell_state", "state/cell-state.json"),
        ("question_verdicts", "state/question-verdicts.json"),
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
        """Restore learning records from tracked JSON into a fresh database.

        Returns the rows actually INSERTED per table. A row the table already holds, or one a
        constraint refuses, is ignored by INSERT OR IGNORE and counted in `self.restore_skipped`
        instead (backlog I229: it used to be counted as restored, so a restore that kept 1 row of 3
        reported 3).
        """
        out_dir = out_dir or GRAPH_DIR
        restored = {}
        self.restore_skipped = {}
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
            n = skipped = 0
            for row in rows or []:
                cols = ", ".join(row.keys())
                marks = ", ".join(f":{k}" for k in row)
                # OR IGNORE, not ON CONFLICT(id): these tables no longer share a
                # single-column 'id' key — cell_state is keyed (commodity_id,
                # store_id) and question_verdicts (commodity_id, product_key), so
                # naming a conflict column would raise on restore, which is the
                # one moment this code exists for.
                cur = self.conn.execute(
                    f"INSERT OR IGNORE INTO {table} ({cols}) VALUES ({marks})", row)
                if cur.rowcount == 1:
                    n += 1
                else:
                    skipped += 1
            restored[table] = n
            if skipped:
                self.restore_skipped[table] = skipped
        self.conn.commit()
        return restored

    def learning_counts(self) -> dict[str, int]:
        return {t: self.conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
                for t, _ in self.LEARNING_TABLES}


def open_db(create: bool = True, allow_new: bool = False) -> GraphDB:
    """The live graph.db. Refuses a missing file unless `allow_new` (see GraphDB.__init__)."""
    return GraphDB(create=create, allow_new=allow_new)


def _selftest() -> int:
    """All-or-nothing at the unit of correctness (2026-09-18). Temp databases only, never graph.db."""
    import shutil
    import tempfile
    root = tempfile.mkdtemp(prefix="gdb-st-")
    fails = []
    cases = 0

    def check(label, cond, got):
        nonlocal cases
        cases += 1
        print(("  ok    " if cond else "  FAIL  ") + label + ("" if cond else f"   got: {got!r}"))
        if not cond:
            fails.append(label)

    def fresh(name):
        p = os.path.join(root, name + ".db")
        g = GraphDB(p, allow_new=True, restore_learning=False)
        g.conn.execute("CREATE TABLE st_rows (x TEXT)")
        g.conn.commit()
        return g, p

    def rows(p):
        c = sqlite3.connect(p)
        try:
            return [r[0] for r in c.execute("SELECT x FROM st_rows ORDER BY x")]
        finally:
            c.close()

    def boom(db, tag):
        db.conn.execute("INSERT INTO st_rows VALUES (?)", (tag,))
        raise RuntimeError("step failed after writing " + tag)

    def write(db, tag):
        db.conn.execute("INSERT INTO st_rows VALUES (?)", (tag,))
        return tag

    try:
        # MUST FIRE, THE FOUNDING BUG (half 1): a `with` block that raises after a write must not keep it.
        g, p = fresh("exit")
        try:
            with g:
                g.conn.execute("INSERT INTO st_rows VALUES ('half')")
                raise RuntimeError("fails after writing")
        except RuntimeError:
            pass
        check("MUST FIRE  a with-block that raises keeps none of its writes", rows(p) == [], rows(p))

        # CLEAN TWIN: a with-block that completes still commits.
        g, p = fresh("exit-ok")
        with g:
            g.conn.execute("INSERT INTO st_rows VALUES ('kept')")
        check("CLEAN TWIN a with-block that completes commits its writes", rows(p) == ["kept"], rows(p))

        # MUST FIRE: a failed step rolls back its own writes and says so.
        g, p = fresh("step")
        ok, res, err = g.run_step(boom, "partial")
        check("MUST FIRE  a failed step reports failure with its error",
              ok is False and res is None and isinstance(err, RuntimeError), (ok, res, err))
        check("MUST FIRE  a failed step leaves none of its writes", rows(p) == [], rows(p))

        # MUST FIRE, THE FOUNDING BUG (half 2): the NEXT step's commit must not save the failed step's
        # writes. This is what import_all did: log the failure, carry on, commit after the next importer.
        ok2, res2, err2 = g.run_step(write, "next")
        check("MUST FIRE  the next step's commit saves only its own writes", rows(p) == ["next"], rows(p))

        # CLEAN TWIN: a step that returns is committed, visible from a second connection, result intact.
        check("CLEAN TWIN a successful step returns its result and commits",
              ok2 is True and res2 == "next" and err2 is None and rows(p) == ["next"], (ok2, res2, err2))

        # CLEAN TWIN: an explicit close() still commits, which every existing caller relies on.
        g.conn.execute("INSERT INTO st_rows VALUES ('closed')")
        g.close()
        check("CLEAN TWIN an explicit close() still commits", rows(p) == ["closed", "next"], rows(p))
    except Exception as e:                                      # noqa: BLE001
        fails.append("harness: " + repr(e))
        print("  FAIL  harness raised " + repr(e))
    finally:
        shutil.rmtree(root, ignore_errors=True)

    verdict = "fail" if fails else "pass"
    print(f"GRAPHDB-SELFTEST-COMPLETE selftest={verdict} cases={cases} failures={len(fails)}")
    return 1 if fails else 0


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        raise SystemExit(_selftest())
    print("graphdb.py is a library; run it with --selftest")
