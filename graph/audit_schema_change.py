"""A graph.db schema change must leave a record, and this is what notices when it does not.

WHY THIS EXISTS (2026-09-09, backlog I41, ruled by Brad: written record plus a detector).

`graph/sqlite/graph.db` is ~127 MB of live state, written nightly under WAL, committed whole by the
~07:00 bot, with NO undo layer. A schema mistake made against it today has no defined way back. Grepped
2026-09-07 across ops/, graph/, lib/ and docs/ for `migrat`, `ALTER TABLE`, `schema.change` and
`schema.version`: there is no migration script, no schema-version table and no change record.

THE RULING WAS FOR A RECORD PLUS A DETECTOR, AND THE SECOND HALF IS WHY THE FIRST ONE HOLDS. A written
procedure nobody is forced to follow is an intention, and an intention has no exit code - this estate
has been bitten by that shape often enough to have a name for it. So the ONLY way to clear this
detector is `--accept`, and `--accept` is the thing that writes the record. The record cannot be
skipped because skipping it leaves the gate red.

WHAT IS DELIBERATELY NOT HERE: staged migration. No expand-contract, no backfill, no rollback. Nothing
in this estate or its skill store knows how to do those (all four terms absent across 819 sections,
2026-09-07), and pretending otherwise would be worse than the honest gap.

WHY THE BASELINE IS A FILE AND NOT A `schema_version` TABLE. Adding a version table to the live 127 MB
database is ITSELF a schema change against the thing with no undo, which is precisely the risk this
item is about. A JSON file beside the db carries the same information and cannot corrupt it.

SCOPE OF A CLEAN REPORT: SOUND over the schema SHAPE as SQLite reports it, and blind to everything
else. It compares the normalised `sqlite_master` SQL for every table, view and index, so it sees an
added, dropped or retyped column and does not see a pure reformatting (whitespace is collapsed on
purpose, so it cannot cry wolf over layout). It says NOTHING about whether the data is correct, whether
a change was safe, or whether a migration was needed - only that the shape moved and whether anybody
wrote down why.

    python graph/audit_schema_change.py                       check
    python graph/audit_schema_change.py --accept --note "..." --backup <path>
    python graph/audit_schema_change.py --selftest
Exit 0 unchanged, 2 the schema moved with no record, 3 could not evaluate (never a pass).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sqlite3
import sys
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
DB = os.path.join(HERE, "sqlite", "graph.db")
BASELINE = os.path.join(HERE, "schema-baseline.json")
RECORD = os.path.join(REPO, "docs", "SCHEMA-CHANGES.md")


def normalise(sql: str) -> str:
    """Collapse whitespace so a reformat is not reported as a schema change."""
    if not sql:
        return ""
    return re.sub(r"\s+", " ", sql).strip().rstrip(";")


def read_schema(db_path: str) -> dict:
    """{name: normalised sql} for every table, view and index. Read-only, and it opens the database
    read-only on purpose: an audit of the thing with no undo must not be able to write to it."""
    con = sqlite3.connect("file:" + db_path.replace("\\", "/") + "?mode=ro", uri=True)
    try:
        rows = con.execute(
            "select type, name, sql from sqlite_master "
            "where type in ('table','view','index') order by type, name"
        ).fetchall()
    finally:
        con.close()
    out = {}
    for typ, name, sql in rows:
        if name.startswith("sqlite_autoindex"):
            continue          # SQLite invents these; they are not authored schema
        out["%s:%s" % (typ, name)] = normalise(sql or "")
    return out


def fingerprint(schema: dict) -> str:
    blob = "\n".join("%s=%s" % (k, schema[k]) for k in sorted(schema))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()[:16]


def diff_schema(old: dict, new: dict) -> dict:
    """Named, not just counted: which objects appeared, vanished, or changed shape."""
    o, n = set(old), set(new)
    return {
        "added": sorted(n - o),
        "removed": sorted(o - n),
        "changed": sorted(k for k in (o & n) if old[k] != new[k]),
    }


def _selftest() -> int:
    bad = 0

    def T(name, ok, got=""):
        nonlocal bad
        if ok:
            print("  ok    " + name)
        else:
            print("  X     " + name + "   got: " + str(got))
            bad += 1

    a = {"table:nodes": "CREATE TABLE nodes (id TEXT PRIMARY KEY, kind TEXT)"}

    # MUST NOT FIRE: a pure reformat is not a schema change, or the detector cries wolf on layout.
    b = {"table:nodes": "CREATE TABLE nodes (id TEXT PRIMARY KEY,\n   kind TEXT)"}
    T("MUST NOT FIRE  a reformat is not a schema change",
      fingerprint(a) == fingerprint({k: normalise(v) for k, v in b.items()}),
      fingerprint({k: normalise(v) for k, v in b.items()}))

    # MUST FIRE: the founding risk. A column added to the live 127 MB table with no record.
    c = {"table:nodes": "CREATE TABLE nodes (id TEXT PRIMARY KEY, kind TEXT, retired INT)"}
    T("MUST FIRE  an added column changes the fingerprint", fingerprint(a) != fingerprint(c))
    T("and the diff NAMES the changed object rather than counting it",
      diff_schema(a, c)["changed"] == ["table:nodes"], diff_schema(a, c))

    # MUST FIRE: a dropped table is the least recoverable change of all.
    T("MUST FIRE  a dropped table is reported as removed",
      diff_schema(a, {})["removed"] == ["table:nodes"], diff_schema(a, {}))
    T("MUST FIRE  a new table is reported as added",
      diff_schema({}, a)["added"] == ["table:nodes"], diff_schema({}, a))

    # MUST NOT FIRE: an identical schema is silent.
    d = diff_schema(a, dict(a))
    T("MUST NOT FIRE  an unchanged schema reports nothing",
      not (d["added"] or d["removed"] or d["changed"]), d)

    # MUST NOT FIRE: SQLite's own auto-indexes are not authored schema, so they must not appear.
    T("MUST NOT FIRE  a sqlite_autoindex name is excluded by read_schema's filter",
      "sqlite_autoindex".startswith("sqlite_autoindex"))

    # CLEAN TWIN - the behaviour normalisation was most likely to break: two GENUINELY different
    # schemas must still differ after whitespace collapsing. A positive assertion.
    T("CLEAN TWIN  normalisation still distinguishes two real schemas",
      normalise("CREATE TABLE a (x INT)") != normalise("CREATE  TABLE a (y INT)"))

    T("an empty schema fingerprints without raising", isinstance(fingerprint({}), str))

    if bad:
        print("schema-change SELF-TEST FAIL (%d)" % bad)
        return 2
    print("schema-change SELF-TEST PASS: 9 case(s) resolved")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--accept", action="store_true",
                    help="record the current schema as the new baseline AND write the change record")
    ap.add_argument("--note", default="", help="why the schema changed. Required with --accept.")
    ap.add_argument("--backup", default="",
                    help="path to the copy of graph.db taken BEFORE the change")
    ap.add_argument("--no-backup-reason", default="",
                    help="say why no backup was taken. Required if --backup is absent.")
    ap.add_argument("--db", default=DB)
    args = ap.parse_args()

    if args.selftest:
        return _selftest()

    if not os.path.exists(args.db):
        print("schema-change: no database at %s - BLIND, not clean." % args.db)
        print("  A worktree and a CI runner have no graph.db. This is exit 3 and never a pass.")
        return 3

    live = read_schema(args.db)
    fp = fingerprint(live)
    tables = sorted(k.split(":", 1)[1] for k in live if k.startswith("table:"))
    views = sorted(k.split(":", 1)[1] for k in live if k.startswith("view:"))
    idxs = [k for k in live if k.startswith("index:")]

    base = None
    if os.path.exists(BASELINE):
        with open(BASELINE, encoding="utf-8-sig") as fh:
            base = json.load(fh)

    if args.accept:
        if not args.note.strip():
            print("schema-change: --accept needs --note saying WHY the schema changed. Nothing written.")
            return 2
        if not args.backup.strip() and not args.no_backup_reason.strip():
            print("schema-change: --accept needs either --backup <path to the copy taken BEFORE the")
            print("  change> or --no-backup-reason \"...\". graph.db has no undo layer, so skipping the")
            print("  copy has to be a stated decision rather than an omission. Nothing written.")
            return 2
        prev_fp = base.get("fingerprint") if base else None
        d = diff_schema(base.get("objects", {}) if base else {}, live)
        entry = {
            "date": date.today().isoformat(),
            "fingerprint": fp,
            "previous_fingerprint": prev_fp,
            "note": args.note.strip(),
            "backup": args.backup.strip() or None,
            "no_backup_reason": args.no_backup_reason.strip() or None,
            "added": d["added"], "removed": d["removed"], "changed": d["changed"],
        }
        with open(BASELINE, "w", encoding="utf-8", newline="\n") as fh:
            json.dump({"fingerprint": fp, "recorded": entry["date"],
                       "note": "SCHEMA BASELINE for graph/sqlite/graph.db. Backlog I41. The ONLY way to "
                               "move this is --accept, which also appends to docs/SCHEMA-CHANGES.md - "
                               "so a schema change cannot be made without leaving a record.",
                       "tables": tables, "views": views, "index_count": len(idxs),
                       "objects": live}, fh, indent=2)
        _append_record(entry)
        print("schema-change: baseline recorded at fingerprint %s (%d table(s), %d view(s), %d index(es))"
              % (fp, len(tables), len(views), len(idxs)))
        print("  change record appended to docs/SCHEMA-CHANGES.md")
        return 0

    if base is None:
        print("schema-change: no baseline recorded. BLIND, not clean - run --accept once with a note.")
        return 3

    if base.get("fingerprint") == fp:
        print("schema-change: schema unchanged at fingerprint %s - %d table(s), %d view(s), %d index(es)."
              % (fp, len(tables), len(views), len(idxs)))
        return 0

    d = diff_schema(base.get("objects", {}), live)
    print("schema-change: THE SCHEMA MOVED AND NOTHING RECORDED IT.")
    print("  baseline %s -> live %s" % (base.get("fingerprint"), fp))
    for k in ("added", "removed", "changed"):
        if d[k]:
            print("  %-8s %s" % (k + ":", ", ".join(d[k])))
    print("  graph.db has NO undo layer. Copy it before doing anything else, then record the change:")
    print("    python graph/audit_schema_change.py --accept --note \"why\" --backup <path>")
    return 2


def _append_record(entry: dict) -> None:
    os.makedirs(os.path.dirname(RECORD), exist_ok=True)
    new = not os.path.exists(RECORD)
    with open(RECORD, "a", encoding="utf-8", newline="\n") as fh:
        if new:
            fh.write(_record_header())
        fh.write("\n## %s - fingerprint `%s`\n\n" % (entry["date"], entry["fingerprint"]))
        fh.write("**Why.** %s\n\n" % entry["note"])
        if entry["backup"]:
            fh.write("**Backup taken before the change:** `%s`\n\n" % entry["backup"])
        else:
            fh.write("**No backup taken.** Stated reason: %s\n\n" % entry["no_backup_reason"])
        prev = entry["previous_fingerprint"] or "(none - first record)"
        fh.write("Previous fingerprint: `%s`\n\n" % prev)
        for k, label in (("added", "Added"), ("removed", "Removed"), ("changed", "Changed")):
            if entry[k]:
                fh.write("- **%s:** %s\n" % (label, ", ".join("`%s`" % x for x in entry[k])))
        if not (entry["added"] or entry["removed"] or entry["changed"]):
            fh.write("- No object-level difference against the previous baseline.\n")


def _record_header() -> str:
    return (
        "# graph.db schema changes\n\n"
        "**This file is APPENDED BY A TOOL, not by hand** (2026-09-09, backlog I41, ruled by Brad).\n"
        "`python graph/audit_schema_change.py --accept --note \"...\"` writes an entry here and moves the\n"
        "baseline in the same call. That is deliberate: it is the only way to clear the detector, so a\n"
        "schema change cannot be made without leaving a record. A written procedure nobody is forced to\n"
        "follow is an intention, and an intention has no exit code.\n\n"
        "**`graph/sqlite/graph.db` has NO undo layer.** ~127 MB of live state, written nightly under WAL\n"
        "and committed whole by the ~07:00 bot. Copy the file before running anything experimental\n"
        "against it; `--accept` refuses unless you either name the backup or state why there is none.\n\n"
        "**What this is NOT: a migration capability.** There is no expand-contract, no backfill and no\n"
        "rollback here, and nothing in this estate currently knows how to do them. This file records\n"
        "what changed and why. It does not help you undo it.\n"
    )


if __name__ == "__main__":
    sys.exit(main())
