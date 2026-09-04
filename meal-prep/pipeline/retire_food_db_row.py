#!/usr/bin/env python3
r"""retire_food_db_row.py - retire ONE duplicate row from meal-prep\food-macros-db.json in favour of
the row that survives, and record the ruling so the merge is auditable and reversible.

WHY THIS EXISTS. The write-time collision check (0b9f8bf5) stops the duplicate backlog GROWING - it
names a collision at the write instead of parking the recipe - but it merges NOTHING, so there was no
gated road for retiring the loser of a pair. The only alternative was a hand edit of a load-bearing
data file with no gate on it.

WHY IT IS PYTHON, having first been written in PowerShell (2026-09-04, same day). The food DB's
sanctioned writer is hunt-daemon's `write_food_db_rows`, and it writes
`json.dump(payload, f, ensure_ascii=False, indent=1)`. PowerShell's ConvertTo-Json cannot reproduce
that: the first merge through the .ps1 version rewrote all 435 rows at 4-space indent with every
apostrophe escaped to \u0027, turning a 3-row deletion into a 6,288-line diff and growing the file
47%. Nothing about the DATA was wrong - 3 rows removed, zero content changes - but a diff nobody can
read is a review nobody performs, which is the reason this repo has a .gitattributes at all. Worse, it
was a SECOND WRITER with its own house style: the next daemon write would have reformatted it back,
and the two would have ping-ponged forever. One writer, one format.

WHAT IT REFUSES, and why each refusal is the point:

  * a retiring row that is REFERENCED ANYWHERE. A food-DB row is looked up by NAME - the conflict rule
    and Get-MacroRecompute are both name-keyed - so retiring a name something still cites turns a
    working macro lookup into a silent absence rather than an error.
  * a survivor the DB does not hold, which is a deletion wearing a merge's clothes.
  * retire == survivor.

WHAT IT IS NOT. It does not decide WHICH row survives. That is a food-identity call with real macro
consequences - the two contested pairs on 2026-09-04 differed by 52 vs 63 cal and 20.2 vs 17 cal per
100 g - so the ruling is Brad's and this records it. Provenance is never a merge tiebreak.

USAGE
  C:\Codex\Python312\python.exe retire_food_db_row.py --retire Apples --survivor Apple --reason "..."
  ... --dry-run
  C:\Codex\Python312\python.exe retire_food_db_row.py --selftest
"""
import argparse
import json
import os
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)

FOOD_DB = os.path.join(MP, "food-macros-db.json")
LEDGER = os.path.join(MP, "db", "food-db-merges.json")
# Every place a food-DB row is cited by name. db\recipes is the spec store the cards render from;
# ingredients.json is the vocabulary a canon name resolves through.
REF_ROOTS = (os.path.join(MP, "db", "recipes"),
             os.path.join(MP, "db", "ingredients.json"),
             os.path.join(MP, "recipes-db.json"),
             os.path.join(MP, "db", "costed.json"),
             os.path.join(MP, "db", "densities.json"),
             os.path.join(MP, "db", "each-nouns.json"))

EXIT_CLEAN, EXIT_REFUSED = 0, 1


# =====================================================================================================
# PURE PREDICATES - pinned without a DB, a spec store or a disk write.
# =====================================================================================================

def db_rows(doc):
    """The row list, whichever shape the file is in.

    A shape this does not recognise returns an EMPTY list and the caller REFUSES - it must never read
    as "the DB has no rows", which is the plausibility-floor lesson ingredient-vocab records after a
    544-recipe estate was reported to own 8 ingredients.
    """
    if isinstance(doc, dict):
        items = doc.get("items")
        return items if isinstance(items, list) else []
    if isinstance(doc, list):
        return doc
    return []


def find_row(rows, name):
    """Index of the row whose item is EXACTLY this name, or -1.

    Exact and case sensitive, because the whole defect class this cleans up came from a lookup that
    was exact while the human eye was not.
    """
    for i, r in enumerate(rows or []):
        if isinstance(r, dict) and r.get("item") == name:
            return i
    return -1


def name_cited(text, name):
    """Is this name cited as a WHOLE JSON string in this text?

    THE QUOTES ARE THE CHECK. A substring sweep for 'Lemon' hits 'Lemons' and 'Lemon Juice' and would
    refuse every merge forever; a sweep ignoring quoting would hit prose. A food-DB row is cited by
    exact name inside a JSON string, so that is what is looked for and nothing else.
    """
    if not name:
        return False
    return ('"%s"' % name) in (text or "")


def merge_record(retired, survivor, reason, at):
    """BOTH rows, verbatim, so a merge is reversible from its own record rather than by
    re-transcribing a label."""
    return {"at": at, "retired": retired, "survivor": survivor, "reason": reason}


def json_files(root):
    """Every .json under a root, or the root itself when it is a file."""
    if os.path.isfile(root):
        return [root]
    out = []
    for base, _dirs, names in os.walk(root):
        for n in names:
            if n.endswith(".json"):
                out.append(os.path.join(base, n))
    return out


def citations(name, roots):
    """Which files cite this name. Missing roots are skipped, never counted as clean."""
    hits = []
    for root in roots:
        if not os.path.exists(root):
            continue
        for f in json_files(root):
            try:
                with open(f, "r", encoding="utf-8-sig") as fh:
                    text = fh.read()
            except Exception:                                     # noqa: BLE001
                continue
            if name_cited(text, name):
                hits.append(f)
    return hits


def write_db(path, payload):
    """THE ONE HOUSE FORMAT: ensure_ascii=False, indent=1, utf-8 - byte-identical to what
    hunt-daemon's write_food_db_rows produces, so the adder and this never reformat each other."""
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


# =====================================================================================================
def retire(retire_name, survivor_name, reason, db_path, ledger_path, roots, dry_run=False,
           out=print):
    """Returns an exit code. Every refusal explains itself and changes nothing."""
    if not retire_name:
        out("retire-food-db-row: REFUSED - pass --retire <exact row name>.")
        return EXIT_REFUSED
    if not survivor_name:
        out("retire-food-db-row: REFUSED - pass --survivor: this records a ruling, it does not make one.")
        return EXIT_REFUSED
    if retire_name == survivor_name:
        out("retire-food-db-row: REFUSED - --retire and --survivor are the same row (%r)." % retire_name)
        return EXIT_REFUSED
    if not reason:
        out("retire-food-db-row: REFUSED - pass --reason: a merge with no stated reason is not auditable.")
        return EXIT_REFUSED
    try:
        with open(db_path, "r", encoding="utf-8-sig") as f:
            doc = json.load(f)
    except Exception as e:                                        # noqa: BLE001
        out("retire-food-db-row: REFUSED - the food DB could not be read (%s)" % e)
        return EXIT_REFUSED

    rows = db_rows(doc)
    if not rows:
        out("retire-food-db-row: REFUSED - read 0 rows from %s. That is a shape this does not "
            "recognise, not an empty DB." % db_path)
        return EXIT_REFUSED

    ri, si = find_row(rows, retire_name), find_row(rows, survivor_name)
    if ri < 0:
        out("retire-food-db-row: REFUSED - no row named exactly %r (the match is case sensitive)."
            % retire_name)
        return EXIT_REFUSED
    if si < 0:
        out("retire-food-db-row: REFUSED - no row named exactly %r to retire it in favour of. That "
            "would be a deletion, not a merge." % survivor_name)
        return EXIT_REFUSED

    cited = citations(retire_name, roots)
    if cited:
        out("retire-food-db-row: REFUSED - %r is still cited by %d file(s):" % (retire_name, len(cited)))
        for f in cited[:10]:
            out("    %s" % f)
        out("  A food-DB row is looked up by NAME, so retiring one still cited turns a working macro")
        out("  lookup into a silent absence. Re-point those citations at %r first." % survivor_name)
        return EXIT_REFUSED

    out("retire-food-db-row: %r -> %r" % (retire_name, survivor_name))
    out("  retiring: %s" % json.dumps(rows[ri], ensure_ascii=False, sort_keys=True)[:400])
    out("  survivor: %s" % json.dumps(rows[si], ensure_ascii=False, sort_keys=True)[:400])
    out("  cited by: nothing (%d root(s) swept)" % len(roots))
    if dry_run:
        out("  --dry-run: nothing written.")
        out("RETIRE-FOOD-DB-ROW-COMPLETE")
        return EXIT_CLEAN

    rec = merge_record(rows[ri], rows[si], reason, time.strftime("%Y-%m-%dT%H:%M:%S"))
    kept = [r for i, r in enumerate(rows) if i != ri]
    if isinstance(doc, dict):
        doc["items"] = kept
        payload = doc
    else:
        payload = kept
    write_db(db_path, payload)

    led = {}
    try:
        with open(ledger_path, "r", encoding="utf-8-sig") as f:
            led = json.load(f) or {}
    except Exception:                                             # noqa: BLE001
        led = {}
    merges = led.get("merges") if isinstance(led.get("merges"), list) else []
    merges.append(rec)
    d = os.path.dirname(ledger_path)
    if d and not os.path.isdir(d):
        os.makedirs(d)
    with open(ledger_path, "w", encoding="utf-8") as f:
        json.dump({"readme": "Food-DB duplicate merges. Each record carries BOTH rows verbatim so the "
                             "merge is reversible from this file alone. Written only by "
                             "retire_food_db_row.py.",
                   "merges": merges}, f, ensure_ascii=False, indent=1)

    out("  retired. %d row(s) remain; ruling recorded in %s" % (len(kept), ledger_path))
    out("RETIRE-FOOD-DB-ROW-COMPLETE")
    return EXIT_CLEAN


# =====================================================================================================
def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    T("MUST FIRE  an items-wrapped DB yields its rows",
      len(db_rows({"items": [{"item": "A"}]})) == 1)
    T("MUST FIRE  a bare array DB yields its rows",
      len(db_rows([{"item": "A"}, {"item": "B"}])) == 2)
    T("MUST FIRE  a shape this does not recognise yields NO rows, so the caller refuses rather than "
      "reporting an empty DB", db_rows({"nope": 1}) == [] and db_rows("x") == [])

    rows = [{"item": "Apple"}, {"item": "Apples"}]
    T("MUST FIRE  the index is found by EXACT name", find_row(rows, "Apples") == 1)
    T("CLEAN TWIN a near name is NOT the row - 'Apple' must never resolve to 'Apples', which is the "
      "very confusion this file cleans up", find_row(rows, "Apple") == 0)
    T("MUST FIRE  a name the DB does not hold is -1, never 0", find_row(rows, "Pear") == -1)
    T("MUST FIRE  the match is case SENSITIVE, so a case-blind merge cannot retire a row nobody "
      "ruled on", find_row(rows, "apples") == -1)

    doc = '{"item":"Lemons","note":"squeeze a Lemon over it","other":"Lemon Juice"}'
    T("MUST FIRE  a name cited as a whole JSON string is FOUND", name_cited(doc, "Lemons"))
    T("CLEAN TWIN the same name inside PROSE is not a citation - a prose sweep would refuse every "
      "merge forever", not name_cited(doc, "Lemon"))
    T("CLEAN TWIN a LONGER name that merely starts with this one is not a citation either "
      "('Lemon' must not match 'Lemon Juice')", not name_cited('{"x":"Lemon Juice"}', "Lemon"))
    T("MUST FIRE  an empty name is never cited, so a missing argument cannot read as a clean sweep",
      not name_cited(doc, ""))

    rec = merge_record({"item": "Apples", "calories": 63}, {"item": "Apple", "calories": 52},
                       "why", "2026-09-04T00:00:00")
    T("MUST FIRE  the record carries BOTH rows verbatim, so the merge is reversible from its own "
      "ledger rather than by re-transcribing a label",
      rec["retired"]["calories"] == 63 and rec["survivor"]["calories"] == 52)
    T("MUST FIRE  ...and the stated reason rides with it", rec["reason"] == "why")

    tmp = tempfile.mkdtemp(prefix="rfdb-")
    try:
        db = os.path.join(tmp, "food.json")
        led = os.path.join(tmp, "merges.json")
        ref = os.path.join(tmp, "refs")
        os.makedirs(ref)

        def fresh(extra=None):
            payload = {"items": [{"item": "Apple", "serving_grams": 100, "calories": 52},
                                 {"item": "Apples", "serving_grams": 100, "calories": 63}]}
            if extra:
                payload["items"] = extra + payload["items"]
            write_db(db, payload)

        def cite(name):
            with open(os.path.join(ref, "a.json"), "w", encoding="utf-8") as f:
                json.dump({"item": name}, f)

        def load():
            with open(db, "r", encoding="utf-8-sig") as f:
                return db_rows(json.load(f))

        said = []
        fresh(); cite("Apple")
        rc = retire("Apples", "Apple", "orphan", db, led, [ref], out=said.append)
        now = load()
        T("MUST FIRE  a clean retire exits 0 and the row is GONE",
          rc == EXIT_CLEAN and find_row(now, "Apples") == -1, "rc=%s" % rc)
        T("MUST FIRE  ...and the SURVIVOR is untouched, with its own macros - a merge that quietly "
          "rewrote the survivor would be the defect wearing the fix's clothes",
          find_row(now, "Apple") >= 0 and now[find_row(now, "Apple")]["calories"] == 52)
        with open(led, "r", encoding="utf-8-sig") as f:
            ldoc = json.load(f)
        T("MUST FIRE  ...and the ledger records it, naming both rows and the reason",
          len(ldoc["merges"]) == 1 and ldoc["merges"][0]["retired"]["calories"] == 63
          and ldoc["merges"][0]["reason"] == "orphan", json.dumps(ldoc)[:200])

        said = []
        fresh(); cite("Apples")
        rc = retire("Apples", "Apple", "orphan", db, led, [ref], out=said.append)
        T("MUST FIRE  a row something still CITES is refused and the DB is left alone - a name-keyed "
          "lookup that loses its row goes silently absent, it does not error",
          rc == EXIT_REFUSED and find_row(load(), "Apples") >= 0, "rc=%s" % rc)
        T("MUST FIRE  ...and the refusal NAMES the file that cites it, so the next step is obvious "
          "rather than a search", any("a.json" in s for s in said), " | ".join(said)[:200])

        said = []
        fresh(); cite("Apple")
        rc = retire("Apples", "Pear", "x", db, led, [ref], out=said.append)
        T("MUST FIRE  retiring in favour of a name the DB does not hold is refused - that is a "
          "deletion wearing a merge's clothes",
          rc == EXIT_REFUSED and find_row(load(), "Apples") >= 0)

        said = []
        rc = retire("Apples", "Apples", "x", db, led, [ref], out=said.append)
        T("MUST FIRE  retiring a row in favour of ITSELF is refused - and on the row NOTHING cites, "
          "so this is the equality check answering and not the citation sweep",
          rc == EXIT_REFUSED and find_row(load(), "Apples") >= 0)

        said = []
        rc = retire("Apples", "Apple", "x", db, led, [ref], dry_run=True, out=said.append)
        T("CLEAN TWIN --dry-run reports the retire it WOULD do and writes nothing",
          rc == EXIT_CLEAN and find_row(load(), "Apples") >= 0)

        # THE HOUSE FORMAT, byte for byte. This is the whole reason the tool moved off PowerShell:
        # ConvertTo-Json rewrote 435 rows at 4-space indent with every apostrophe escaped to \u0027,
        # a 47% larger file and a 6,288-line diff for a 3-row deletion.
        fresh(extra=[{"item": "Cafe\u0301 Cre\u0300me", "notes": "it's fine", "calories": 40}])
        cite("Apple")
        retire("Apples", "Apple", "x", db, led, [ref], out=lambda *_a: None)
        raw = open(db, "rb").read().decode("utf-8")
        T("MUST FIRE  the file is written in the house format - one-space indent, NO \\u escaping - "
          "so this tool and hunt-daemon's writer never reformat each other's work",
          '\n "items"' in raw and "\\u0027" not in raw and "it's fine" in raw, raw[:80])
        T("MUST FIRE  ...and a non-ASCII row NOT being retired survives verbatim",
          "Cafe\u0301 Cre\u0300me" in raw, raw[:200])
    finally:
        import shutil
        shutil.rmtree(tmp, ignore_errors=True)

    print("")
    if bad:
        print("retire-food-db-row SELF-TEST FAIL (%d)" % len(bad))
        print("RETIRE-FOOD-DB-ROW-COMPLETE")
        return EXIT_REFUSED
    print("retire-food-db-row SELF-TEST PASS")
    print("RETIRE-FOOD-DB-ROW-COMPLETE")
    return EXIT_CLEAN


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--retire", default="")
    ap.add_argument("--survivor", default="")
    ap.add_argument("--reason", default="")
    ap.add_argument("--db", default=FOOD_DB)
    ap.add_argument("--ledger", default=LEDGER)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    return retire(a.retire, a.survivor, a.reason, a.db, a.ledger, list(REF_ROOTS),
                  dry_run=a.dry_run)


if __name__ == "__main__":
    sys.exit(main())
