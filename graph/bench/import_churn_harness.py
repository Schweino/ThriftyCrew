"""I211 churn harness: run one import_all.py --observations pass from a given CODE ROOT against a
COPY of graph.db, with a fixed clock, and report rows inserted (by lane), rows pruned, file size,
page_count, freelist_count and the sha256 of cell_state and question_verdicts.

    python harness.py snapshot <out.db>                  # backup-API copy of the live graph.db (mode=ro)
    python harness.py run --root R --db D --ts T --out J # one import pass

Never writes the live graph.db: `snapshot` opens it mode=ro, `run` refuses a path under graph/sqlite.
"""
import hashlib
import json
import os
import sqlite3
import sys
import time

LIVE = r"C:\Codex\ThriftyCrew\graph\sqlite\graph.db"


def snapshot(out):
    src = sqlite3.connect("file:%s?mode=ro" % LIVE.replace("\\", "/"), uri=True)
    dst = sqlite3.connect(out)
    src.backup(dst)
    dst.close()
    src.close()
    print(json.dumps({"snapshot": out, "bytes": os.path.getsize(out)}))


def table_sha(conn, sql):
    h = hashlib.sha256()
    n = 0
    for r in conn.execute(sql):
        h.update(json.dumps(list(r), default=str).encode("utf-8"))
        h.update(b"\n")
        n += 1
    return h.hexdigest(), n


def measure(db_path):
    c = sqlite3.connect(db_path)
    out = {
        "bytes": os.path.getsize(db_path),
        "page_count": c.execute("PRAGMA page_count").fetchone()[0],
        "freelist_count": c.execute("PRAGMA freelist_count").fetchone()[0],
        "observations": c.execute("SELECT count(*) FROM price_observations").fetchone()[0],
    }
    out["cell_state_sha"], out["cell_state_rows"] = table_sha(
        c, "SELECT * FROM cell_state ORDER BY commodity_id, store_id")
    out["question_verdicts_sha"], out["question_verdicts_rows"] = table_sha(
        c, "SELECT * FROM question_verdicts ORDER BY commodity_id, product_key")
    # the same two tables without the run's own timestamp columns, in case a clock leaks
    out["cell_state_sha_no_ts"], _ = table_sha(
        c, "SELECT commodity_id, store_id, everyday_price, everyday_unit_price, everyday_unit, "
           "everyday_size, everyday_product, everyday_asof, everyday_evidence, ad_price, ad_unit_price, "
           "ad_product, ad_from, ad_to, ad_evidence, reverted_checked_at FROM cell_state "
           "ORDER BY commodity_id, store_id")
    out["observations_sha"], _ = table_sha(
        c, "SELECT id, commodity_id, store_id, product_name, price, unit_price, match_status, observed_at "
           "FROM price_observations ORDER BY id")
    row = c.execute("SELECT detail_json FROM decision_log WHERE decision='import_complete' "
                    "ORDER BY timestamp DESC, rowid DESC LIMIT 1").fetchone()
    c.close()
    return out, (json.loads(row[0]) if row else {})


def run(root, db_path, ts, out_json):
    if os.path.normcase(os.path.abspath(db_path)).startswith(
            os.path.normcase(os.path.abspath(os.path.dirname(LIVE)))):
        raise SystemExit("refusing: %s is under the live graph/sqlite" % db_path)
    for sub in ("lib", "import", "pipeline", "learning"):
        sys.path.insert(0, os.path.join(root, "graph", sub))
    fixed = time.strptime(ts, "%Y-%m-%dT%H:%M:%S")
    orig = time.strftime
    time.strftime = lambda fmt, t=None: orig(fmt, fixed if t is None else t)

    import graphdb
    graphdb.DB_PATH = db_path
    graphdb.GraphDB._append_jsonl = staticmethod(lambda run, record: None)
    import state
    scratch = os.path.dirname(os.path.abspath(out_json))
    tag = os.path.splitext(os.path.basename(out_json))[0]
    state.CELL_STATE_JSON = os.path.join(scratch, tag + "-cell-state.json")
    state.VERDICTS_JSON = os.path.join(scratch, tag + "-verdicts.json")
    state.STATE_DIR = scratch

    inserted = {}
    upserted = [0]
    orig_add = graphdb.GraphDB.add_observation

    def add_obs(self, obs):
        hit = self.conn.execute("SELECT 1 FROM price_observations WHERE id=?", (obs["id"],)).fetchone()
        if hit:
            upserted[0] += 1
        else:
            sf = obs.get("source_file") or ""
            parts = sf.replace("\\", "/").split("/")
            lane = parts[2] if len(parts) > 3 and parts[1] == "out" else os.path.basename(sf)
            inserted[lane] = inserted.get(lane, 0) + 1
        return orig_add(self, obs)
    graphdb.GraphDB.add_observation = add_obs

    before, _ = measure(db_path)
    import import_all
    sys.argv = ["import_all.py", "--observations", "--quiet"]
    t0 = time.time()
    rc = import_all.main()
    secs = round(time.time() - t0, 1)
    after, totals = measure(db_path)
    tot = totals.get("totals", {})
    res = {"root": root, "db": db_path, "ts": ts, "rc": rc, "seconds": secs,
           "inserted_total": sum(inserted.values()), "inserted_by_lane": inserted,
           "upserted_existing": upserted[0],
           "pruned": tot.get("superseded"), "prune_examined": tot.get("examined"),
           "observations_import": tot.get("observations"),
           "skipped_superseded": {k: v for k, v in tot.items() if "skipped_already_superseded" in k},
           "kept_because": tot.get("new_rows_kept_because"),
           "before": before, "after": after}
    with open(out_json, "w", encoding="utf-8") as fh:
        json.dump(res, fh, indent=1)
    print(json.dumps({k: res[k] for k in ("rc", "seconds", "inserted_total", "inserted_by_lane",
                                          "upserted_existing", "pruned", "skipped_superseded",
                                          "kept_because")}))
    print(json.dumps({k: after[k] for k in ("bytes", "page_count", "freelist_count", "observations",
                                            "cell_state_sha", "question_verdicts_sha")}))
    return rc


if __name__ == "__main__":
    if sys.argv[1] == "snapshot":
        snapshot(sys.argv[2])
    else:
        a = dict(zip(sys.argv[2::2], sys.argv[3::2]))
        sys.exit(run(a["--root"], a["--db"], a["--ts"], a["--out"]))
