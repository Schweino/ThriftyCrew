"""probe_cold_corpus_scrub.py - re-read the cold corpora nothing re-reads, and count what has rotted.

WHY (backlog I119). A check that only runs when something reads has no coverage over the things nobody
reads, and its clean report is a statement about traffic rather than about data. The daily chain audits
today's board. This probe reads the COMMITTED bytes (the HEAD blob, never the working copy, so a fresh
CRLF checkout cannot read as rot) of three corpora and counts five classes, each with its denominator:

  PARSE      a line or file that is not valid JSON, or carries a NUL, a BOM past byte 0, or a CR
  DUP        a repeated `id` inside one gold file, or a repeated `event_id` across the provenance trail
  MISFILED   a provenance record whose own timestamp day is not the day its file is named for
             (graph/lib/graphdb.py `_append_jsonl` shards by RECORD day, so this is a writer defect)
  REWRITTEN  a commit to a provenance file whose previous blob is not a byte prefix of the new one:
             an append-only trail whose past was edited
  DANGLING   a gold row whose `commodity` is in none of the three id namespaces (graph/lib/ids.py):
             staple grocery/commodities.json, recipe grocery/recipe-commodities.json, and the recipe
             FLOOR ids (grocery/out/recipe-board-everyday.json, grocery/recipe-floor-id-map.json), plus the
             board ids meal-prep/ingredient-map.json maps to

Corpora: graph/gold/*.jsonl, graph/provenance/*.jsonl, and every tracked .json/.jsonl under meal-prep/db.

It is a REPORT, never a gate: exit 0 whatever it finds, 3 when it could not read the tree. It writes
nothing unless --rows names a file, which gets ONE ROW PER FINDING.

SCOPE OF A CLEAN REPORT: UNSOUND. It checks five named classes over the committed bytes. A value that is
well-formed, unique, correctly filed, never rewritten and names a live id can still be wrong; a clean
report says only that none of these five shapes of rot is present.

Run:  C:\\Codex\\Python312\\python.exe ops\\probe_cold_corpus_scrub.py [--rows out.jsonl] [--rev HEAD]
      C:\\Codex\\Python312\\python.exe ops\\probe_cold_corpus_scrub.py --selftest
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter

GOLD_PREFIX = "graph/gold/"
PROV_PREFIX = "graph/provenance/"
DB_PREFIX = "meal-prep/db/"
PROV_NAME = re.compile(r"^graph/provenance/(\d{4}-\d{2}-\d{2})\.jsonl$")


# ---------------------------------------------------------------- pure classifiers (self-tested)
def byte_defects(data: bytes) -> list[str]:
    """Byte-level damage a JSON parser may not name: NUL, a BOM anywhere but byte 0, a CR."""
    out = []
    if b"\x00" in data:
        out.append("nul")
    if data.find(b"\xef\xbb\xbf", 1) != -1:
        out.append("bom-past-0")
    if b"\r" in data:
        out.append("cr")
    return out


def parse_jsonl(data: bytes) -> tuple[list, list[int]]:
    """Parse each non-empty line. Returns (records, bad line numbers). A BOM at byte 0 is legal."""
    text = data.decode("utf-8-sig", errors="replace")
    recs, bad = [], []
    for n, line in enumerate(text.split("\n"), 1):
        if not line.strip():
            continue
        try:
            recs.append(json.loads(line))
        except ValueError:
            bad.append(n)
    return recs, bad


def record_day(rec) -> str | None:
    """The day a provenance record belongs to, by the writer's own rule: timestamp, then run id."""
    if not isinstance(rec, dict):
        return None
    ts = str(rec.get("timestamp") or "")
    if len(ts) >= 10 and ts[4] == "-" and ts[7] == "-":
        return ts[:10]
    m = re.search(r"(\d{4})(\d{2})(\d{2})T\d{6}", str(rec.get("run_id") or ""))
    return f"{m.group(1)}-{m.group(2)}-{m.group(3)}" if m else None


def is_append_only(old: bytes, new: bytes) -> bool:
    return new.startswith(old)


def dup_values(values) -> dict:
    c = Counter(v for v in values if v is not None)
    return {k: n for k, n in c.items() if n > 1}


# ---------------------------------------------------------------- git plumbing
def git(*args: str) -> bytes:
    return subprocess.run(["git", *args], check=True, capture_output=True).stdout


def blob(rev: str, path: str) -> bytes:
    return git("cat-file", "blob", f"{rev}:{path}")


def tracked(rev: str) -> list[str]:
    return git("ls-tree", "-r", "--name-only", rev).decode("utf-8").splitlines()


def commodity_universe(rev: str) -> set[str]:
    ids: set[str] = set()
    for c in json.loads(blob(rev, "grocery/commodities.json").decode("utf-8-sig")):
        ids.add(c["id"])
    rc = json.loads(blob(rev, "grocery/recipe-commodities.json").decode("utf-8-sig"))
    for c in rc.get("commodities", []):
        if isinstance(c, dict) and c.get("id"):
            ids.add(c["id"])
    im = json.loads(blob(rev, "meal-prep/ingredient-map.json").decode("utf-8-sig"))
    maps = im.get("mappings", {})
    for v in (maps.values() if isinstance(maps, dict) else maps):
        if isinstance(v, dict):
            for k in ("board_id", "commodity", "id", "commodity_id"):
                if isinstance(v.get(k), str):
                    ids.add(v[k])
    # The third namespace: recipe FLOOR ids, which live on the recipe board and in the floor-id map.
    rb = json.loads(blob(rev, "grocery/out/recipe-board-everyday.json").decode("utf-8-sig"))
    for c in rb.get("comparison", []):
        if isinstance(c, dict) and c.get("id"):
            ids.add(c["id"])
    fm = json.loads(blob(rev, "grocery/recipe-floor-id-map.json").decode("utf-8-sig"))
    for k, v in (fm.get("map") or {}).items():
        ids.add(k)
        if isinstance(v, str):
            ids.add(v)
    return ids


# ---------------------------------------------------------------- the scrub
def scrub(rev: str, rows: list) -> dict:
    files = tracked(rev)
    head = git("rev-parse", rev).decode().strip()
    t = {"rev": head}

    def find(cls, corpus, path, detail):
        rows.append({"class": cls, "corpus": corpus, "path": path, "detail": detail, "rev": head})

    # --- gold
    universe = commodity_universe(rev)
    g_files = [f for f in files if f.startswith(GOLD_PREFIX) and f.endswith(".jsonl")]
    g_lines = g_bad = g_dang = g_dup = g_byte = 0
    for p in g_files:
        data = blob(rev, p)
        for d in byte_defects(data):
            g_byte += 1
            find("PARSE", "gold", p, d)
        recs, bad = parse_jsonl(data)
        g_lines += len(recs) + len(bad)
        g_bad += len(bad)
        for n in bad:
            find("PARSE", "gold", p, f"line {n}")
        for k, n in dup_values(r.get("id") for r in recs if isinstance(r, dict)).items():
            g_dup += n - 1
            find("DUP", "gold", p, f"id {k} x{n}")
        for r in recs:
            cid = r.get("commodity") if isinstance(r, dict) else None
            if cid and cid not in universe:
                g_dang += 1
                find("DANGLING", "gold", p, f"{r.get('id')} commodity={cid}")
    t["gold"] = dict(files=len(g_files), rows=g_lines, parse_bad=g_bad, byte_defects=g_byte,
                     dup=g_dup, dangling=g_dang, universe=len(universe))

    # --- provenance
    p_files = [f for f in files if PROV_NAME.match(f)]
    p_lines = p_bad = p_mis = p_byte = p_undated = 0
    ev = []
    for p in p_files:
        day = PROV_NAME.match(p).group(1)
        data = blob(rev, p)
        for d in byte_defects(data):
            p_byte += 1
            find("PARSE", "provenance", p, d)
        recs, bad = parse_jsonl(data)
        p_lines += len(recs) + len(bad)
        p_bad += len(bad)
        for n in bad:
            find("PARSE", "provenance", p, f"line {n}")
        for r in recs:
            rd = record_day(r)
            if rd is None:
                p_undated += 1
            elif rd != day:
                p_mis += 1
                find("MISFILED", "provenance", p, f"{r.get('event_id')} day={rd}")
            if isinstance(r, dict):
                ev.append(r.get("event_id"))
    p_dup = 0
    for k, n in dup_values(ev).items():
        p_dup += n - 1
        find("DUP", "provenance", "*", f"event_id {k} x{n}")
    # REWRITTEN: walk each file's history oldest-first and require every blob to extend the last.
    commits_seen = rewritten = 0
    for p in p_files:
        hist = git("log", "--format=%H", "--reverse", rev, "--", p).decode().split()
        prev = None
        for c in hist:
            try:
                cur = blob(c, p)
            except subprocess.CalledProcessError:
                prev = None          # deleted at this commit; the next add starts a new chain
                continue
            if prev is not None:
                commits_seen += 1
                if not is_append_only(prev, cur):
                    rewritten += 1
                    find("REWRITTEN", "provenance", p, f"commit {c[:10]} old={len(prev)}B new={len(cur)}B")
            prev = cur
    t["provenance"] = dict(files=len(p_files), rows=p_lines, parse_bad=p_bad, byte_defects=p_byte,
                           dup=p_dup, misfiled=p_mis, undated=p_undated,
                           transitions=commits_seen, rewritten=rewritten)

    # --- meal-prep/db
    d_files = [f for f in files if f.startswith(DB_PREFIX) and (f.endswith(".json") or f.endswith(".jsonl"))]
    d_bad = d_byte = d_lines = 0
    for p in d_files:
        data = blob(rev, p)
        for d in byte_defects(data):
            d_byte += 1
            find("PARSE", "meal-prep-db", p, d)
        if p.endswith(".jsonl"):
            recs, bad = parse_jsonl(data)
            d_lines += len(recs) + len(bad)
            for n in bad:
                d_bad += 1
                find("PARSE", "meal-prep-db", p, f"line {n}")
        else:
            try:
                json.loads(data.decode("utf-8-sig"))
            except ValueError as e:
                d_bad += 1
                find("PARSE", "meal-prep-db", p, f"json: {str(e)[:80]}")
    t["meal_prep_db"] = dict(files=len(d_files), jsonl_rows=d_lines, parse_bad=d_bad, byte_defects=d_byte)
    return t


# ---------------------------------------------------------------- self-test
def selftest() -> int:
    fails = 0
    ran = 0

    def case(label, cond):
        nonlocal fails, ran
        ran += 1
        print(("  ok    " if cond else "  FAIL  ") + label)
        if not cond:
            fails += 1

    nul = b'{"a":1}' + b"\x00" + b"\n"
    case("MUST FIRE      a NUL byte is a byte defect", "nul" in byte_defects(nul))
    case("MUST FIRE      a BOM past byte 0 is a byte defect",
         "bom-past-0" in byte_defects(b'{"a":1}\n' + b"\xef\xbb\xbf" + b'{"b":2}\n'))
    case("MUST FIRE      a CR is a byte defect", "cr" in byte_defects(b'{"a":1}\r\n'))
    case("MUST NOT FIRE  a BOM at byte 0 is legal", byte_defects(b"\xef\xbb\xbf" + b'{"a":1}\n') == [])
    recs, bad = parse_jsonl(b'{"a":1}\n{"a":\n\n{"b":2}\n')
    case("MUST FIRE      a truncated line is named by number", bad == [2])
    case("CLEAN TWIN     the good lines around it still parse", len(recs) == 2 and recs[1] == {"b": 2})
    case("MUST FIRE      a record stamped another day is not this day",
         record_day({"timestamp": "2026-09-13T01:00:00"}) == "2026-09-13")
    case("CLEAN TWIN     a record with no timestamp takes its run id's day",
         record_day({"timestamp": None, "run_id": "run:import:20260918T081526"}) == "2026-09-18")
    case("MUST NOT FIRE  a record with neither is undated, not misfiled", record_day({"x": 1}) is None)
    case("MUST FIRE      an edited past line is not append-only",
         not is_append_only(b'{"a":1}\n{"b":2}\n', b'{"a":9}\n{"b":2}\n{"c":3}\n'))
    case("MUST FIRE      a dropped line is not append-only",
         not is_append_only(b'{"a":1}\n{"b":2}\n', b'{"a":1}\n'))
    case("MUST NOT FIRE  a pure append is append-only",
         is_append_only(b'{"a":1}\n', b'{"a":1}\n{"b":2}\n'))
    case("MUST FIRE      a repeated id is counted", dup_values(["x", "y", "x"]) == {"x": 2})
    case("MUST NOT FIRE  a missing id is not a duplicate", dup_values([None, None, "x"]) == {})
    expected = 14
    case(f"CLEAN TWIN     the literal case list ran in full ({expected})", ran == expected)
    print(f"probe_cold_corpus_scrub self-test: {'PASS' if fails == 0 else 'FAIL'} ({ran - fails} of {ran} cases)")
    return 0 if fails == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--rev", default="HEAD")
    ap.add_argument("--rows", default="")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    rows: list = []
    try:
        t = scrub(a.rev, rows)
    except (subprocess.CalledProcessError, OSError, KeyError, ValueError) as e:
        print(f"could not read the tree: {e}")
        print("COLD-CORPUS-SCRUB-COMPLETE blind=could-not-read")
        return 3
    print(f"cold-corpus scrub at {t['rev'][:10]}")
    for k in ("gold", "provenance", "meal_prep_db"):
        print(f"  {k:<13} " + "  ".join(f"{n}={v}" for n, v in t[k].items()))
    by = Counter(r["class"] for r in rows)
    print("  findings by class: " + (", ".join(f"{k}={v}" for k, v in sorted(by.items())) or "none"))
    for r in rows[:40]:
        print(f"    {r['class']:<9} {r['corpus']:<12} {r['path']}  {r['detail']}")
    if len(rows) > 40:
        print(f"    ... {len(rows) - 40} more (use --rows)")
    if a.rows:
        with open(a.rows, "w", encoding="utf-8", newline="\n") as fh:
            for r in rows:
                fh.write(json.dumps(r, sort_keys=True) + "\n")
    print(f"COLD-CORPUS-SCRUB-COMPLETE findings={len(rows)} rev={t['rev'][:10]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
