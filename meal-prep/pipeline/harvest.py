"""
harvest.py - the HARVEST plane (PLAN-recipe-hunter-v3 section 3 S1, deliverable D3).

WHAT THIS REPLACES. The hunt lane. On run wf_11382034-6fd the sourcers burned 325,543,422 tokens -
43.3% of the entire run - to re-discover, live and with a frontier model, a corpus that is largely
ENUMERABLE: the reliable publishers carry schema.org JSON-LD Recipe blocks (ingredients, instructions,
nutrition) reachable by sitemap and WordPress REST. The band filter is arithmetic on that JSON-LD.
None of that is judgment work. This module does it locally, for zero tokens, and leaves behind a
persistent, pre-qualified backlog so a "hunt" becomes a pop instead of a search.

THE POOL IS THE INSTITUTIONAL MEMORY THE 48% DUPE CHURN NEVER HAD. 44 of 91 recipes died as dupes on
2026-08-15 and left no trace outside the run dir. Every candidate this file has ever looked at - taken,
ruled, or out of band - stays in meal-prep\\db\\candidate-pool.json with the numbers behind its verdict.

THE THREE RULES THIS FILE IS BUILT ON (v3 section 1.4, non-negotiable):
  1. Local output is never trusted, always verified. Numbers here are EXTRACTED from the page's own
     machine statement, never inferred. A number we cannot defend is a FLAG, never a filter decision.
  2. Local may reject, filter, rank and flag. It may NEVER assert an identity. Nothing in this file
     rules that two dishes are the same - it ranks neighbours and hands the evidence to the decider.
  3. Everything user-visible, and every carriage/mapping/audit ruling, stays frontier.

SINGLE WRITER. This module is the ONLY writer of candidate-pool.json. Consumption and rulings come
back through --mark-taken / --mark-ruled, and top-up sourcer finds enter through --ingest, so a
crawled candidate and a searched one get the SAME band check, signature and dedup scoring. One road
into the pool; a candidate the decider rejected can never resurface as available.

ONE TAXONOMY, NOT THREE. The sauce-family vocabulary is PARSED OUT OF considered-dishes.ps1 at load
time rather than copied here, and the method enum is read from db\\considered-dishes.json's recorded
-Method values. A third hand-maintained copy of either is the pu-lib / category-exclude trap; a
method in the ledger this file has no detector for is REPORTED as a finding, never silently dropped.

POLITENESS IS CONTRACT, not etiquette. robots.txt is honoured, every domain is paced at one request
per 2-4 s regardless of worker count, a per-domain nightly cap bounds the ask, and every fetch outcome
lands in source-domains.ps1 (three failures = blocked, as that ledger already scores). A publisher
that walls the harvester is skipped and reported, never hammered - the same doctrine the stores get.

  python harvest.py --crawl [--limit N] [--per-domain N] [--domains a,b] [--dry-run]
  python harvest.py --classify [--limit N]          needs llama-server; REFUSES (exit 2) when it is down
  python harvest.py --ingest <candidates.json>
  python harvest.py --mark-taken <slug> --run <id>
  python harvest.py --mark-ruled <slug> --verdict <v> [--reason '...']
  python harvest.py --dossier [--count 10] [--run <id>] [--out <file>]
  python harvest.py --status [--json]
  python harvest.py --calibration [--json]          BLIND (exit 2) when the calibration is missing/stale
  python harvest.py --selftest

EXIT CODES (v3 section 4.5, and they differ from lib\\guard-contract.ps1's older vocabulary on purpose):
  0 = clean   1 = findings (the report is still written)   2 = could-not-run.
Exit 2 is a BLOCKED stage, never a pass - could-not-look is never a clean bill. Last line of stdout is
the completion marker HARVEST-COMPLETE, because "did it finish" and "what did it find" are different
questions and this estate has conflated them at least five times.

INTERPRETER: C:\\Codex\\Python312\\python.exe. Bare `python` is the Windows Store shim, which exits 49
without running. This module is stdlib-only on purpose - the embedding lane (harvest_embed.py, D4)
is where torch lives, and it runs under sidecar\\.venv.
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import html
import json
import os
import random
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import band_precheck
import urllib.request
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime

HERE = os.path.dirname(os.path.abspath(__file__))
MP = os.path.dirname(HERE)
REPO = os.path.dirname(MP)

POOL = os.path.join(MP, "db", "candidate-pool.json")
HARVEST_STATE = os.path.join(MP, "db", "harvest-state.json")
ROBOTS_DIR = os.path.join(MP, "db", "harvest-robots")
PAGE_CACHE = os.path.join(MP, "db", "page-cache")
NEIGHBOUR_FILE = os.path.join(MP, "db", "harvest-neighbours.json")

SOURCE_DOMAINS_PS = os.path.join(HERE, "source-domains.ps1")
FETCH_RECIPE_PS = os.path.join(HERE, "fetch-recipe.ps1")
CONSIDERED_PS = os.path.join(HERE, "considered-dishes.ps1")
FIND_SIMILAR_PS = os.path.join(HERE, "find-similar.ps1")
CONSIDERED_JSON = os.path.join(MP, "db", "considered-dishes.json")
SOURCE_DOMAINS_JSON = os.path.join(MP, "db", "source-domains.json")
SATURATION_JSON = os.path.join(MP, "db", "saturation.json")
CATALOG_DIGEST = os.path.join(HERE, "catalog-digest.json")
# Written by harvest_embed.py --calibrate, beside the digest it is a property of (D12 rung 2, S2a
# part b). Absent or stale is BLIND here - never a default number.
CALIBRATION_FILE = os.path.join(HERE, "catalog-similarity.json")

UA = "Mozilla/5.0 (compatible; ThriftyCrew recipe pipeline)"   # the same UA fetch-recipe.ps1 sends

# ---- thresholds. Defaults; a run that changes one records the reason in its run dir (section 4.5).
BAND_CAL_MIN = 400
BAND_CAL_MAX = 650
BAND_CARB_MAX = 35
# The plausibility window a stated per-serving calorie figure has to sit inside before the band filter
# is allowed to ACT on it. Outside it, the serving basis is ambiguous (some publishers put per-RECIPE
# nutrition where schema.org means per-serving) and the candidate demotes to band-unverified rather
# than being filtered in or out on a guess. This is the silent-wrongness trap section 3 S1 names.
PLAUSIBLE_CAL_MIN = 100
PLAUSIBLE_CAL_MAX = 2000

POLITE_MIN_SEC = 2.0     # one request per domain every 2-4 s, regardless of worker count
POLITE_MAX_SEC = 4.0
NIGHTLY_CAP = 60         # per-domain network fetches per calendar day
FETCH_WORKERS = 8        # section 4.3: 8 workers, bounded by network + per-domain politeness

DOSSIER_INGREDIENT_CAP = 22   # keeps a dossier at the 2-3 KB section S2 budgets
DOSSIER_NEIGHBOUR_CAP = 5

STARCHES = ("rice", "noodle", "pasta", "potato", "tortilla", "bread", "bean", "quinoa", "couscous",
            "polenta")
# Exclusions the run's conditions already carry (SKILL.md: no seafood; ground chicken is a standing
# board exclusion). Matched on ingredient nouns, not on the title, because a title lies more often.
SEAFOOD = ("shrimp", "prawn", "salmon", "tuna", "cod fillet", "tilapia", "halibut", "crab", "lobster",
           "scallop", "clam", "mussel", "oyster", "anchovy", "sardine", "fish sauce", "fish fillet",
           "catfish", "trout", "swordfish", "mahi", "squid", "calamari", "octopus")
GROUND_CHICKEN = ("ground chicken",)

# RIB CUTS - a STANDING EXCLUSION (Brad's ruling 2026-08-24, after the 6b proving run).
#
# WHY. Rib racks are calorie-dense against their edible protein, so the protein-per-serving a
# high-protein band asks for cannot be reached inside the same band's calorie ceiling. 6b paid for
# `beef-back-ribs` through map, registrar AND pricing before the pre-write band gate retired it at
# 41.6 g protein against a 50 g floor - and the run's own reading of that closure turned on our
# food-DB row's `needs_verify: true` 0.45 edible-yield estimate, which is exactly the argument nobody
# should have to relitigate per recipe. Brad's ruling settles the class instead: rib recipes do not
# enter. Excluding at INGEST is the cheap place - it costs one substring pass and saves an entire
# paid pipeline per candidate.
#
# WHAT IS IN, AND WHAT IS DELIBERATELY NOT. These are the RACK cuts, matched as PHRASES so the filter
# cannot act on a guess (the standing rule the seafood list above already follows). `ribeye`,
# `rib eye` and `prime rib` are NOT excluded: they are different cuts with different fat and yield,
# and a bare "rib" substring would take them along with the racks - which is the class of silent
# over-rejection this file's own comments warn about. If Brad wants those out too, they are one
# phrase each.
# GENERIC `ribs` IS THE CLASS, and leaving it out let one through. Measured 2026-08-26: this list is
# phrase-specific, so "Fall-Apart Oven Baked Ribs with Chipotle BBQ Sauce" and "Oven Pork Ribs with
# Barbecue Sauce" matched NOTHING and the first was accepted into hunt-2026-08-26-smoke2 at 723 cal -
# through a band whose ceiling had just been raised to 750, which is exactly the calorie-density Brad's
# ruling names. The plural is the safe form: `ribs` cannot appear inside `ribeye`, `rib eye` or
# `prime rib`, so the deliberate exemption for those cuts survives untouched. The specific phrases stay
# because they catch the SINGULAR forms (`rib tips`, `baby back`, `riblet`) that a bare plural misses.
RIB_CUTS = ("ribs", "back ribs", "baby back", "spare ribs", "spareribs", "short ribs", "shortribs",
            "riblet", "rib tips", "country style ribs", "country-style ribs", "rack of ribs")

# ---------------------------------------------------------------------------------------------------
# Protein detection. WEIGHTED, not first-substring-wins, because first-substring-wins was measured
# wrong on 2026-08-23 over the first real 20-candidate dossier: "Chicken Madeira" read as BEEF (its
# beef broth) and "Jalapeno Popper Chicken" read as PORK (its bacon). A wrong protein does not just
# mis-rank a neighbour search - it lands in `record.protein` and becomes what considered-dishes
# remembers about the dish forever.
#
# Three rules, in order:
#   1. A protein noun inside a BROTH/STOCK phrase is not the dinner. Those phrases are removed first.
#   2. A named CUT is strong evidence; a bare noun is weak; bacon and ham are weak (garnish more
#      often than dinner). Strong evidence beats any amount of weak evidence.
#   3. "<x> sausage" is sausage, and the phrase is consumed so it cannot also score for <x>.
# ---------------------------------------------------------------------------------------------------
BROTH_CTX = re.compile(r"\b(chicken|beef|pork|turkey|vegetable)\s+"
                       r"(broth|stock|bouillon|base|consomm\w*|gravy|granules|drippings)\b")
SAUSAGE_PHRASES = re.compile(
    r"\b(?:(?:chicken|turkey|pork|beef|italian|smoked|breakfast|hot|sweet|spicy|polish|andouille)\s+)?"
    r"sausages?\b|\b(?:chorizo|kielbasa|andouille|bratwurst|linguica)\b")

STRONG_CUTS = {
    "chicken": ("chicken breast", "chicken thigh", "chicken tender", "chicken drumstick",
                "chicken wing", "whole chicken", "rotisserie chicken", "chicken cutlet",
                "chicken quarter"),
    "beef": ("ground beef", "chuck roast", "chuck steak", "ground chuck", "sirloin", "flank steak",
             "skirt steak", "short rib", "stew meat", "brisket", "ribeye", "rib eye", "beef roast",
             "beef chuck", "flat iron", "top round", "steak"),
    "pork": ("pork shoulder", "pork loin", "pork chop", "pork tenderloin", "ground pork",
             "pork butt", "pork rib", "country style rib", "pork steak", "pork cutlet"),
    "turkey": ("ground turkey", "turkey breast", "turkey thigh", "turkey cutlet"),
}
WEAK_NOUNS = {
    "chicken": ("chicken",),
    "beef": ("beef",),
    "pork": ("pork", "bacon", "ham ", "pancetta", "prosciutto"),
    "turkey": ("turkey",),
}
# Tie-break when two proteins carry the same weight: the more specific claim wins.
PROTEIN_ORDER = ("sausage", "turkey", "pork", "beef", "chicken")

# What counts as a protein NAMED IN THE TITLE. Deliberately narrower than WEAK_NOUNS: bacon and ham
# in a title ("Bacon Ranch Chicken") describe a topping, not the dinner, and letting them win the
# title rule would put every bacon-topped chicken dish in the pork bucket.
TITLE_NOUNS = {
    "chicken": ("chicken",), "beef": ("beef", "steak"), "pork": ("pork",), "turkey": ("turkey",),
    "sausage": ("sausage", "chorizo", "kielbasa", "andouille", "bratwurst"),
}

# Detectors for the methods the LEDGER records. The enum itself is read from db\considered-dishes.json;
# this map only says how each recorded method is spotted, as word-boundary regexes. A ledger method
# with no entry here is a FINDING (exit 1), never a silent drop - that is how a taxonomy quietly forks.
#
# CORRECTED 2026-08-23 against the first real dossier batch: `chili` matched "chili powder" and made a
# breakfast taco a STEW, and `simmer for` made every cream-sauce skillet a stew. A method word has to
# be a claim about the DISH, not an ingredient noun that happens to contain one.
METHOD_WORDS = {
    "skillet": (r"\bskillet\b", r"\bsaut[eé]", r"\bpan[- ]fry", r"\bstir[- ]fry",
                r"\bwok\b", r"\bfrying pan\b", r"\bsear\b"),
    "bake": (r"\bbaked?\b", r"\bbaking\b", r"\boven\b", r"\broast(ed)?\b", r"\bsheet[- ]pan\b"),
    "casserole": (r"\bcasserole\b", r"\b9\s*x\s*13\b", r"\bbaking dish\b", r"\bgratin\b"),
    "braised": (r"\bbrais(e|ed|ing)\b", r"\bdutch oven\b", r"\bslow cooker\b", r"\bcrock ?pot\b",
                r"\bpressure cooker\b", r"\binstant pot\b"),
    "stew": (r"\bstew(ed)?\b", r"\bsoup pot\b",
             r"\bchili\b(?!\s*(?:powder|flakes|paste|oil|garlic|sauce|crisp|seasoning|pepper))"),
}
# Tie-break order: the more specific claim wins over the generic pan/oven words, so a page that says
# both "casserole" and "oven" reads as a casserole rather than a bake.
METHOD_PRECEDENCE = ("casserole", "stew", "braised", "skillet", "bake")

POOL_DOC = ("Every candidate the harvester has ever looked at, with the numbers behind its verdict. "
            "harvest.py is the SOLE writer; --mark-taken / --mark-ruled / --ingest are the only roads "
            "in. A ruled candidate never resurfaces as available.")

_print_lock = threading.Lock()


def say(msg):
    with _print_lock:
        print(msg, flush=True)


def now_stamp():
    return datetime.now().strftime("%Y-%m-%dT%H:%M:%S")


# =====================================================================================================
# vocabulary - read, never re-typed
# =====================================================================================================

_FAMILY_BLOCK = re.compile(r"\$script:FAMILIES\s*=\s*\[ordered\]@\{(.*?)^\}", re.S | re.M)
_FAMILY_ROW = re.compile(r"^\s*'([a-z]+)'\s*=\s*@\((.*?)\)\s*$", re.M)


def load_families(ps_path=CONSIDERED_PS):
    """The sauce-family vocabulary, PARSED OUT of considered-dishes.ps1.

    considered-dishes.ps1 and make-saturation.ps1 already carry this list twice, with a fixture in
    make-saturation asserting they agree. A third copy typed here in Python is exactly the trap this
    estate has paid for three times (pu-lib had three copies; the category-exclude bake drifted 2,165
    patterns). So it is read from the source of record. If the block cannot be parsed that is
    could-not-run, not a default - a silently empty vocabulary would classify every dish as unknown.
    """
    with open(ps_path, "r", encoding="utf-8-sig") as f:
        src = f.read()
    m = _FAMILY_BLOCK.search(src)
    if not m:
        raise RuntimeError("could not find $script:FAMILIES in %s - the taxonomy moved; harvest.py "
                           "must be re-pointed rather than given its own copy" % ps_path)
    out = {}
    for row in _FAMILY_ROW.finditer(m.group(1)):
        fam = row.group(1)
        needles = tuple(x.strip().strip("'") for x in row.group(2).split(",") if x.strip())
        if needles:
            out[fam] = needles
    if not out:
        raise RuntimeError("the $script:FAMILIES block in %s parsed to nothing" % ps_path)
    return out


def family_of(text, families=None):
    """Get-Family's answer, or None where Get-Family would say 'plain'.

    'plain' in the PS ledger means "no family keyword matched", which is precisely the case section 3
    S1 hands to the local classifier. --crawl therefore leaves it null and --classify fills it; a null
    sauce_family only WIDENS the neighbour search and never blocks a candidate.
    """
    if families is None:
        families = load_families()
    if not text:
        return None
    t = text.lower()
    for fam, needles in families.items():
        for n in needles:
            if n in t:
                return fam
    return None


def load_methods(ledger_path=CONSIDERED_JSON):
    """The method enum, read from the rulings ledger's own -Method values.

    Returns (methods, unmapped). `unmapped` is every recorded method this file has no detector for -
    a finding for the caller, because a taxonomy that grows in the ledger and not here forks silently.
    'any' is the ledger's WILDCARD, not a method, and is excluded.
    """
    try:
        with open(ledger_path, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
    except Exception:
        return [], []
    seen = []
    for row in (d.get("dishes") or []):
        m = (row.get("method") or "").strip().lower()
        if m and m != "any" and m not in seen:
            seen.append(m)
    unmapped = [m for m in seen if m not in METHOD_WORDS]
    return sorted(seen), sorted(unmapped)


# =====================================================================================================
# the page cache - shared with fetch-recipe.ps1, by the same key
# =====================================================================================================

def cache_key(url):
    """fetch-recipe.ps1's Get-UrlKey, byte-for-byte: sha256 of the fragment-stripped lowercased URL,
    first 32 hex characters. A fixture asserts this against the PS implementation, because two cache
    key functions that drift means two caches, two fetches, and a politeness budget spent twice."""
    norm = re.sub(r"#.*$", "", url).strip().lower()
    return hashlib.sha256(norm.encode("utf-8")).hexdigest()[:32]


def cached_body(url, cache_dir=PAGE_CACHE):
    p = os.path.join(cache_dir, cache_key(url) + ".html")
    if not os.path.exists(p):
        return None
    try:
        with open(p, "r", encoding="utf-8-sig", errors="replace") as f:
            return f.read()
    except Exception:
        return None


def run_ps(script, args, timeout=180):
    """A PowerShell surface, called the way the daemon will call it. Returns (rc, stdout).

    ONE marshalling road, hunt_lib.ps_invoke's - see its header. `powershell -File` cannot bind a
    multi-element [string[]] from argv at all, so a second invocation style here would be a second
    chance to re-create B8.
    """
    import hunt_lib
    rc, out, _err = hunt_lib.ps_invoke(script, args, timeout=timeout)
    return rc, out


def fetch_through_cache(url, cache_dir=PAGE_CACHE, record=True):
    """The page body, and whether the network was touched.

    Contract (section 3 S1 item 2): every page fetch goes THROUGH fetch-recipe.ps1, which owns the
    cache and records the domain outcome in source-domains.ps1. A cache HIT is read straight off disk
    by the same key - there is nothing for PowerShell to do on a hit, and paying a process spawn per
    already-cached page would make the backlog's whole point (the extractor and QA never re-fetch)
    cost more than it saves. A MISS is handed to fetch-recipe.ps1, which fetches, caches and records.
    """
    body = cached_body(url, cache_dir)
    if body is not None:
        return body, False
    args = ["-Url", url]
    if not record:
        # A PROBE MAY NOT PROMOTE A PUBLISHER. Recording a sample fetch marks the domain `reliable`,
        # and `reliable` is exactly what the crawl enumerates - so probing a useless site admitted it.
        args.append("-NoRecord")
    rc, _out = run_ps(FETCH_RECIPE_PS, args, timeout=120)
    if rc != 0:
        return None, True
    return cached_body(url, cache_dir), True


# =====================================================================================================
# JSON-LD, parsed DEFENSIVELY (section 3 S1 item 3 - the silent-wrongness trap)
# =====================================================================================================

_LD_BLOCK = re.compile(r"<script[^>]*type\s*=\s*[\"']application/ld\+json[\"'][^>]*>(.*?)</script>",
                       re.S | re.I)


def jsonld_blocks(html):
    if not html:
        return []
    return [m.group(1) for m in _LD_BLOCK.finditer(html)]


def find_recipe_node(node, depth=0):
    """Recipe sits at the root, inside @graph, or inside an array - all three occur in the wild, so
    all three are searched. The same shapes fetch-recipe.ps1's Find-RecipeNode covers."""
    if depth > 6 or node is None:
        return None
    if isinstance(node, list):
        for n in node:
            r = find_recipe_node(n, depth + 1)
            if r is not None:
                return r
        return None
    if isinstance(node, dict):
        t = node.get("@type")
        types = t if isinstance(t, list) else [t]
        if any(str(x) == "Recipe" for x in types if x is not None):
            return node
        if "@graph" in node:
            r = find_recipe_node(node["@graph"], depth + 1)
            if r is not None:
                return r
    return None


def recipe_jsonld(html):
    for b in jsonld_blocks(html):
        try:
            node = find_recipe_node(json.loads(b))
        except Exception:
            node = None
        if node is not None:
            return node
    return None


_NUM = re.compile(r"(\d+(?:[.,]\d+)?)")


def extract_number(v):
    """A number the page STATES, or None. Never an inference.

    Nutrition arrives as strings with units ("418 kcal", "20 g", "1,024 calories"). A value with no
    digits is None and stays None: the band filter may only ever act on numbers it can defend, and
    "about four hundred" is a flag for the decider, not a 400. More than one number in the string is
    also None - "400-500" is a range, and picking an end of it is a guess.
    """
    if v is None or isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    if isinstance(v, list):
        vals = [extract_number(x) for x in v]
        vals = [x for x in vals if x is not None]
        return vals[0] if len(vals) == 1 else None
    hits = _NUM.findall(str(v))
    if len(hits) != 1:
        return None
    try:
        return float(hits[0].replace(",", ""))
    except ValueError:
        return None


def parse_yield(v):
    """recipeYield to ONE integer, or None.

    Arrives as "8", ["8", "8 servings"], "6-8", "makes 8 patties". A yield that does not parse to one
    integer demotes the candidate; it never guesses the low end of a range, because the servings count
    is the denominator of every per-serving number downstream.
    """
    if v is None or isinstance(v, bool):
        return None
    if isinstance(v, list):
        ints = []
        for item in v:
            n = parse_yield(item)
            if n is not None and n not in ints:
                ints.append(n)
        return ints[0] if len(ints) == 1 else None
    if isinstance(v, (int, float)):
        n = int(v)
        return n if 0 < n <= 200 else None
    hits = re.findall(r"\d+", str(v))
    if len(hits) != 1:
        return None
    n = int(hits[0])
    return n if 0 < n <= 200 else None


def flatten_instructions(v, depth=0):
    """recipeInstructions arrives as plain strings OR HowToStep / HowToSection objects; the contract
    (section 4.5) is that both flatten into the ordered string list. Used here only to spot the method
    words - the extraction ladder (D6) owns the real transcription."""
    out = []
    if v is None or depth > 4:
        return out
    if isinstance(v, str):
        s = html.unescape(re.sub(r"<[^>]+>", " ", v)).strip()
        if s:
            out.append(s)
        return out
    if isinstance(v, list):
        for item in v:
            out.extend(flatten_instructions(item, depth + 1))
        return out
    if isinstance(v, dict):
        if v.get("@type") == "HowToSection" or "itemListElement" in v:
            out.extend(flatten_instructions(v.get("itemListElement"), depth + 1))
            return out
        txt = v.get("text") or v.get("name")
        if txt:
            out.extend(flatten_instructions(txt, depth + 1))
        return out
    return out


def read_band(node):
    """The band block, and why it is or is not defensible.

    Returns {cal, carbs, protein_g, verified, reason}. `verified` is True ONLY when every number the
    band test needs was extracted from the page AND the serving basis is plausible. Everything else is
    band-unverified: KEPT and flagged for the decider, exactly as the current sourcer prompt allows,
    never filtered in or out on a guess.
    """
    nut = node.get("nutrition") if isinstance(node, dict) else None
    if not isinstance(nut, dict):
        return {"cal": None, "carbs": None, "protein_g": None, "verified": False,
                "reason": "no JSON-LD nutrition block"}
    cal = extract_number(nut.get("calories"))
    carbs = extract_number(nut.get("carbohydrateContent"))
    prot = extract_number(nut.get("proteinContent"))
    servings = parse_yield(node.get("recipeYield"))
    if cal is None:
        return {"cal": None, "carbs": carbs, "protein_g": prot, "verified": False,
                "reason": "calories not stated as a single number"}
    if carbs is None:
        return {"cal": cal, "carbs": None, "protein_g": prot, "verified": False,
                "reason": "carbohydrateContent not stated as a single number"}
    if servings is None:
        return {"cal": cal, "carbs": carbs, "protein_g": prot, "verified": False,
                "reason": "recipeYield does not parse to one integer - the serving basis is ambiguous"}
    if not (PLAUSIBLE_CAL_MIN <= cal <= PLAUSIBLE_CAL_MAX):
        return {"cal": cal, "carbs": carbs, "protein_g": prot, "verified": False,
                "reason": "%g cal is implausible for one serving - the block may be per-RECIPE" % cal}
    return {"cal": cal, "carbs": carbs, "protein_g": prot, "verified": True, "reason": ""}


def in_band(band, cal_min=BAND_CAL_MIN, cal_max=BAND_CAL_MAX, carb_max=BAND_CARB_MAX):
    """Inclusive on both edges, exactly as the run's conditions state them (section 4.5).
    Returns True / False / None, where None means "not defensible" and is never a rejection."""
    if not band.get("verified"):
        return None
    return (cal_min <= band["cal"] <= cal_max) and (band["carbs"] <= carb_max)


# =====================================================================================================
# signature (protein x method x sauce-family x starch)
# =====================================================================================================

def ingredient_lines(node):
    v = node.get("recipeIngredient") if isinstance(node, dict) else None
    if isinstance(v, str):
        v = [v]
    out = []
    for x in (v or []):
        s = re.sub(r"<[^>]+>", " ", str(x))
        # HTML ENTITIES ARE UNESCAPED (2026-08-23, D6 measurement). JSON-LD is embedded in HTML and
        # publishers escape their own lines: "softened &amp; cut into cubes", "1/2&nbsp;cup". The
        # extraction contract says `raw` is the line EXACTLY AS PRINTED, and "&amp;" is not what is
        # printed - "&" is. It cost a real page an escalation: the split was perfect and the
        # round-trip check demanded the token "amp", which exists in no recipe. Unescaping here fixes
        # the line for every reader of this parser at once, which is why it is here and not in D6.
        s = html.unescape(s)
        s = re.sub(r"\s+", " ", s).strip()
        if s:
            out.append(s)
    return out


def detect_protein(lines, title=""):
    """The dinner's protein, from the ingredients, with the title allowed to break the tie.

    RULE 4, added 2026-08-23 after "Chicken and Stuffing Casserole" read as SAUSAGE on the strength of
    the sausage in its stuffing: a protein NAMED IN THE TITLE is the publisher saying what the dinner
    is, and it wins - but ONLY IF THE INGREDIENTS CORROBORATE IT. That proviso is the whole safety of
    the rule: "Chicken Fried Steak" names chicken in its title and has no chicken in it, so it falls
    back to the ingredients and reads beef, which is right.
    """
    blob = " ; ".join(lines).lower()
    blob = BROTH_CTX.sub(" ", blob)                       # rule 1: broth is not the dinner
    sausage_hits = len(SAUSAGE_PHRASES.findall(blob))
    blob = SAUSAGE_PHRASES.sub(" ", blob)                 # rule 3: consume it so it scores once
    strong = {p: sum(blob.count(c) for c in cuts) for p, cuts in STRONG_CUTS.items()}
    if sausage_hits:
        strong["sausage"] = sausage_hits
    weak = {p: sum(blob.count(n) for n in nouns) for p, nouns in WEAK_NOUNS.items()}
    weak["sausage"] = sausage_hits

    t = (title or "").lower()
    for p in PROTEIN_ORDER:
        if any(n in t for n in TITLE_NOUNS.get(p, ())) and (strong.get(p, 0) or weak.get(p, 0)):
            return p

    top = max(strong.values()) if strong else 0
    if top > 0:
        for p in PROTEIN_ORDER:
            if strong.get(p, 0) == top:
                return p
    top = max(weak.values()) if weak else 0
    if top > 0:
        for p in PROTEIN_ORDER:
            if weak.get(p, 0) == top:
                return p
    return "any"


def detect_method(title, instructions, methods=None):
    """Mechanically, from the title and the page's own instructions, against the LEDGER's enum.

    THE TITLE DECIDES WHEN IT SPEAKS. A recipe's instructions name several vessels and only one of
    them is the claim; the title is what the publisher says the dish IS. So if any method word appears
    in the title, only title-matching methods compete and the body is not consulted at all - otherwise
    "Baked Gnocchi Casserole" loses `casserole` to `bake` on the strength of the word "baking dish"
    appearing twice in its own instructions, which is exactly backwards. Measured 2026-08-23 over 652
    re-derived signatures. Ties fall to METHOD_PRECEDENCE, most specific first.
    """
    if methods is None:
        methods, _ = load_methods()
    t = (title or "").lower()
    body = " ".join(instructions or []).lower()

    def hits(text):
        out = {}
        for m in methods:
            pats = METHOD_WORDS.get(m, ())
            if not pats:
                continue    # a ledger method with no detector cannot be spotted; load_methods reports it
            n = sum(1 for pat in pats if re.search(pat, text))
            if n:
                out[m] = n
        return out

    score = hits(t) or hits(body)
    if not score:
        return "any"
    top = max(score.values())
    for m in METHOD_PRECEDENCE:
        if score.get(m) == top:
            return m
    return sorted(k for k, v in score.items() if v == top)[0]


# Binders and coatings are not the starch on the plate. Measured 2026-08-23: the breadcrumbs in
# Swedish meatballs read as a `bread` starch, which is the quiet kind of wrongness that widens a
# neighbour search toward every sandwich in the catalog.
NOT_STARCH = re.compile(r"\b(bread ?crumbs?|panko|breading|bread flour)\b")


# ---- THE ROUND'S ALLOWED CUTS (Brad's ruling 2026-08-27) ---------------------------------------------
# "They need to use either boneless chicken breast, ground beef, pork loin or ground turkey as the
# 'main' protein. No steak cuts or any other cuts of meat for this round."
#
# WHY THIS IS A CUT FILTER AND NOT A FAMILY FILTER. detect_protein() answers "chicken" or "beef" -
# the FAMILY - which cannot tell a chicken breast from a chicken thigh, or ground beef from a ribeye.
# The signature has always carried the family, so a family filter would admit exactly the cuts this
# ruling excludes. STRONG_CUTS already holds the cut vocabulary; this reads it at cut level.
#
# AND WHY IT IS SAFE TO HARD-FILTER HERE while the BAND is only tagged (see qualify): a cut is a fact
# about the ingredient list, which we read ourselves. The band is the publisher's own nutrition claim,
# measured wrong by -25% to +43% on the recipes this estate has actually computed, and Brad's
# 2026-08-24 ruling removed the ingest band precisely so an unreliable number could not bury a
# candidate permanently. A cut we misread is a bug; a band we believe is a lie we inherited.
ROUND_CUTS = {
    "chicken breast": ("boneless skinless chicken breast", "boneless chicken breast",
                       "skinless chicken breast", "chicken breast"),
    "ground beef":    ("lean ground beef", "ground beef", "ground chuck"),
    "pork loin":      ("boneless pork loin", "pork loin", "pork tenderloin", "boneless pork chop"),
    "ground turkey":  ("lean ground turkey", "ground turkey"),
}
# Cuts that DISQUALIFY even when an allowed cut is also present: a recipe built on steak plus a little
# chicken breast is a steak dinner. Ordered so the disqualifier is checked before the allow.
ROUND_EXCLUDED_CUTS = ("chicken thigh", "chicken drumstick", "chicken wing", "chicken quarter",
                       "whole chicken", "rotisserie chicken", "bone-in", "bone in",
                       "steak", "chuck roast", "short rib", "brisket", "ribeye", "rib eye",
                       "stew meat", "beef roast", "flat iron", "top round",
                       "pork shoulder", "pork butt", "pork rib", "country style rib",
                       "ground pork", "turkey thigh", "sausage", "bacon-wrapped")


def detect_round_cut(lines, title=""):
    """Which of the round's four allowed cuts is this dinner's MAIN protein, or None.

    Returns None when the recipe carries a disqualifying cut, when it carries none of the four, or
    when it carries more than one of the four (an ambiguous main protein is not a main protein).
    """
    blob = " ; ".join(list(lines) + [title or ""]).lower()
    for bad in ROUND_EXCLUDED_CUTS:
        if bad in blob:
            return None
    found = []
    for cut, needles in ROUND_CUTS.items():
        if any(n in blob for n in needles):
            found.append(cut)
    if len(found) != 1:
        return None
    return found[0]


def detect_starch(lines):
    blob = NOT_STARCH.sub(" ", " ; ".join(lines).lower())
    for st in STARCHES:
        if st in blob:
            return st
    return "none"


def exclusions(lines, name=""):
    """The run conditions' standing exclusions, matched on ingredient nouns. Returns a list of reasons.

    `name` IS LOAD-BEARING FOR THE RIB CUTS, and the reason is measured (2026-08-24). The pool does not
    always hold ingredient lines: 254 of 661 available candidates carry none, and `beef-back-ribs` - the
    very recipe whose retirement prompted this exclusion - is one of them, so an ingredient-only filter
    could not fire on it at all. A rib recipe names itself in its title essentially always, so the rib
    check reads BOTH. Seafood deliberately still reads ingredients only: its whole point is catching a
    dinner whose title does not advertise the fish, and a title-side seafood match would take
    "Chicken Puttanesca" with it.
    """
    out = []
    blob = " ; ".join(lines).lower()
    rib_blob = (blob + " ; " + str(name or "")).lower()
    for w in SEAFOOD:
        if w in blob:
            # Worcestershire lists anchovy in its own ingredients; it is a condiment, not a seafood
            # dinner, and rejecting every pot roast that uses it would be a filter acting on a guess.
            if w == "anchovy" and "worcestershire" in blob:
                continue
            out.append("seafood: " + w)
            break
    for w in GROUND_CHICKEN:
        if w in blob:
            out.append("board exclusion: " + w)
    for w in RIB_CUTS:
        if w in rib_blob:
            out.append("rib cut: " + w)
            break
    return out


# ---------------------------------------------------------------------------------------------------
# BATCH-SCALABILITY CONCERNS (section 3 S1 item 3, "method words vs batch-scalability rules").
#
# A FLAG, NOT A FILTER, and that is a deliberate reading. The band filter rejects on arithmetic it can
# defend; "is this a 14-serving batch dinner" is a judgment, and a mechanical reject would quietly
# lose real dinners - a taco SALAD skillet and a frittata are both perfectly good batch prep, and both
# trip the obvious keyword rules. So the concern is recorded, it demotes the candidate in the pop
# order so genuine dinners surface first, and the DECIDER rules. Local may reject, filter, rank and
# flag; ruling that a dish is not the kind of dinner this board sells is not arithmetic.
#
# BUILT 2026-08-23 after the phase-1 gate's first 20-candidate pop came back dominated by cold salads,
# wraps and a breakfast taco - all correctly rejected by both the decider and the hand check, and all
# of them work the paid lane had to do because nothing upstream had ranked a dinner above a salad.
BATCH_CONCERNS = (
    ("cold-plate", (r"\bsalads?\b", r"\bwraps?\b", r"\bsandwich(es)?\b", r"\bsubs?\b", r"\btoast\b",
                    r"\bsmoothies?\b", r"\bdips?\b", r"\bslaw\b")),
    ("breakfast", (r"\bbreakfast\b", r"\bpancakes?\b", r"\bwaffles?\b", r"\boatmeal\b",
                   r"\bmuffins?\b", r"\bgranola\b", r"\bsmoothie bowl\b", r"\bcinnamon rolls?\b")),
    ("cook-to-order", (r"\bdeep[- ]fry(ing)?\b", r"\bdeep[- ]fried\b", r"\btempura\b",
                       r"\bto order\b", r"\bfondue\b")),
    ("not-a-main", (r"\bcookies?\b", r"\bbrownies?\b", r"\bcupcakes?\b", r"\bice cream\b",
                    r"\bpudding\b", r"\bcocktail\b", r"\bmargarita\b", r"\bappetizers?\b")),
)


def batch_concerns(name, instructions=None):
    """What about this dish might not survive a 14-serving batch. Each entry is a flag for the decider."""
    blob = ((name or "") + " || " + " ".join(instructions or [])).lower()
    out = []
    for label, pats in BATCH_CONCERNS:
        if any(re.search(pat, blob) for pat in pats):
            out.append(label)
    return out


def slugify(name):
    s = re.sub(r"[^a-z0-9]+", "-", (name or "").lower()).strip("-")
    return s[:80] or "unnamed"


def domain_of(url):
    d = urllib.parse.urlparse(url).netloc.lower()
    return re.sub(r"^www\.", "", d)


# =====================================================================================================
# the pool - single writer, atomic
# =====================================================================================================

def read_pool(path=POOL):
    if not os.path.exists(path):
        return {"_doc": POOL_DOC, "updated": None, "count": 0, "candidates": []}
    with open(path, "r", encoding="utf-8-sig") as f:
        d = json.load(f)
    if "candidates" not in d:
        d["candidates"] = []
    return d


def write_pool(pool, path=POOL):
    pool["_doc"] = POOL_DOC
    pool["updated"] = now_stamp()
    pool["count"] = len(pool["candidates"])
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(pool, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


def pool_index(pool):
    by_slug, by_url = {}, {}
    for c in pool["candidates"]:
        by_slug[c["slug"]] = c
        by_url[norm_url(c.get("url") or "")] = c
    return by_slug, by_url


def norm_url(u):
    return re.sub(r"#.*$", "", (u or "")).strip().lower().rstrip("/")


RECIPES_DB = os.path.join(MP, "recipes-db.json")


def published_slugs(digest_path=CATALOG_DIGEST, db_path=RECIPES_DB):
    """Every slug the catalog already carries, from the recipes db UNION the digest.

    The "read the digest, not the 3.9 MB db" rule is about an AGENT'S CONTEXT - a selector cannot hold
    1500 recipes and still think. A local script has no such problem, and the digest is only as fresh
    as the last make-catalog-digest run: on 2026-08-23 it held 540 recipes while the db held more, so
    a digest-only guard would have let an already-published dish back into the pool. The db is the
    authority here and the digest is the belt; the union is what "already published" means.
    """
    slugs, names = set(), {}
    try:
        with open(digest_path, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
        for _p, rows in (d.get("by_protein") or {}).items():
            for r in rows:
                slugs.add(r.get("slug"))
                names[r.get("slug")] = r.get("name")
    except Exception:
        pass
    try:
        with open(db_path, "r", encoding="utf-8-sig") as f:
            db = json.load(f)
        rows = db.get("recipes") if isinstance(db, dict) else db
        for r in (rows or []):
            sl = r.get("slug") or r.get("id")
            if sl:
                slugs.add(sl)
                names.setdefault(sl, r.get("name") or r.get("title"))
    except Exception:
        pass
    return slugs, names


def refuse_entry(slug, url, pub_slugs, by_slug, by_url):
    """Why this candidate may NOT enter the pool, or None.

    ONE predicate, used by --crawl and --ingest alike, so a searched candidate cannot slip past a
    guard a crawled one has to clear. An exact already-published slug never enters: the catalog
    already carries that dinner, and re-offering it to a decider is the churn this plane exists to end.
    """
    if slug in pub_slugs:
        return "already published"
    if slug in by_slug:
        return "already in the pool"
    if norm_url(url) in by_url:
        return "this URL is already in the pool under another name"
    return None


def new_entry(slug, name, url, domain, entered_by):
    return {
        "slug": slug, "name": name, "url": url, "domain": domain,
        "first_seen": now_stamp(), "last_verified": now_stamp(),
        "signature": {"protein": None, "method": None, "sauce_family": None, "starch": None},
        "band": {"cal": None, "carbs": None, "protein_g": None, "verified": False, "reason": ""},
        "servings": None, "ingredients_verbatim": [], "neighbours": [], "prior_rulings": [],
        "saturation_pressure": 0, "status": "available", "entered_by": entered_by,
    }


# Fields a RULED entry still has a use for. Everything else is dropped when a candidate is ruled.
#
# WHY THIS EXISTS AND IS NOT PREMATURE. The pool is permanent memory, and permanent memory grows: at
# the standing nightly cap (60 x 7 publishers) about 250 candidates a night are ruled out on arrival,
# and a full entry is ~600 bytes, which is ~55 MB of git churn a year for rows nothing will ever read
# again. A ruled entry has exactly one job - answer "have we seen this URL, and what did we decide" -
# so it keeps its identity, its provenance and THE NUMBERS THAT RULED IT, and loses the scoring
# apparatus that only an available candidate uses. Measured 2026-08-23: 607 B -> ~300 B per row.
RULED_KEEP = ("slug", "name", "url", "domain", "first_seen", "band", "servings", "signature",
              "status", "entered_by", "exclusion", "ruled_reason", "ruled_at")


def slim_ruled(entry):
    """Drop what a ruled entry cannot use. Never drops a number that justified the ruling."""
    if not str(entry.get("status", "")).startswith("ruled:"):
        return entry
    return {k: v for k, v in entry.items() if k in RULED_KEEP}


def qualify(entry, node, families, methods, cal_min=BAND_CAL_MIN, cal_max=BAND_CAL_MAX,
            carb_max=BAND_CARB_MAX, band_at_ingest=False):
    """The band + structure + signature pass. ONE code path, so an --ingest candidate from a top-up
    sourcer is treated exactly like a crawled one (section 3 S1 item 5: one road into the pool).

    Returns (entry, disposition) where disposition is one of in-band / band-unverified / out-of-band /
    excluded. Only `out-of-band` and `excluded` are rulings; the other two stay available.
    """
    if node is None:
        entry["band"] = {"cal": None, "carbs": None, "protein_g": None, "verified": False,
                         "reason": "no JSON-LD Recipe block on the page"}
        entry["signature"] = {"protein": "any", "method": "any", "sauce_family": None,
                              "starch": "none"}
        entry["status"] = "available"
        return entry, "band-unverified"

    lines = ingredient_lines(node)
    instr = flatten_instructions(node.get("recipeInstructions"))
    entry["ingredients_verbatim"] = lines
    entry["servings"] = parse_yield(node.get("recipeYield"))
    if node.get("name"):
        entry["name"] = str(node["name"]).strip() or entry.get("name")
    entry["band"] = read_band(node)
    entry["last_verified"] = now_stamp()

    excl = exclusions(lines, entry.get("name") or "")
    if excl:
        entry["status"] = "ruled:excluded"
        entry["exclusion"] = "; ".join(excl)
        return slim_ruled(entry), "excluded"

    # ---- THE ROUND'S CUT AND COMPOSITION FILTERS (Brad's ruling 2026-08-27) ---------------------
    # Two conditions that are FACTS ABOUT THE INGREDIENT LIST, which we read ourselves, so they are
    # hard filters. Contrast the band, which stays a tag - see the 2026-08-24 note above.
    #   1. the main protein must be one of four cuts;
    #   2. the dinner must carry a carbohydrate source. "I don't want a recipe that just says how to
    #      cook ground beef" - a cooked protein with no starch is not a meal, and 62% of the last
    #      broad-crawl pool had starch "none".
    # A filtered candidate stays in the pool AS MEMORY with the reason recorded, exactly like an
    # exclusion, so the page is never re-fetched to re-earn the same answer.
    round_cut = detect_round_cut(lines, entry.get("name") or "")
    round_starch = detect_starch(lines)
    if round_cut is None:
        entry["status"] = "ruled:rejected-not-fit"
        entry["exclusion"] = ("main protein is not one of this round's four cuts (boneless chicken "
                              "breast, ground beef, pork loin, ground turkey), or more than one of "
                              "them is present, or a disqualifying cut is")
        return slim_ruled(entry), "not-fit-cut"
    if round_starch == "none":
        entry["status"] = "ruled:rejected-not-fit"
        entry["exclusion"] = "no carbohydrate source - a cooked protein on its own is not a meal"
        return slim_ruled(entry), "not-fit-nostarch"

    entry["batch_concerns"] = batch_concerns(entry.get("name") or "", instr)
    entry["round_cut"] = round_cut
    # THE BAND IS TAGGED, NEVER ENFORCED HERE. Brad 2026-08-27: enforce proteins/composition, tag the
    # band. `meets_round_band` records whether the PUBLISHER's own figures clear 450-800 cal and the
    # 40 g protein floor, so a run can demand it and a later re-score on our own arithmetic can
    # overturn it. Nothing is buried on a number the site got wrong.
    _b = entry.get("band") or {}
    _cal, _pro = _b.get("cal"), _b.get("protein_g")
    # OUR OWN ARITHMETIC BESIDE THE PUBLISHER'S CLAIM (2026-08-27). The site's figure decides nothing
    # here, and neither does this - both are recorded so the run can prefer a candidate whose numbers
    # we can defend. Measured: on dill-pickle-chicken-wings the site said 620 and this says 854
    # against a true 888, which is the difference between paying for extraction and not.
    _pre = band_precheck.compute(lines, entry.get("servings") or 0)
    entry["band_computed"] = _pre
    entry["band_conflict"] = band_precheck.conflict(entry.get("band"), _pre)
    entry["meets_round_band"] = (
        None if not isinstance(_cal, (int, float)) or not isinstance(_pro, (int, float))
        else bool(450 <= _cal <= 800 and _pro >= 40))
    entry["signature"] = {
        "protein": detect_protein(lines, entry.get("name") or ""),
        "method": detect_method(entry.get("name") or "", instr, methods),
        "sauce_family": family_of((entry.get("name") or "") + " " + " ".join(lines[:12]), families),
        "starch": detect_starch(lines),
    }

    # THE INGEST BAND IS GONE (Brad's ruling 2026-08-24). harvest RECORDS what the page says; the RUN
    # decides what is acceptable. That is what band-as-run-parameter established this morning, and this
    # was the last place a second, hidden band survived: qualify() ruled candidates out at CRAWL time
    # against hard-coded 400-650 cal / <= 35 carbs, so 1,556 candidates - 64% of the pool - were buried
    # by a constraint no run had asked for, and every publisher's apparent "yield" was really a
    # measurement of that constant. An ingest band NARROWER than a run band can be is a candidate the
    # run would accept and can never reach.
    #
    # The numbers are still read and still recorded on entry["band"], so the run's pop filter and the
    # two macro gates work exactly as before on whatever band a prompt states. Nothing is weakened:
    # a band that IS stated still rejects, one stage later and where it can be seen.
    verdict = in_band(entry["band"], cal_min, cal_max, carb_max) if band_at_ingest else None
    if verdict is False:
        # FILTERED - and the numbers that filtered it are RECORDED, so the judgment is auditable and
        # the page is never re-fetched to re-earn the same answer. A filtered candidate stays in the
        # pool as memory; it is not `available`, so nothing can offer it to a decider.
        entry["status"] = "ruled:out-of-band"
        return slim_ruled(entry), "out-of-band"
    entry["status"] = "available"
    # DISPOSITION TRACKS THE NUMBERS, NOT A BAND RULING. With no ingest band, `verdict` is None for
    # every page, and calling them all "band-unverified" would lie about pages whose macros read
    # perfectly - dossier_rank reads this distinction to pop candidates whose band we can defend first.
    if verdict is None:
        disp = "in-band" if entry["band"].get("verified") else "band-unverified"
    else:
        disp = "in-band" if verdict is True else "band-unverified"
    return entry, disp


# =====================================================================================================
# politeness
# =====================================================================================================

class Robots:
    """robots.txt for one domain: the User-agent:* group plus any group naming us, Disallow only.

    Deliberately strict and dumb. A rule we cannot parse is treated as a rule (skip), because the cost
    of over-obeying a publisher is a candidate we do not get and the cost of under-obeying is the
    estate's name on a crawl complaint.
    """

    def __init__(self, domain, text):
        self.domain = domain
        self.disallow = []
        self.allow = []
        self.available = text is not None
        self.sitemaps = []
        group_applies = False
        for raw in (text or "").splitlines():
            line = raw.split("#", 1)[0].strip()
            if not line or ":" not in line:
                continue
            k, v = line.split(":", 1)
            k, v = k.strip().lower(), v.strip()
            if k == "sitemap" and v:
                self.sitemaps.append(v)
            elif k == "user-agent":
                group_applies = (v == "*" or "thriftycrew" in v.lower())
            elif k == "disallow" and group_applies and v:
                self.disallow.append(v)
            elif k == "allow" and group_applies and v:
                self.allow.append(v)

    def allows(self, url):
        path = urllib.parse.urlparse(url).path or "/"
        best_allow = max([len(a) for a in self.allow if path.startswith(a.rstrip("*"))] or [-1])
        best_deny = max([len(d) for d in self.disallow if path.startswith(d.rstrip("*"))] or [-1])
        if best_deny < 0:
            return True
        return best_allow >= best_deny


class Pacer:
    """One request per domain every POLITE_MIN..POLITE_MAX seconds, regardless of worker count.

    The delay is per DOMAIN and the lock is held across the sleep, so eight workers on one publisher
    queue behind each other rather than each waiting its own two seconds and then arriving together.
    Vendor pacing is the floor no core count moves (PLAN-use-the-cores).
    """

    def __init__(self, lo=POLITE_MIN_SEC, hi=POLITE_MAX_SEC, clock=None, sleeper=None, jitter=None):
        self.lo, self.hi = lo, hi
        self.last = {}
        self.locks = {}
        self.guard = threading.Lock()
        self.clock = clock or time.monotonic
        self.sleeper = sleeper or time.sleep
        self.jitter = jitter or (lambda: random.uniform(self.lo, self.hi))

    def _lock(self, domain):
        with self.guard:
            if domain not in self.locks:
                self.locks[domain] = threading.Lock()
            return self.locks[domain]

    def wait(self, domain):
        lk = self._lock(domain)
        lk.acquire()
        try:
            gap = self.jitter()
            prev = self.last.get(domain)
            slept = 0.0
            if prev is not None:
                need = (prev + gap) - self.clock()
                if need > 0:
                    self.sleeper(need)
                    slept = need
            self.last[domain] = self.clock()
            return slept
        finally:
            lk.release()


def read_harvest_state(path=HARVEST_STATE):
    if not os.path.exists(path):
        return {"_doc": "Per-domain nightly fetch counts and the enumeration cursor, so a capped run "
                        "resumes where it stopped instead of re-walking the same sitemap.",
                "days": {}, "cursor": {}}
    with open(path, "r", encoding="utf-8-sig") as f:
        return json.load(f)


def write_harvest_state(st, path=HARVEST_STATE):
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


def nightly_room(state, domain, cap=NIGHTLY_CAP, today=None):
    today = today or date.today().isoformat()
    return cap - int((state.get("days") or {}).get(today, {}).get(domain, 0))


def note_fetch(state, domain, today=None):
    today = today or date.today().isoformat()
    state.setdefault("days", {}).setdefault(today, {})
    state["days"][today][domain] = int(state["days"][today].get(domain, 0)) + 1


# =====================================================================================================
# enumeration
# =====================================================================================================

def http_get(url, timeout=25):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        if raw[:2] == b"\x1f\x8b":
            raw = gzip.decompress(raw)
        return raw.decode("utf-8", errors="replace")


def reliable_domains(path=SOURCE_DOMAINS_JSON):
    """The publishers the ledger calls reliable. `blocked` is never crawled; `unknown`/`unreliable`
    are not enumerated either - a publisher earns enumeration by having worked."""
    with open(path, "r", encoding="utf-8-sig") as f:
        d = json.load(f)
    return [r["domain"] for r in (d.get("domains") or []) if r.get("status") == "reliable"]


SKIP_PATH = ("/category/", "/tag/", "/author/", "/web-stories/", "/page/", "/wp-content/",
             "/about", "/contact", "/privacy", "/shop", "/product", "/course/", "/cookbook",
             "/recipe-index", "/feed", "/attachment/")

# IMAGE ATTACHMENT PAGES (Brad's ruling 2026-08-24, after the no-band drill).
#
# WordPress mints a PAGE for every uploaded image, and sitemaps list them. They are not recipes and
# never can be - they carry no JSON-LD Recipe block, which is exactly why they piled up in the
# ingredient-less corner of the pool. MEASURED: 187 of the 280 available candidates with no JSON-LD
# were these, 67% - `baked-pork-chops-2-jpg`, `chicken-stir-fry-chop-suey-5-landscape-jpg`,
# `close-up-of-baked-pork-chops-with-potato-jpg`. Each one had already cost a fetch from a 60-a-day
# politeness budget, and with the band dropped they became poppable, so each could also cost a
# dossier slot in front of a paid decider.
#
# MATCHED ON THE SLUG'S TAIL, not on a bare "jpg" anywhere. A real recipe can legitimately be
# `air-fryer-jpg-chicken` in some parallel universe, and more plausibly can carry digits
# (`5-ingredient-chili`); the clean twins pin both. The tail patterns are how WordPress actually
# names these: a trailing extension word, a dimension pair, or a photo-orientation suffix.
IMAGE_TAIL = re.compile(
    r"(?:-(?:jpg|jpeg|png|webp|gif|scaled)"          # trailing extension word, WP's slugified upload
    r"|\.(?:jpg|jpeg|png|webp|gif)"                  # or a real file extension
    r"|-\d+x\d+"                                     # or a dimension pair, 1200x628
    r"|-(?:landscape|portrait|overhead|closeup|close-up|thumb|thumbnail))"
    r"/?$", re.I)


def is_image_page(url):
    """True for a WordPress image attachment page. Reads the URL's TAIL only - see IMAGE_TAIL."""
    path = urllib.parse.urlparse(str(url or "")).path or str(url or "")
    return bool(IMAGE_TAIL.search(path.rstrip("/")))
PRIORITY_WORDS = ("chicken", "beef", "pork", "turkey", "sausage", "steak", "keto", "low-carb",
                  "lowcarb", "skillet", "casserole", "bake", "stew", "braised", "sheet-pan",
                  "meatball", "chop", "roast", "curry", "taco", "stir-fry")


def _locs(xml_text):
    try:
        root = ET.fromstring(xml_text.encode("utf-8", errors="replace"))
    except Exception:
        return None, []
    tag = root.tag.split("}")[-1]
    return tag, [e.text.strip() for e in root.iter()
                 if e.tag.split("}")[-1] == "loc" and e.text and e.text.strip()]


def enumerate_domain(domain, robots, want=600, getter=None):
    """Recipe URL candidates for one publisher, priority-ordered.

    ORDERING, NOT A VERDICT. A URL's slug is a hint about what the page might be; the band filter acts
    on the page's own JSON-LD and nothing else. Ordering only decides what a capped night looks at
    FIRST - a URL not reached tonight is not ruled, it is still on the cursor tomorrow.
    """
    get = getter or http_get
    seeds = list(robots.sitemaps)
    for guess in ("sitemap_index.xml", "wp-sitemap.xml", "sitemap.xml"):
        u = "https://%s/%s" % (domain, guess)
        if u not in seeds:
            seeds.append(u)
    urls, seen_maps = [], set()
    for s in seeds:
        if s in seen_maps or len(urls) >= want * 4:
            continue
        seen_maps.add(s)
        try:
            tag, locs = _locs(get(s))
        except Exception:
            continue
        if tag == "sitemapindex":
            for sub in locs:
                low = sub.lower()
                if any(bad in low for bad in ("category", "tag", "author", "web-stor", "image",
                                              "video", "product", "page-sitemap")):
                    continue
                if len(urls) >= want * 4:
                    break
                try:
                    _t2, locs2 = _locs(get(sub))
                except Exception:
                    continue
                urls.extend(locs2)
        elif tag:
            urls.extend(locs)
    if not urls:
        # WP-REST fallback: the second road section 3 S1 item 1 names.
        for page in range(1, 6):
            try:
                rows = json.loads(get("https://%s/wp-json/wp/v2/posts?per_page=100&page=%d&_fields=link"
                                      % (domain, page)))
            except Exception:
                break
            if not rows:
                break
            urls.extend([r.get("link") for r in rows if isinstance(r, dict) and r.get("link")])
    out, seen = [], set()
    for u in urls:
        if not u or u in seen:
            continue
        seen.add(u)
        low = u.lower()
        if domain not in low:
            continue
        if any(sk in low for sk in SKIP_PATH):
            continue
        if is_image_page(u):
            continue
        if low.rstrip("/").endswith(domain):
            continue
        if not robots.allows(u):
            continue
        out.append(u)
    out.sort(key=lambda u: (-sum(1 for w in PRIORITY_WORDS if w in u.lower()), u))
    return out


def get_robots(domain, cache_dir=ROBOTS_DIR):
    os.makedirs(cache_dir, exist_ok=True)
    p = os.path.join(cache_dir, domain + ".txt")
    if os.path.exists(p) and (time.time() - os.path.getmtime(p)) < 7 * 86400:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            return Robots(domain, f.read())
    try:
        text = http_get("https://%s/robots.txt" % domain, timeout=15)
    except Exception:
        text = None
    if text is not None:
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
    return Robots(domain, text)


# =====================================================================================================
# dedup scoring
# =====================================================================================================

def _batch_call(script, args, rows, payload, key_name, timeout=600):
    if not rows:
        return {}
    tmp = os.path.join(os.environ.get("TEMP", "."), "harvest-%s-%d.json" % (key_name, os.getpid()))
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(payload, f, ensure_ascii=False)
    try:
        rc, out = run_ps(script, args + ["-BatchFile", tmp, "-Json"], timeout=timeout)
        if rc not in (0, 3):
            return {}
        try:
            data = json.loads(out)
        except Exception:
            return {}
        if isinstance(data, dict):
            data = [data]
        return {r.get("key"): r for r in data if isinstance(r, dict)}
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


# ---- the ingredient channel (D12 rung 1, S2a defect 2) ----------------------------------------------
# find-similar.ps1's Get-Score has always awarded a bonus for shared commodity items, with its own
# fixture proving it - and score_pool sent `"items": []` for every candidate, so the channel ran on
# names alone. Names are exactly where duplicates hide: "Marry Me Chicken" and "Creamy Sun-Dried Tomato
# Chicken" share no name word and one ingredient list, and the embedding channel does not cover for it
# (its signature string is name + protein by design, so ingredients are invisible to BOTH channels).
#
# A candidate has no canonical item ids - the mapper has not run and will not run until after the
# decider rules - so the plug is a NORMALISATION into the item-id word namespace: the board's ids are
# kebab-case English, so verbatim ingredient lines are reduced to their content words and find-similar
# matches those words against the words of each digest row's ids. The matching rule and the singular/
# plural fold live in find-similar.ps1 with Get-Score, in ONE place; this side only extracts words.
#
# WHY THIS STOP LIST IS HERE AND NOT PARSED FROM A LEDGER. It is a tokeniser's stop list, not a
# taxonomy: it classifies nothing and no other file rules on it. The two vocabularies that ARE
# taxonomies - the sauce families and the method enum - are still parsed from the files that own them.
INGREDIENT_STOP = set("""
tsp tsps teaspoon teaspoons tbsp tbsps tablespoon tablespoons cup cups ounce ounces pound pounds
gram grams kilogram pint pints quart quarts gallon liter liters litre millilitre milliliter
pinch dash handful package packages pkg jar jars bag bags box boxes bottle bottles carton container
slice slices piece pieces inch inches clove cloves stick sticks sprig sprigs bunch bunches head heads
about approximately plus more less taste optional divided room temperature needed serving servings
garnish garnishing topping toppings for and the with into from your our each any some such well
cut chopped finely roughly thinly coarsely halved quartered peeled seeded rinsed drained trimmed
lengthwise crosswise cubed minced diced sliced grated melted softened beaten cooked uncooked
warm cold hot large medium small extra plain plenty
""".split())

# WHAT IS DELIBERATELY NOT IN THAT LIST. `canned`, `frozen`, `shredded`, `boneless`, `skinless`,
# `ground` and their kind look like prep words and are ID words - canned-corn, frozen-broccoli-florets,
# boneless-skinless-chicken-thigh, 93-7-ground-turkey. Dropping them would cost the channel exactly the
# specificity it is being plugged in for, since an id only counts as shared when every word of it is
# known (find-similar.ps1's Get-ItemWords).

_ING_PAREN = re.compile(r"\([^)]*\)")
_ING_NONALPHA = re.compile(r"[^a-z]+")


def ingredient_words(lines, cap=120):
    """Verbatim ingredient lines -> the content words find-similar matches against item ids.

    Quantities, units and prep verbs go; the nouns and the qualifiers the board's ids are built from
    stay. Deliberately crude and lossy in the safe direction: an extra word costs a spurious +1 the
    decider sees named in shared_items, a missing word costs a duplicate nobody is ever shown.
    """
    out = []
    seen = set()
    for line in (lines or []):
        text = _ING_PAREN.sub(" ", str(line).lower())
        for w in _ING_NONALPHA.split(text):
            if len(w) < 3 or w in INGREDIENT_STOP or w in seen:
                continue
            seen.add(w)
            out.append(w)
            if len(out) >= cap:
                return out
    return out


def batch_find_similar(rows, top=DOSSIER_NEIGHBOUR_CAP):
    """find-similar.ps1's word-overlap shortlist for many candidates in ONE process.

    Its Get-Score is the estate's implementation of this shortlist and stays the only one; a Python
    re-write here would be a second copy of a scoring rule, which is how two copies start disagreeing.
    """
    payload = [{"key": r["slug"], "name": r["name"], "protein": r.get("protein") or "",
                "items": r.get("items") or []} for r in rows]
    res = _batch_call(FIND_SIMILAR_PS, ["-Top", top], rows, payload, "fs")
    return {k: (v.get("matches") or []) for k, v in res.items()}


def batch_prior_rulings(rows):
    """considered-dishes.ps1's prior rulings for many candidates in ONE process. Same reasoning: the
    wildcard-matching rule ('any' matches everything, concrete protein+method is evidence) lives in
    that file only."""
    payload = [{"key": r["slug"], "name": r["name"], "protein": r.get("protein") or "",
                "method": r.get("method") or ""} for r in rows]
    res = _batch_call(CONSIDERED_PS, ["-Query"], rows, payload, "cd")
    return {k: (v.get("rulings") or []) for k, v in res.items()}


def load_saturation(path=SATURATION_JSON):
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            d = json.load(f)
    except Exception:
        return {}
    out = {}
    for key in ("regions", "crowded", "all_regions"):
        for r in (d.get(key) or []):
            out["%s|%s" % (r.get("protein"), r.get("family"))] = int(r.get("count") or 0)
    return out


def load_embed_neighbours(path=NEIGHBOUR_FILE):
    """The bge-m3 cosine shortlist the embedding lane (D4) writes, if it has run.

    Absent is normal and never blocking: the pool is scored on word overlap and prior rulings alone
    until the embedding lane has run, and the dossier states which signals it carries so the decider
    is never left guessing how much evidence is behind a neighbour block.
    """
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            return (json.load(f) or {}).get("neighbours") or {}
    except Exception:
        return {}


def load_similarity_calibration(path=CALIBRATION_FILE, digest_path=CATALOG_DIGEST):
    """The live catalog's own pairwise similarity distribution, or a REASON we cannot see it.

    Returns (record, reason). Exactly one of the two is ever set, and `reason` is the whole point:
    a missing or stale calibration is could-not-look, and could-not-look is never a clean bill. There
    is no default distribution and no fallback threshold - S2a part b puts the threshold in the corpus,
    so a reader without the corpus's answer has NO answer and says so.

    STALE IS BLIND TOO. The record names the digest it was computed from by content fingerprint; if the
    digest on disk has moved since, the numbers describe a catalog that no longer exists. The
    fingerprint function is harvest_embed's own - the writer's - imported rather than re-implemented,
    so the two can never drift apart on what "the same digest" means. That import is safe under the
    graph interpreter: harvest_embed guards its torch/numpy imports and reports them at main().
    """
    if not os.path.exists(path):
        return None, ("no calibration at %s - run harvest_embed.py --calibrate under the sidecar venv "
                      "(make-catalog-digest.ps1 does it for you)" % path)
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            rec = json.load(f)
    except Exception as e:
        return None, "the calibration at %s could not be read (%s)" % (path, e)
    for k in ("p50", "p90", "p99", "n", "dupe_threshold", "generated_from"):
        if k not in rec:
            return None, "the calibration is missing `%s` - it cannot be the file S2a part b specifies" % k
    try:
        sys.path.insert(0, HERE)
        import harvest_embed
        fp = harvest_embed.digest_fingerprint(digest_path)
    except Exception as e:
        return None, "the digest could not be fingerprinted to date the calibration against (%s)" % e
    if (rec.get("generated_from") or {}).get("sha256") != fp["sha256"]:
        return None, ("the calibration is STALE: it was computed from a digest of %s recipes "
                      "(%s...), the digest on disk is %s recipes (%s...)"
                      % ((rec.get("generated_from") or {}).get("recipe_count"),
                         str((rec.get("generated_from") or {}).get("sha256"))[:12],
                         fp["recipe_count"], fp["sha256"][:12]))
    return rec, ""


def cmd_calibration(a):
    """Report the corpus calibration, or REFUSE. No verb in this file hand-sets a similarity number."""
    rec, reason = load_similarity_calibration()
    if rec is None:
        say("harvest --calibration: BLIND - %s" % reason)
        say("  There is no default. A threshold nobody measured is a threshold nobody can defend.")
        say("HARVEST-COMPLETE")
        return 2
    if a.json:
        print(json.dumps(rec, indent=1))
        say("HARVEST-COMPLETE")
        return 0
    say("harvest --calibration: %d live recipes, %d pairs, %s"
        % (rec.get("recipes") or 0, rec["n"], rec.get("model") or "?"))
    say("  p50 %.4f   p90 %.4f   p99 %.4f   max %.4f"
        % (rec["p50"], rec["p90"], rec["p99"], rec.get("max") or rec["dupe_threshold"]))
    say("  dupe threshold READ from the corpus: %.4f  (%s)"
        % (rec["dupe_threshold"], rec.get("dupe_threshold_basis") or "basis not stated"))
    for p in (rec.get("closest_published_pairs") or [])[:3]:
        say("    closest published pair: %s <-> %s  %.4f" % (p["a"], p["b"], p["score"]))
    say("  Calibration only - S2a: no auto-rejection on similarity at any score.")
    say("HARVEST-COMPLETE")
    return 0


def score_pool(pool, quiet=False):
    """Refresh neighbours / prior rulings / saturation pressure for every AVAILABLE candidate."""
    rows = []
    for c in pool["candidates"]:
        if c.get("status") != "available":
            continue
        sig = c.get("signature") or {}
        rows.append({"slug": c["slug"], "name": c.get("name") or c["slug"],
                     "protein": sig.get("protein") or "", "method": sig.get("method") or "",
                     # THE PLUGGED CHANNEL (D12 rung 1). This was `[]` from the day the batch road was
                     # built, which meant find-similar's shared-items bonus - fixture and all - ran on
                     # empty input for every candidate the harvest has ever scored.
                     "items": ingredient_words(c.get("ingredients_verbatim"))})
    if not rows:
        return 0
    sim = batch_find_similar(rows)
    prior = batch_prior_rulings(rows)
    sat = load_saturation()
    emb = load_embed_neighbours()
    n, blind_live, with_items = 0, 0, 0
    for c in pool["candidates"]:
        if c.get("status") != "available":
            continue
        neigh = []
        for m in (sim.get(c["slug"]) or [])[:DOSSIER_NEIGHBOUR_CAP]:
            # find-similar scores against the catalog digest and nothing else, so every row it
            # returns is a LIVE recipe by construction.
            neigh.append({"slug": m.get("slug"), "name": m.get("name"), "score": m.get("score"),
                          "shared": m.get("shared_words") or [], "source": "word-overlap",
                          "side": "live-catalog",
                          # The ingredient channel's evidence, NAMED. S2a: every number a dossier
                          # carries must be auditable - it names the recipe and the score, never a
                          # bare integer, and a shared-items bonus with no items listed is exactly
                          # the bare integer that rule exists to forbid.
                          "shared_items": m.get("shared_items") or []})
        # PER SIDE, not the first five of a concatenated list (D12 rung 1). harvest_embed now hands
        # back up to `top` catalog rows followed by up to `top` pool rows; a flat [:CAP] here would
        # throw the backlog side away and re-open the starvation from the other end.
        emb_rows = emb.get(c["slug"]) or []
        per_side = {}
        for m in emb_rows:
            side = "live-catalog" if m.get("side") == "catalog" else "backlog"
            if len(per_side.setdefault(side, [])) >= DOSSIER_NEIGHBOUR_CAP:
                continue
            per_side[side].append(m)
        for m in per_side.get("live-catalog", []) + per_side.get("backlog", []):
            # THE EMBEDDING LANE SCORES AGAINST BOTH the live catalog AND the rest of the backlog, and
            # the two mean completely different things to a decider: a live neighbour is a published
            # dinner it would be duplicating, a backlog neighbour is another candidate nobody has
            # ruled on yet. Shipping them unlabelled was a real defect - the decider caught it itself
            # on 2026-08-23 ("several 0.90+ neighbours are absent from the live digest, so they must
            # not be treated as catalog dupes") and went and read catalog-digest.json to tell them
            # apart, which is exactly the corpus read section S2 exists to make unnecessary.
            neigh.append({"slug": m.get("slug"), "name": m.get("name"),
                          "score": round(float(m.get("score") or 0), 4), "shared": [],
                          "source": "bge-m3",
                          "side": ("live-catalog" if m.get("side") == "catalog" else "backlog")})
        c["neighbours"] = neigh
        c["prior_rulings"] = prior.get(c["slug"]) or []
        sig = c.get("signature") or {}
        fam = sig.get("sauce_family")
        c["saturation_pressure"] = sat.get("%s|%s" % (sig.get("protein") or "any", fam), 0) if fam else 0
        n += 1
        if not [x for x in neigh if x.get("side") == "live-catalog"]:
            blind_live += 1
        if [x for x in neigh if x.get("shared_items")]:
            with_items += 1
    if not quiet:
        say("  scored %d available candidate(s): word-overlap%s + prior rulings + saturation"
            % (n, "+bge-m3" if emb else ""))
        # THE D12 RUNG-1 GATE, MEASURED ON EVERY RUN rather than once at build time. A candidate with
        # no live-catalog neighbour hands the decider an empty live block next to `catalog_checked`,
        # which reads as evidence of absence. Zero is the number this is supposed to say.
        say("  %d of %d carry NO live-catalog neighbour%s; %d carry ingredient evidence (shared_items)"
            % (blind_live, n, " - the catalog digest is missing" if not catalog_size() else "",
               with_items))
    return n


# =====================================================================================================
# verbs
# =====================================================================================================

def _record_outcome(url, outcome, note=""):
    """Every ENUMERATION outcome goes to source-domains.ps1. Page fetches are recorded by
    fetch-recipe.ps1 itself (it owns that road), so recording them again here would double-count a
    publisher's failures and blocked-after-three would fire at one and a half."""
    args = ["-Record", "-Domain", url, "-Outcome", outcome]
    if note:
        args += ["-Note", note[:120]]
    run_ps(SOURCE_DOMAINS_PS, args, timeout=60)


def cmd_crawl(a):
    findings = []
    try:
        families = load_families()
    except Exception as e:
        say("harvest: CANNOT RUN - %s" % e)
        return 2
    methods, unmapped = load_methods()
    if not methods:
        say("harvest: CANNOT RUN - db\\considered-dishes.json holds no -Method values, so there is no "
            "method enum to classify against. Do not invent one.")
        return 2
    if unmapped:
        findings.append("method enum drift: the ledger records %s, which harvest.py has no detector "
                        "for - every candidate will read as that method's absence" % ", ".join(unmapped))

    if a.domains:
        domains = [d.strip() for d in a.domains.split(",") if d.strip()]
    else:
        try:
            domains = reliable_domains()
        except Exception as e:
            say("harvest: CANNOT RUN - cannot read the source-domains ledger (%s)" % e)
            return 2
    if not domains:
        say("harvest: CANNOT RUN - the source-domains ledger lists no reliable publisher to enumerate")
        return 2

    say("harvest --crawl over %d publisher(s): %s" % (len(domains), ", ".join(domains)))
    state = read_harvest_state()
    pool = read_pool()
    by_slug, by_url = pool_index(pool)
    pub_slugs, _pub_names = published_slugs()
    pacer = Pacer()
    cap = a.per_domain or NIGHTLY_CAP
    today = date.today().isoformat()

    plan = {}
    for d in domains:
        rc, _out = run_ps(SOURCE_DOMAINS_PS, ["-Query", "-Domain", d], timeout=60)
        if rc == 3:
            findings.append("%s is BLOCKED in the ledger - not crawled" % d)
            continue
        robots = get_robots(d)
        if not robots.available:
            findings.append("%s served no robots.txt - enumerating conservatively" % d)
        try:
            urls = enumerate_domain(d, robots)
        except Exception as e:
            findings.append("%s could not be enumerated: %s" % (d, e))
            _record_outcome("https://%s/" % d, "fail", "harvest enumeration: %s" % e)
            continue
        if not urls:
            findings.append("%s enumerated ZERO recipe URLs (no sitemap, no WP-REST) - it starves the "
                            "harvester and needs the Claude sourcer road instead" % d)
            continue
        room = max(0, min(cap, nightly_room(state, d, cap, today)))
        # Already-pooled URLs are dropped rather than skipped-over, so tonight's cap advances the
        # frontier by itself: today's top `room` enter the pool, and tomorrow `fresh` starts after
        # them. A separate cursor would only be a second, driftable, account of the same fact.
        fresh = [u for u in urls if norm_url(u) not in by_url]
        take = fresh[:room]
        plan[d] = {"urls": take, "enumerated": len(urls), "fresh": len(fresh), "robots": robots}
        say("  %-28s %5d enumerated, %5d unseen, taking %d (nightly cap %d)"
            % (d, len(urls), len(fresh), len(take), cap))

    if a.dry_run:
        say("harvest: --dry-run, nothing fetched and nothing written")
        for f in findings:
            say("  FINDING  " + f)
        say("HARVEST-COMPLETE")
        return 1 if findings else 0

    total_target = a.limit or 10 ** 9
    results = []
    lock = threading.Lock()
    counters = {"fetched": 0, "cached": 0, "kept": 0, "ruled": 0, "failed": 0}

    def work(domain, url):
        with lock:
            if counters["kept"] >= total_target:
                return None
        body = cached_body(url)
        touched_network = False
        if body is None:
            pacer.wait(domain)
            body, touched_network = fetch_through_cache(url)
        if body is None:
            with lock:
                counters["failed"] += 1
            return None
        with lock:
            if touched_network:
                counters["fetched"] += 1
                note_fetch(state, domain, today)
            else:
                counters["cached"] += 1
        node = recipe_jsonld(body)
        name = (str(node.get("name")).strip() if node and node.get("name") else
                urllib.parse.urlparse(url).path.rstrip("/").split("/")[-1].replace("-", " ").title())
        slug = slugify(name)
        entry = new_entry(slug, name, url, domain, "crawl")
        entry, disp = qualify(entry, node, families, methods)
        return entry, disp

    # ONE worker pool over an INTERLEAVED work list. Fanning per-domain and running the domains one
    # after another would make the wall-clock the SUM of seven paced walks; interleaving makes it the
    # longest single one, because the Pacer serialises each domain independently while eight workers
    # spread across all seven. Vendor pacing stays the floor - what changes is that we stop idling
    # against it (PLAN-use-the-cores: a fan-out may not move the vendor's floor, only stop wasting it).
    work_list = []
    order = [(d, list(p["urls"])) for d, p in plan.items() if p["urls"]]
    while any(u for _d, u in order):
        for _d, urls_left in order:
            if urls_left:
                work_list.append((_d, urls_left.pop(0)))
    if work_list:
        with ThreadPoolExecutor(max_workers=min(FETCH_WORKERS, len(work_list))) as ex:
            for r in ex.map(lambda du: work(du[0], du[1]), work_list):
                if r:
                    results.append(r)
    for domain, p in plan.items():
        state.setdefault("cursor", {})[domain] =             int((state.get("cursor") or {}).get(domain, 0)) + len(p["urls"])

    added, skipped_pub, skipped_dupe = 0, 0, 0
    for entry, disp in results:
        # An exact already-published slug never enters the pool. The catalog already carries that
        # dinner; re-offering it to a decider is the churn this whole plane exists to stop.
        why = refuse_entry(entry["slug"], entry["url"], pub_slugs, by_slug, by_url)
        if why == "already published":
            skipped_pub += 1
            continue
        if why:
            skipped_dupe += 1
            continue
        pool["candidates"].append(entry)
        by_slug[entry["slug"]] = entry
        by_url[norm_url(entry["url"])] = entry
        added += 1
        if entry["status"].startswith("ruled:"):
            counters["ruled"] += 1
        else:
            counters["kept"] += 1

    score_pool(pool)
    write_pool(pool)
    write_harvest_state(state)

    avail = [c for c in pool["candidates"] if c.get("status") == "available"]
    verified = [c for c in avail if (c.get("band") or {}).get("verified")]
    doms = sorted(set(c["domain"] for c in avail))
    say("")
    say("  network fetches %d, cache hits %d, failed %d" % (counters["fetched"], counters["cached"],
                                                            counters["failed"]))
    say("  new pool entries %d  (available %d, ruled on entry %d)" % (added, counters["kept"],
                                                                      counters["ruled"]))
    say("  already published, never entered: %d ; already in pool: %d" % (skipped_pub, skipped_dupe))
    say("  POOL now: %d entries, %d available (%d band-verified) from %d publisher(s)"
        % (len(pool["candidates"]), len(avail), len(verified), len(doms)))
    for f in findings:
        say("  FINDING  " + f)
    say("HARVEST-COMPLETE")
    return 1 if findings else 0


LLAMA_URL = os.environ.get("LLAMA_SERVER", "http://127.0.0.1:8080")


def llama_up(url=None, timeout=3):
    url = url or LLAMA_URL
    try:
        req = urllib.request.Request(url.rstrip("/") + "/health")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


def cmd_classify(a):
    """Backfill sauce_family on entries the keyword vocabulary could not settle.

    REFUSES when llama-server is down - the audit-semantic-identity BLIND pattern. A classify pass
    that cannot reach the model has not classified anything, and reporting that as a clean run is the
    could-not-look-is-not-a-clean-bill failure this estate has mechanised against five times. Nothing
    here schedules the server: it is started by hand at run start and stopped at run end (section 4.4).
    """
    if not llama_up():
        say("harvest --classify: REFUSING - llama-server is not answering at %s." % LLAMA_URL)
        say("  Start it by hand (section 4.4: the card is hand-held; nightly.ps1 owns 21:30-06:30 and")
        say("  a hunt run must be off the card before the 07:00 ad pull), then run this again.")
        say("  Nothing was classified and nothing was written. A null sauce_family is not a defect -")
        say("  it only widens the neighbour search.")
        say("HARVEST-COMPLETE")
        return 2
    families = load_families()
    enum = sorted(families.keys()) + ["plain"]
    pool = read_pool()
    todo = [c for c in pool["candidates"]
            if c.get("status") == "available" and not (c.get("signature") or {}).get("sauce_family")]
    if a.limit:
        todo = todo[:a.limit]
    if not todo:
        say("harvest --classify: nothing to classify - every available candidate already carries a "
            "sauce family")
        say("HARVEST-COMPLETE")
        return 0
    say("harvest --classify: %d candidate(s), closed enum %s" % (len(todo), ", ".join(enum)))
    done = 0
    for c in todo:
        verdict = classify_one(c, enum)
        if verdict in enum:
            c["signature"]["sauce_family"] = None if verdict == "plain" else verdict
            done += 1
    score_pool(pool)
    write_pool(pool)
    say("  classified %d of %d" % (done, len(todo)))
    say("HARVEST-COMPLETE")
    return 0 if done == len(todo) else 1


def classify_one(cand, enum, url=None):
    """One grammar-forced closed-enum call. The answer is a SHORTLIST KEY, never a verdict: it steers
    which neighbours the dossier carries and nothing else (section 3 S1 item 4). A value outside the
    enum is discarded rather than coerced."""
    url = (url or LLAMA_URL).rstrip("/") + "/completion"
    ings = "; ".join((cand.get("ingredients_verbatim") or [])[:15])
    prompt = ("Classify the sauce or flavour family of this dish. Answer with exactly one word from "
              "the list and nothing else.\nList: %s\nDish: %s\nIngredients: %s\nAnswer:"
              % (", ".join(enum), cand.get("name") or cand.get("slug"), ings))
    grammar = "root ::= (" + " | ".join('"%s"' % e for e in enum) + ")"
    body = json.dumps({"prompt": prompt, "grammar": grammar, "n_predict": 8, "temperature": 0.0}
                      ).encode("utf-8")
    try:
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            out = json.loads(r.read().decode("utf-8", errors="replace"))
        return (out.get("content") or "").strip().lower()
    except Exception:
        return ""


NL = chr(10)
DEDUP_SHORTLIST_MIN = 20      # who to ASK about, never who to refuse - see the calibration below
DEDUP_ASK_CAP = 3             # at most three neighbours per candidate; the top ones carry the signal


def llm_same_dinner(cand, neighbour, url=None, timeout=60):
    """Ask the LOCAL model whether a candidate is the same dinner as a live recipe. "yes" or "no".

    Grammar-forced closed enum at temperature 0, exactly like classify_sauce_family above - the model
    picks between two tokens and cannot free-text its way into an ambiguous answer.
    """
    url = (url or LLAMA_URL).rstrip("/") + "/completion"
    ings = "; ".join((cand.get("ingredients_verbatim") or [])[:12])
    shared = ", ".join((neighbour.get("shared_items") or neighbour.get("shared") or [])[:8])
    prompt = NL.join([
        "You are deduplicating a recipe catalog. Two dinners are THE SAME DINNER when a reader "
        "would not buy both: same main protein, same cooking method, same sauce or flavour "
        "identity. A different vehicle for the same filling (taco vs burrito vs bowl) is the SAME "
        "dinner. A genuinely different plate that happens to share ingredients is NOT.",
        "Already published: %s" % (neighbour.get("name") or neighbour.get("slug")),
        "Candidate: %s" % (cand.get("name") or cand.get("slug")),
        "Candidate ingredients: %s" % ings,
        "Shared with the published one: %s" % (shared or "(not computed)"),
        "Is the candidate the same dinner as the published recipe? Answer yes or no.",
        "Answer:"])
    body = json.dumps({"prompt": prompt, "grammar": 'root ::= ("yes" | "no")',
                       "n_predict": 4, "temperature": 0.0}).encode("utf-8")
    try:
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out = json.loads(r.read().decode("utf-8", errors="replace"))
        return (out.get("content") or "").strip().lower()
    except Exception:
        return ""


def llm_different_dinner(cand, neighbour, url=None, timeout=60):
    """The MIRROR of llm_same_dinner. Its answer is only used to detect that the model is
    agreeing with whatever it is asked - see the note at the call site."""
    url = (url or LLAMA_URL).rstrip("/") + "/completion"
    prompt = NL.join([
        "Two recipe titles.",
        "A: %s" % (neighbour.get("name") or neighbour.get("slug")),
        "B: %s" % (cand.get("name") or cand.get("slug")),
        "Are A and B DIFFERENT dinners that a reader might want both of? Answer yes or no.",
        "Answer:"])
    body = json.dumps({"prompt": prompt, "grammar": 'root ::= ("yes" | "no")',
                       "n_predict": 4, "temperature": 0.0}).encode("utf-8")
    try:
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out = json.loads(r.read().decode("utf-8", errors="replace"))
        return (out.get("content") or "").strip().lower()
    except Exception:
        return ""


def refuse_near_dupes(pool, quiet=False):
    """Rule an obvious near-duplicate OUT before it sits in the pool as a candidate (Brad 2026-08-27:
    "We need to send them through dedup FIRST before storing in the DB").

    WHY A THRESHOLD CANNOT DO THIS, MEASURED. Scored against the live catalog, the estate's 68 known
    rejected-dupes and its 51 known accepted candidates have the SAME word-overlap distribution -
    both median 20, both max 40. At >= 20 a threshold catches 85% of the dupes and wrongly refuses
    71% of the ACCEPTED ones; at >= 25 it catches 21% and still wrongly refuses 8%. There is no cut
    point, because the signal genuinely does not separate "chicken cordon bleu pasta vs chicken
    cordon bleu casserole" (a dupe) from "beef chili vs beef chili mac" (not one). So word overlap
    picks WHO TO ASK ABOUT and the local model makes the call.

    BEST EFFORT, NEVER BLOCKING, AND IT SAYS WHICH. The 18:00 crawl calls this and nothing starts
    llama-server for it. A dedup pass that could not reach the model has not deduplicated anything,
    and recording that as clean is the could-not-look-is-not-a-clean-bill failure this estate has
    mechanised against repeatedly - so every candidate carries `dedup_at_ingest`: "llm" when it was
    judged, "unavailable" when the model was down, "no-neighbour" when there was nothing to ask
    about. The decide lane still rules on everything either way; this only stops the obvious ones
    from ever being stored.
    """
    avail = [c for c in pool["candidates"] if c.get("status") == "available"
             and not c.get("dedup_at_ingest")]
    if not avail:
        return 0
    up = llama_up()
    refused = 0
    for c in avail:
        near = [n for n in (c.get("neighbours") or [])
                if n.get("side") == "live-catalog" and (n.get("score") or 0) >= DEDUP_SHORTLIST_MIN]
        if not near:
            c["dedup_at_ingest"] = "no-neighbour"
            continue
        if not up:
            c["dedup_at_ingest"] = "unavailable"
            continue
        near.sort(key=lambda n: -(n.get("score") or 0))
        verdict = ""
        for n in near[:DEDUP_ASK_CAP]:
            # TWO POLARITIES, AND THE MODEL MUST DISAGREE WITH ITSELF TO BE BELIEVED.
            # Measured 2026-08-27 on seven labelled pairs: asked "are these the same dinner?"
            # AND "are these different dinners?", the local model answered YES to BOTH on every
            # single pair - including stroganoff vs burrito. A grammar-forced binary makes it
            # answer, it does not make it discriminate, and a one-sided ask read that bias as 14
            # near-duplicate refusals out of 15 candidates, ten of them plainly wrong. So a
            # verdict counts ONLY when the mirrored question contradicts it. A model that agrees
            # with both framings has told us nothing, and nothing is what we act on.
            if llm_same_dinner(c, n) == "yes" and llm_different_dinner(c, n) == "no":
                verdict = n.get("slug") or n.get("name")
                break
        if verdict:
            c["status"] = "ruled:rejected-dupe"
            c["exclusion"] = ("near-duplicate of live recipe '%s', ruled at ingest by the local model "
                              "before storing" % verdict)
            c["dedup_at_ingest"] = "llm"
            refused += 1
        else:
            c["dedup_at_ingest"] = "llm"
    if not quiet:
        state = "local model" if up else "MODEL DOWN - candidates stored UNDEDUPED and tagged"
        say("  dedup at ingest (%s): %d refused as near-duplicates of live recipes" % (state, refused))
    return refused


def cmd_ingest(a):
    """The ONE road in for a top-up sourcer's finds.

    Every candidate - crawled or searched - gets the same band check, signature and dedup scoring
    before the pool will hold it. An --ingest candidate is not trusted more than a crawled one because
    a frontier model found it; the page's own JSON-LD still rules the band.
    """
    if not a.ingest or not os.path.exists(a.ingest):
        say("harvest --ingest: CANNOT RUN - no candidates file at %s" % a.ingest)
        say("HARVEST-COMPLETE")
        return 2
    try:
        with open(a.ingest, "r", encoding="utf-8-sig") as f:
            payload = json.load(f)
    except Exception as e:
        say("harvest --ingest: CANNOT RUN - %s does not parse (%s)" % (a.ingest, e))
        say("HARVEST-COMPLETE")
        return 2
    rows = payload.get("candidates") if isinstance(payload, dict) else payload
    if not isinstance(rows, list) or not rows:
        say("harvest --ingest: CANNOT RUN - no candidates array in %s" % a.ingest)
        say("HARVEST-COMPLETE")
        return 2

    families = load_families()
    methods, _unmapped = load_methods()
    pool = read_pool()
    by_slug, by_url = pool_index(pool)
    pub_slugs, _n = published_slugs()
    added, skipped, failed = 0, 0, []
    pacer = Pacer()
    for row in rows:
        url = (row.get("source_url") or row.get("url") or "").strip()
        if not url:
            failed.append("a candidate with no source_url cannot be band-checked")
            continue
        name = (row.get("name") or "").strip()
        dom = domain_of(url)
        body = cached_body(url)
        if body is None:
            pacer.wait(dom)
            body, _net = fetch_through_cache(url)
        if body is None:
            failed.append("%s could not be fetched - not ingested (a candidate we cannot read is not "
                          "a candidate)" % url)
            continue
        node = recipe_jsonld(body)
        if node is not None and node.get("name"):
            name = name or str(node["name"]).strip()
        slug = (row.get("slug") or "").strip() or slugify(name)
        if refuse_entry(slug, url, pub_slugs, by_slug, by_url):
            skipped += 1
            continue
        entry = new_entry(slug, name, url, dom, "ingest")
        entry, _disp = qualify(entry, node, families, methods)
        pool["candidates"].append(entry)
        by_slug[slug] = entry
        by_url[norm_url(url)] = entry
        added += 1
    score_pool(pool)
    # DEDUP BEFORE STORING (Brad 2026-08-27). score_pool has just attached the neighbours this
    # needs and write_pool is the next line, so this is the last moment a near-duplicate can be
    # stopped from entering the pool as a candidate rather than being ruled out of it later.
    refuse_near_dupes(pool)
    write_pool(pool)
    say("harvest --ingest: %d added, %d already known or published, %d refused"
        % (added, skipped, len(failed)))
    for f in failed:
        say("  FINDING  " + f)
    say("HARVEST-COMPLETE")
    return 1 if failed else 0


def cmd_mark_taken(a):
    pool = read_pool(a.pool or POOL)
    by_slug, _ = pool_index(pool)
    c = by_slug.get(a.mark_taken)
    if c is None:
        say("harvest --mark-taken: CANNOT RUN - %s is not in the pool" % a.mark_taken)
        say("HARVEST-COMPLETE")
        return 2
    if c["status"] != "available":
        say("harvest --mark-taken: %s is already '%s' - refusing to re-take it" % (c["slug"], c["status"]))
        say("HARVEST-COMPLETE")
        return 1
    c["status"] = "taken:%s" % (a.run or "unknown-run")
    write_pool(pool, a.pool or POOL)
    say("harvest --mark-taken: %s -> %s" % (c["slug"], c["status"]))
    say("HARVEST-COMPLETE")
    return 0


# =====================================================================================================
# PUBLISHER SOURCING (Brad's ruling 2026-08-24: "build something that can go source new publishers,
# but only when I say and not automatically").
#
# MANUAL BY CONSTRUCTION. This is never called by harvest-crawl.ps1 - that wrapper's own self-test
# asserts its executing region contains no `--probe` - and it is not wired into --crawl. Fetching a
# stranger's site on a timer is how a domain gets BLOCKED, and a blocked publisher costs far more than
# a slow one.
#
# QUALIFYING A PUBLISHER NEEDS NO MODEL. What makes a site usable is entirely mechanical, and the
# source-domains ledger already scores exactly it: does it serve robots.txt, does robots ALLOW us, can
# it be enumerated (sitemap or WP-REST), and do its pages carry the machine-readable Recipe block every
# stage downstream reads. A site with beautiful recipes and no JSON-LD is worth nothing to this
# pipeline; a plain one with clean markup is worth a great deal. Arithmetic, not judgment.
#
# DISCOVERY IS THE ONLY HARD PART, and there are two free roads: --from-cache mines outbound links out
# of pages already fetched (recipe publishers link to each other), and --domains takes a list you hand
# it. Neither needs a model.
#
# NOTHING IS ADMITTED WITHOUT --admit. The ledger's own rule is that a publisher earns enumeration by
# having WORKED, so a probe result is evidence for a decision, never the decision.
# =====================================================================================================

PROBE_INFRA = re.compile(
    r"(facebook|instagram|pinterest|twitter|youtube|tiktok|amazon|amzn|google|gstatic|googleapis|"
    r"w3[.]org|schema[.]org|gmpg|wp[.]com|w[.]org|yoast|adthrive|raptive|scorecardresearch|clarity|"
    r"omappapi|convertkit|mailchi|error-report|html-load|ytimg|bit[.]ly|linktr|cloudflare|jsdelivr|"
    r"shopify|penguinrandomhouse|barnesandnoble|booksamillion|bookshop|indiebound|target[.]com|walmart|"
    r"doubleclick|wordpress|disqus|typekit|fontawesome|cdn|analytics|substack|kit[.]com|memberful|"
    r"samcart|ck[.]page|apple[.]com|microsoft|paypal|stripe)", re.I)
PROBE_FOODY = re.compile(
    r"(recipe|kitchen|cook|eat|food|meal|fit|protein|nutrit|plate|dish|spoon|fork|pan|table|chef|bake|"
    r"delish|yum|savor|nourish|wholesome|lean|prep|skillet|grill|bowl|feast|pantry|supper)", re.I)

PROBE_LINK = re.compile(r"https?://([a-z0-9.-]+[.][a-z]{2,})[/\"']", re.I)


def mine_link_domains(known, cap=40, sample=1200):
    """Candidate publisher domains, mined from pages already in the cache. No network, no model."""
    import random                                                 # noqa: PLC0415
    files = []
    for root, _dirs, names in os.walk(PAGE_CACHE):
        for n in names:
            files.append(os.path.join(root, n))
    if not files:
        return []
    random.seed(11)
    picked = random.sample(files, min(sample, len(files)))
    hits = {}
    for f in picked:
        try:
            with open(f, "r", encoding="utf-8", errors="replace") as fh:
                body = fh.read()
        except Exception:                                         # noqa: BLE001
            continue
        seen = set()
        for m in PROBE_LINK.finditer(body):
            d = m.group(1).lower()
            d = d[4:] if d.startswith("www.") else d
            if d in known or d.count(".") > 2:
                continue
            if PROBE_INFRA.search(d) or not PROBE_FOODY.search(d):
                continue
            seen.add(d)
        for d in seen:
            hits[d] = hits.get(d, 0) + 1
    return [d for d, _n in sorted(hits.items(), key=lambda x: -x[1])][:cap]


def probe_domain(domain, samples=5):
    """Everything that decides whether a publisher is usable, and all of it mechanical."""
    out = {"domain": domain, "robots": False, "allowed": True, "enumerated": 0,
           "sampled": 0, "jsonld": 0, "with_ingredients": 0, "with_nutrition": 0,
           "verdict": "", "why": ""}
    try:
        robots = get_robots(domain)
    except Exception as e:                                        # noqa: BLE001
        out["verdict"] = "UNUSABLE"
        out["why"] = "robots.txt could not be read (%s)" % str(e)[:60]
        return out
    out["robots"] = bool(robots.available)
    try:
        urls = enumerate_domain(domain, robots)
    except Exception as e:                                        # noqa: BLE001
        out["verdict"] = "UNUSABLE"
        out["why"] = "could not enumerate (%s)" % str(e)[:60]
        return out
    out["enumerated"] = len(urls)
    if not urls:
        out["verdict"] = "UNUSABLE"
        out["why"] = "no sitemap and no WP-REST - nothing to enumerate, so the harvester starves"
        return out
    pacer = Pacer()
    for u in urls[:samples]:
        if not robots.allows(u):
            out["allowed"] = False
            continue
        body = cached_body(u)
        if body is None:
            pacer.wait(domain)
            body, _net = fetch_through_cache(u, record=False)
        if body is None:
            continue
        out["sampled"] += 1
        node = recipe_jsonld(body)
        if not node:
            continue
        out["jsonld"] += 1
        if ingredient_lines(node):
            out["with_ingredients"] += 1
        b = read_band(node)
        if b.get("cal") is not None:
            out["with_nutrition"] += 1
    if not out["allowed"] and out["sampled"] == 0:
        out["verdict"] = "UNUSABLE"
        out["why"] = "robots.txt disallows the recipe paths"
        return out
    if out["sampled"] == 0:
        out["verdict"] = "UNUSABLE"
        out["why"] = "no sample page could be fetched"
        return out
    rate = out["with_ingredients"] / float(out["sampled"])
    if rate >= 0.6:
        out["verdict"] = "USABLE"
    elif rate > 0:
        out["verdict"] = "THIN"
    else:
        out["verdict"] = "UNUSABLE"
    out["why"] = ("%d of %d sampled pages carry a Recipe block with ingredients; %d also state nutrition"
                  % (out["with_ingredients"], out["sampled"], out["with_nutrition"]))
    return out


def cmd_probe_domains(a):
    known = set(d.lower() for d in reliable_domains())
    try:
        with open(SOURCE_DOMAINS_JSON, "r", encoding="utf-8-sig") as f:
            known |= set(str(r.get("domain") or "").lower() for r in (json.load(f).get("domains") or []))
    except Exception:                                             # noqa: BLE001
        pass
    if a.domains:
        cands = [d.strip().lower() for d in a.domains.split(",") if d.strip()]
    else:
        cands = mine_link_domains(known)
        say("harvest --probe-domains: mined %d candidate domain(s) from the page cache" % len(cands))
    cands = [d for d in cands if d not in known]
    if not cands:
        say("harvest --probe-domains: no candidate domains to probe (all already in the ledger)")
        say("HARVEST-COMPLETE")
        return 0
    if a.limit:
        cands = cands[:a.limit]
    say("harvest --probe-domains: probing %d, %d sample page(s) each. MANUAL ONLY - never scheduled."
        % (len(cands), a.samples or 5))
    results = []
    for d in cands:
        r = probe_domain(d, samples=a.samples or 5)
        results.append(r)
        say("  %-28s %-9s enum %-6d sampled %d  recipe-block %d  ingredients %d  nutrition %d"
            % (d[:28], r["verdict"], r["enumerated"], r["sampled"], r["jsonld"],
               r["with_ingredients"], r["with_nutrition"]))
        if r["verdict"] != "USABLE":
            say("      %s" % r["why"])
    usable = [r for r in results if r["verdict"] == "USABLE"]
    say("")
    say("  USABLE %d, THIN %d, UNUSABLE %d"
        % (len(usable), len([r for r in results if r["verdict"] == "THIN"]),
           len([r for r in results if r["verdict"] == "UNUSABLE"])))
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            json.dump({"probed": now_stamp(), "results": results}, f, ensure_ascii=False, indent=1)
        say("  wrote %s" % a.out)
    if not a.admit:
        say("  NOTHING ADMITTED. Re-run with --admit to add the USABLE ones to the source-domains "
            "ledger - a probe is evidence for a decision, not the decision.")
    else:
        for r in usable:
            rc, _o = run_ps(SOURCE_DOMAINS_PS, ["-Record", "-Domain", r["domain"], "-Outcome", "ok",
                                                "-HasJsonLd", "-Note",
                                                "admitted by --probe-domains: " + r["why"]], timeout=60)
            say("  admitted %-28s (rc %d)" % (r["domain"], rc))
    say("HARVEST-COMPLETE")
    return 0


def cmd_classify_nutrition(a):
    """Transcribe printed nutrition panels for candidates whose JSON-LD carries none.

    WHY (measured 2026-08-24). 314 available candidates were unverified, and ~60% of them print a
    complete panel in the page TEXT - "Nutrition Serving: 6 ounces | Calories: 255 kcal |
    Carbohydrates: 0 g". The numbers were always there; only the machine-readable block was missing,
    so publishers who render nutrition in HTML were second-class to this pipeline for no reason.

    LOCAL, AND ONLY BECAUSE IT IS TRANSCRIPTION. Section 1.4 lets local transcribe verifiably and
    forbids it to assert. Every number here is proved a substring of the page it came from, the panel's
    own serving basis is captured rather than assumed, and the required set must be COMPLETE - a panel
    missing protein verifies perfectly on what IS there, which is the confident-fragment failure. Where
    a page prints NO panel this writes nothing: computing macros from ingredients would be an
    assertion, and the estate already answers that better with the label-accurate macro recompute.

    REFUSES when llama-server is down, the audit-semantic-identity BLIND pattern: a pass that could not
    reach the model has transcribed nothing, and reporting that as clean is could-not-look-is-not-a-
    clean-bill. Nothing here starts or stops the server (section 4.4).
    """
    import local_extract                                          # noqa: PLC0415
    if not llama_up():
        say("harvest --classify-nutrition: REFUSING - llama-server is not answering at %s." % LLAMA_URL)
        say("  Start it by hand (section 4.4), then run this again. Nothing was written.")
        say("HARVEST-COMPLETE")
        return 2
    pool = read_pool(a.pool or POOL)
    # RE-EVALUATE STORED PANELS TOO, so re-running corrects an earlier verdict rather than skipping
    # what it already touched. Needed the day it shipped: the first full pass marked 129 panels
    # `verified` before `verified` was tightened to mean "one whole serving", and those rows would
    # otherwise have been invisible to every later run.
    for c in pool["candidates"]:
        if not c.get("nutrition_serving"):
            continue
        band = dict(c.get("band") or {})
        whole = local_extract.serving_is_whole(c.get("nutrition_serving"))
        if bool(band.get("verified")) != whole:
            band["verified"] = whole
            band["reason"] = (("transcribed from the page's printed panel (serving: %s)"
                               % str(c.get("nutrition_serving"))[:40]) if whole else
                              ("the page's panel is per %s, not per serving - the numbers are real "
                               "but they are not a serving's" % str(c.get("nutrition_serving"))[:40]))
            c["band"] = band
    targets = [c for c in pool["candidates"]
               if c.get("status") == "available" and not (c.get("band") or {}).get("verified")
               and not c.get("nutrition_serving")]
    if a.limit:
        targets = targets[:a.limit]
    say("harvest --classify-nutrition: %d unverified candidate(s) to try" % len(targets))
    llm = local_extract.LocalLLM(timeout=180)
    read = uncached = nopanel = failed = 0
    for c in targets:
        body = cached_body(c.get("url") or "")
        if body is None:
            uncached += 1
            continue
        text = local_extract.page_text_from_html(body)
        try:
            r = local_extract.read_nutrition(text, llm)
        except Exception as e:                                    # noqa: BLE001
            failed += 1
            if failed <= 3:
                say("  %-44s ERROR %s" % (c["slug"][:44], str(e)[:60]))
            continue
        if not r.get("ok"):
            nopanel += 1
            continue
        band = dict(c.get("band") or {})
        band.update(r["band"])
        c["band"] = band
        c["nutrition_serving"] = r.get("serving")
        read += 1
        if read <= 12:
            say("  %-44s cal %-7s p %-6s c %-6s  serving: %s"
                % (c["slug"][:44], band.get("cal"), band.get("protein_g"), band.get("carbs"),
                   str(r.get("serving"))[:22]))
    if a.dry_run:
        say("  DRY RUN - nothing written")
    else:
        write_pool(pool, a.pool or POOL)
    say("  transcribed %d, no printed panel %d, no cached page %d, errors %d"
        % (read, nopanel, uncached, failed))
    say("HARVEST-COMPLETE")
    return 0


def cmd_reingredients(a):
    """Restore ingredient lines to pooled candidates from the PAGE CACHE. No network, no model.

    WHY THIS EXISTS (2026-08-24). `slim_ruled` strips `ingredients_verbatim` from a ruled entry to keep
    the pool small - correct while the entry is buried. When the ingest band was dropped and 1,555
    band-ruled candidates came back to `available`, they came back WITHOUT their lines, and lines are
    load-bearing: the exclusions filter reads them (a rib recipe whose title hides the cut is caught
    only there), the decider's dossier is built from them, and the mapper's table starts from them.
    Their pages are already in the content-addressed cache, so this is a re-parse, not a re-fetch:
    measured 95% of a 250-candidate sample recoverable.
    """
    pool = read_pool(a.pool or POOL)
    targets = [c for c in pool["candidates"]
               if c.get("status") == "available" and not c.get("ingredients_verbatim")]
    if a.limit:
        targets = targets[:a.limit]
    say("harvest --reingredients: %d available candidate(s) carry no ingredient lines" % len(targets))
    fixed = uncached = nojson = 0
    for c in targets:
        body = cached_body(c.get("url") or "")
        if body is None:
            uncached += 1
            continue
        node = recipe_jsonld(body)
        lines = ingredient_lines(node) if node else []
        if not lines:
            nojson += 1
            continue
        c["ingredients_verbatim"] = lines
        fixed += 1
    if a.dry_run:
        say("  DRY RUN - nothing written")
    else:
        write_pool(pool, a.pool or POOL)
    say("  restored %d, no cached page %d, no JSON-LD ingredients %d" % (fixed, uncached, nojson))
    say("HARVEST-COMPLETE")
    return 0


def cmd_mark_ruled(a):
    pool = read_pool(a.pool or POOL)
    by_slug, _ = pool_index(pool)
    c = by_slug.get(a.mark_ruled)
    if c is None:
        say("harvest --mark-ruled: CANNOT RUN - %s is not in the pool" % a.mark_ruled)
        say("HARVEST-COMPLETE")
        return 2
    if not a.verdict:
        say("harvest --mark-ruled: CANNOT RUN - a ruling needs --verdict")
        say("HARVEST-COMPLETE")
        return 2
    if a.verdict == "deferred":
        # DEFERRED is not a ruling. The decider looked and did not decide, so the candidate goes back
        # on the shelf rather than being buried; burying it would lose a candidate nobody rejected.
        c["status"] = "available"
    else:
        c["status"] = "ruled:%s" % a.verdict
    c["ruled_reason"] = a.reason or ""
    c["ruled_at"] = now_stamp()
    if c["status"].startswith("ruled:"):
        pool["candidates"] = [slim_ruled(x) if x["slug"] == c["slug"] else x
                              for x in pool["candidates"]]
    write_pool(pool, a.pool or POOL)
    say("harvest --mark-ruled: %s -> %s" % (c["slug"], c["status"]))
    say("HARVEST-COMPLETE")
    return 0


def dossier_rank(c):
    """Pop order. Prefers a candidate whose band we can defend, whose region is not already crowded,
    and which no prior ruling has already touched. This is RANKING, not a verdict - nothing is
    auto-rejected by rank, and the decider sees every signal that produced it."""
    band = c.get("band") or {}
    return (
        len(c.get("batch_concerns") or []),      # a likely dinner pops before a likely salad
        0 if band.get("verified") else 1,
        len(c.get("prior_rulings") or []),
        int(c.get("saturation_pressure") or 0),
        -len(c.get("ingredients_verbatim") or []),
        c["slug"],
    )


def catalog_size(digest_path=CATALOG_DIGEST):
    try:
        with open(digest_path, "r", encoding="utf-8-sig") as f:
            return int((json.load(f) or {}).get("recipe_count") or 0)
    except Exception:
        return 0


def dossier_neighbours(neigh, cap=DOSSIER_NEIGHBOUR_CAP):
    """Top `cap` per CHANNEL per SIDE - the bound S2a sets, and the reason it is not a flat slice.

    `neighbours` arrives as word-overlap rows (live only) then bge-m3 live then bge-m3 backlog, each
    already ordered and already capped by score_pool. A flat [:2*cap] cut looks equivalent and is not:
    once the embedding lane carries both sides, the flat cut lands inside the bge-m3 block and drops
    the backlog rows entirely - the same starvation D12 rung 1 just closed, arriving from the other
    end. The dossier's cost per candidate stays CONSTANT in catalog size either way, which is the
    property the cap exists for.
    """
    kept, seen = [], {}
    for x in neigh:
        key = (x.get("source"), x.get("side"))
        if seen.get(key, 0) >= cap:
            continue
        seen[key] = seen.get(key, 0) + 1
        kept.append(x)
    return kept


def build_dossier(c, catalog_n=None):
    sig = c.get("signature") or {}
    band = c.get("band") or {}
    neigh = dossier_neighbours(c.get("neighbours") or [])
    live = [n for n in neigh if n.get("side") == "live-catalog"]
    return {
        "slug": c["slug"], "name": c.get("name"), "url": c.get("url"), "domain": c.get("domain"),
        "signature": {"protein": sig.get("protein"), "method": sig.get("method"),
                      "sauce_family": sig.get("sauce_family"), "starch": sig.get("starch")},
        "band": {"cal": band.get("cal"), "carbs": band.get("carbs"),
                 "protein_g": band.get("protein_g"), "verified": bool(band.get("verified")),
                 "reason": band.get("reason") or ""},
        "servings": c.get("servings"),
        "ingredients_verbatim": (c.get("ingredients_verbatim") or [])[:DOSSIER_INGREDIENT_CAP],
        "neighbours": neigh,
        # An empty neighbour block is ambiguous unless the dossier says the search HAPPENED. Without
        # this, "no neighbours" and "nobody looked" are the same bytes, and a decider that cannot tell
        # them apart will go and read the corpus itself - which is what it did.
        "catalog_checked": {"live_recipes_searched": (catalog_size() if catalog_n is None
                                                      else catalog_n),
                            "live_matches": len(live),
                            "backlog_matches": len(neigh) - len(live)},
        "prior_rulings": c.get("prior_rulings") or [],
        "saturation_pressure": c.get("saturation_pressure") or 0,
        "batch_concerns": c.get("batch_concerns") or [],
        "entered_by": c.get("entered_by"),
    }


def cmd_dossier(a):
    """Pop up to N available candidates and emit their dossiers (section S2: one decider call per <=10
    candidates, dossiers inline at 2-3 KB each). --mark-taken is a SEPARATE act: a dossier that was
    built and never dispatched must not strand its candidates as taken."""
    pool = read_pool()
    avail = [c for c in pool["candidates"] if c.get("status") == "available"]
    if not avail:
        say("harvest --dossier: the pool holds no available candidate")
        say("HARVEST-COMPLETE")
        return 1
    avail.sort(key=dossier_rank)
    if a.slugs:
        # An EXPLICIT set, in the order given. Used to re-issue a dossier for a named batch - a
        # re-measurement after a dossier-contract change has to compare the same candidates, or it is
        # measuring the pop order instead of the change.
        want = [x.strip() for x in a.slugs.split(",") if x.strip()]
        by = {c["slug"]: c for c in avail}
        picked = [by[w] for w in want if w in by]
        missing = [w for w in want if w not in by]
        if missing:
            say("harvest --dossier: %d requested slug(s) are not available: %s"
                % (len(missing), ", ".join(missing)))
    else:
        picked = avail[:max(1, a.count)]
    if not picked:
        say("harvest --dossier: nothing to build a dossier from")
        say("HARVEST-COMPLETE")
        return 1
    catalog_n = catalog_size()
    out = {"generated": now_stamp(), "run": a.run or "", "count": len(picked),
           "signals": {"word_overlap": True, "bge_m3": bool(load_embed_neighbours()),
                       "prior_rulings": True, "saturation": True,
                       "neighbour_sides": "each neighbour is labelled live-catalog or backlog",
                       "live_catalog_recipes": catalog_n},
           "candidates": [build_dossier(c, catalog_n) for c in picked]}
    text = json.dumps(out, indent=1, ensure_ascii=False)
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(text)
        sizes = [len(json.dumps(d, ensure_ascii=False)) for d in out["candidates"]]
        say("harvest --dossier: %d candidate(s) -> %s  (%d-%d bytes each, %.1f KB total)"
            % (len(picked), a.out, min(sizes), max(sizes), len(text) / 1024.0))
    else:
        print(text)
    say("HARVEST-COMPLETE")
    return 0


def cmd_resignature(a):
    """Re-derive signature and band for every candidate FROM THE CACHED PAGE. No network.

    A detector fix is worthless if it only applies to candidates harvested after it. Every page the
    harvester has ever fetched is in fetch-recipe.ps1's cache, so a pool built with a wrong protein
    rule can be corrected without asking a single publisher for anything a second time - which is
    also the only version of this that respects the politeness contract.

    A candidate whose page is no longer in the cache is REPORTED and left exactly as it was: a
    signature we can no longer defend is not one to overwrite with a guess.
    """
    families = load_families()
    methods, unmapped = load_methods()
    pool = read_pool(a.pool or POOL)
    changed, missing, same = 0, 0, 0
    moved = []
    for c in pool["candidates"]:
        if str(c.get("status", "")).startswith("ruled:") and c.get("status") != "ruled:out-of-band":
            continue
        body = cached_body(c.get("url") or "")
        if body is None:
            missing += 1
            continue
        before = json.dumps(c.get("signature") or {}, sort_keys=True)
        node = recipe_jsonld(body)
        entry = dict(c)
        entry["ingredients_verbatim"] = c.get("ingredients_verbatim") or []
        entry["status"] = "available"       # re-qualify from scratch; qualify() rules it again
        entry, _disp = qualify(entry, node, families, methods)
        # Consumption state is NOT re-derived - a candidate a run has taken stays taken.
        if str(c.get("status", "")).startswith("taken:"):
            entry["status"] = c["status"]
        entry["first_seen"] = c.get("first_seen") or entry.get("first_seen")
        entry["entered_by"] = c.get("entered_by") or entry.get("entered_by")
        entry["neighbours"] = c.get("neighbours") or []
        entry["prior_rulings"] = c.get("prior_rulings") or []
        entry["saturation_pressure"] = c.get("saturation_pressure") or 0
        after = json.dumps(entry.get("signature") or {}, sort_keys=True)
        if after != before:
            changed += 1
            if len(moved) < 12:
                moved.append("%s: %s -> %s" % (c["slug"], before, after))
        else:
            same += 1
        c.clear()
        c.update(entry)
    score_pool(pool)
    write_pool(pool, a.pool or POOL)
    say("harvest --resignature: %d re-derived, %d unchanged, %d page(s) no longer cached"
        % (changed, same, missing))
    for m in moved:
        say("  " + m)
    if unmapped:
        say("  FINDING  ledger methods with no detector: %s" % ", ".join(unmapped))
    say("HARVEST-COMPLETE")
    return 1 if (missing or unmapped) else 0


def cmd_rescore(a):
    """Refresh every available candidate's neighbours, prior rulings and saturation pressure without
    fetching anything. Run it after harvest_embed --build (which adds the bge-m3 neighbour source) or
    after the catalog digest is rebuilt, so a dossier never carries a signal older than the ledgers."""
    pool = read_pool(a.pool or POOL)
    n = score_pool(pool)
    if not n:
        say("harvest --rescore: no available candidate to score")
        say("HARVEST-COMPLETE")
        return 1
    # Derived-state hygiene in the same pass: a ruled row written before slim_ruled existed still
    # carries the scoring apparatus it can never use again.
    before = len(json.dumps(pool["candidates"], ensure_ascii=False))
    pool["candidates"] = [slim_ruled(c) for c in pool["candidates"]]
    after = len(json.dumps(pool["candidates"], ensure_ascii=False))
    write_pool(pool, a.pool or POOL)
    say("harvest --rescore: %d candidate(s) rescored" % n)
    if after < before:
        say("  compacted %d ruled row(s): %.0f KB -> %.0f KB"
            % (len([c for c in pool["candidates"] if str(c.get("status","")).startswith("ruled:")]),
               before / 1024.0, after / 1024.0))
    say("HARVEST-COMPLETE")
    return 0


def cmd_status(a):
    pool = read_pool(a.pool or POOL)
    cands = pool["candidates"]
    buckets = {}
    for c in cands:
        k = c.get("status", "?").split(":")[0] + (":" + c["status"].split(":", 1)[1]
                                                  if ":" in c.get("status", "") and
                                                  c["status"].startswith("ruled") else "")
        buckets[k] = buckets.get(k, 0) + 1
    avail = [c for c in cands if c.get("status") == "available"]
    doms = sorted(set(c["domain"] for c in avail))
    verified = [c for c in avail if (c.get("band") or {}).get("verified")]
    if a.json:
        print(json.dumps({"total": len(cands), "available": len(avail),
                          "band_verified": len(verified), "publishers": doms,
                          "by_status": buckets}, indent=1))
    else:
        say("candidate pool: %d entries, %d available (%d band-verified) across %d publisher(s)"
            % (len(cands), len(avail), len(verified), len(doms)))
        for k in sorted(buckets):
            say("  %-28s %d" % (k, buckets[k]))
        for d in doms:
            n = len([c for c in avail if c["domain"] == d])
            say("  publisher %-26s %d available" % (d, n))
    say("HARVEST-COMPLETE")
    return 0


# =====================================================================================================
# self-test - every fixture ships with its must-fire and its clean twin
# =====================================================================================================

def cmd_selftest(_a):
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    # ---- the cache key is fetch-recipe.ps1's, or the estate has two page caches ----------------
    rc, out = run_ps(FETCH_RECIPE_PS, ["-Url", "https://x.com/a", "-BodyPath"], timeout=60)
    ps_key = os.path.basename(out.strip().splitlines()[0]).replace(".html", "") if out.strip() else ""
    T("the page-cache key is byte-identical to fetch-recipe.ps1's Get-UrlKey",
      ps_key == cache_key("https://x.com/a"), "%s vs %s" % (ps_key, cache_key("https://x.com/a")))
    T("MUST FIRE  a fragment does not create a second cache entry",
      cache_key("https://x.com/a#print") == cache_key("https://x.com/a"), "differs")

    # ---- one taxonomy ---------------------------------------------------------------------------
    fams = load_families()
    T("the sauce-family vocabulary is READ from considered-dishes.ps1, not re-typed here",
      len(fams) == 9 and "cream" in fams and "spice" in fams, ",".join(sorted(fams)))
    T("it agrees with Get-Family on the case that names it", family_of("Creamy Tuscan Chicken", fams) == "cream",
      str(family_of("Creamy Tuscan Chicken", fams)))
    T("it agrees with Get-Family on the soy case", family_of("Beef Egg Roll in a Bowl", fams) == "soy",
      str(family_of("Beef Egg Roll in a Bowl", fams)))
    T("MUST FIRE  where Get-Family says 'plain', harvest says null so --classify can fill it",
      family_of("Roast Beef", fams) is None, str(family_of("Roast Beef", fams)))
    meths, unmapped = load_methods()
    T("the method enum is READ from db\\considered-dishes.json's -Method values",
      "skillet" in meths and "casserole" in meths and "any" not in meths, ",".join(meths))
    T("MUST FIRE  a ledger method with no detector is reported, never silently dropped",
      unmapped == [] or all(m not in METHOD_WORDS for m in unmapped), ",".join(unmapped))

    # ---- numbers are extracted, never inferred ---------------------------------------------------
    T("'418 kcal' extracts 418", extract_number("418 kcal") == 418.0, str(extract_number("418 kcal")))
    T("'1,024 calories' extracts 1024", extract_number("1,024 calories") == 1024.0,
      str(extract_number("1,024 calories")))
    T("MUST FIRE  'about four hundred' is None, not 400",
      extract_number("about four hundred") is None, str(extract_number("about four hundred")))
    T("MUST FIRE  a range '400-500' is None - picking an end of it is a guess",
      extract_number("400-500") is None, str(extract_number("400-500")))
    T("yield '8' parses to 8", parse_yield("8") == 8, str(parse_yield("8")))
    T("yield 'makes 8 patties' parses to 8 - one integer is one integer",
      parse_yield("makes 8 patties") == 8, str(parse_yield("makes 8 patties")))
    T("MUST FIRE  yield '6-8' does not parse - the serving basis is ambiguous",
      parse_yield("6-8") is None, str(parse_yield("6-8")))
    T("yield ['8','8 servings'] parses to 8 - one distinct integer",
      parse_yield(["8", "8 servings"]) == 8, str(parse_yield(["8", "8 servings"])))

    # ---- JSON-LD shapes --------------------------------------------------------------------------
    html = ('<html><head><script type="application/ld+json">'
            '{"@graph":[{"@type":"WebSite"},{"@type":"Recipe","name":"Deep"}]}'
            '</script></head><body>prose</body></html>')
    T("MUST FIRE  the Recipe node is found inside @graph (the common WordPress shape)",
      (recipe_jsonld(html) or {}).get("name") == "Deep", str(recipe_jsonld(html)))
    T("CLEAN TWIN a page with no JSON-LD yields no node, and must not crash",
      recipe_jsonld("<html><body>nothing</body></html>") is None, "found one")
    T("MUST FIRE  an HTML entity in a recipeIngredient line is unescaped - `raw` is what is PRINTED",
      ingredient_lines({"recipeIngredient": ["4 oz. cream cheese (softened &amp; cut into cubes)"]})
      == ["4 oz. cream cheese (softened & cut into cubes)"],
      str(ingredient_lines({"recipeIngredient": ["4 oz. cream cheese (softened &amp; cut into cubes)"]})))
    T("  and a non-breaking space collapses like any other whitespace",
      ingredient_lines({"recipeIngredient": ["1/2&nbsp;cup milk"]}) == ["1/2 cup milk"],
      str(ingredient_lines({"recipeIngredient": ["1/2&nbsp;cup milk"]})))
    T("CLEAN TWIN a line with no entity is untouched",
      ingredient_lines({"recipeIngredient": ["2 cups rice"]}) == ["2 cups rice"])
    T("instructions are unescaped too - the same escaping, the same page",
      flatten_instructions(["Stir the beef &amp; onions."]) == ["Stir the beef & onions."],
      str(flatten_instructions(["Stir the beef &amp; onions."])))
    steps = flatten_instructions([{"@type": "HowToSection", "itemListElement": [
        {"@type": "HowToStep", "text": "Sear the pork"}, {"@type": "HowToStep", "text": "Bake it"}]}])
    T("HowToSection/HowToStep flatten into the ordered string list (section 4.5)",
      steps == ["Sear the pork", "Bake it"], str(steps))

    # ---- the band filter -------------------------------------------------------------------------
    def node(cal, carbs, yld="8", name="Creamy Tuscan Chicken Skillet", ings=None):
        return {"@type": "Recipe", "name": name, "recipeYield": yld,
                "nutrition": {"@type": "NutritionInformation", "calories": cal,
                              "carbohydrateContent": carbs, "proteinContent": "41 g"},
                # THE DEFAULT FIXTURE MUST CLEAR THE ROUND'S CUT AND CARB GATES, or every band case
                # below stops testing the band and starts testing detect_round_cut instead. It used
                # to be chicken THIGHS with no starch, which the 2026-08-27 filters reject - 13 band
                # cases went red for a reason that had nothing to do with the band. Breast + rice is
                # the minimum conforming dinner; the cut and carb gates get their own cases below.
                "recipeIngredient": ings or ["2 lb boneless skinless chicken breast", "2 cups rice",
                                             "1 cup heavy cream", "2 tbsp olive oil"],
                "recipeInstructions": ["Sear the chicken in a skillet.", "Simmer in the cream."]}

    e, disp = qualify(new_entry("x", "X", "https://d/x", "d", "crawl"), node("512 kcal", "9 g"),
                      fams, meths)
    T("CLEAN TWIN an in-band page is available with its numbers recorded",
      disp == "in-band" and e["status"] == "available" and e["band"]["cal"] == 512
      and e["band"]["verified"], "%s %s %s" % (disp, e["status"], e["band"]))
    T("its signature is protein x method x sauce-family x starch",
      e["signature"] == {"protein": "chicken", "method": "skillet", "sauce_family": "cream",
                         "starch": "rice"}, json.dumps(e["signature"]))

    # CHANGED 2026-08-24 (Brad: drop the ingest band). harvest RECORDS what the page says; the RUN
    # decides what is acceptable. This was the last place a second, hidden band survived - it buried
    # 1,556 candidates, 64% of the pool, against hard-coded constants no run had asked for.
    e2, disp2 = qualify(new_entry("y", "Y", "https://d/y", "d", "crawl"), node("980 kcal", "9 g"),
                        fams, meths)
    T("MUST FIRE  a 980-cal page is RECORDED and left AVAILABLE - ingest does not bury it, the run rules",
      disp2 != "out-of-band" and e2["status"] == "available" and e2["band"]["cal"] == 980,
      "%s %s" % (disp2, e2["status"]))
    T("CLEAN TWIN ...and it keeps the scoring apparatus, because it is a candidate now",
      "neighbours" in e2 and "ingredients_verbatim" in e2, ",".join(sorted(e2)))
    # THE MACHINERY IS NOT DELETED, only defaulted off: asked for a band, ingest still filters and
    # still slims the ruled entry down to the numbers that ruled it.
    e2f, disp2f = qualify(new_entry("yf", "Yf", "https://d/yf", "d", "crawl"), node("980 kcal", "9 g"),
                          fams, meths, band_at_ingest=True)
    T("MUST FIRE  band_at_ingest=True still filters, and a ruled entry keeps its numbers and loses the apparatus",
      disp2f == "out-of-band" and e2f["status"] == "ruled:out-of-band" and e2f["band"]["cal"] == 980
      and "neighbours" not in e2f and "ingredients_verbatim" not in e2f,
      "%s %s %s" % (disp2f, e2f["status"], ",".join(sorted(e2f))))
    T("CLEAN TWIN an AVAILABLE entry keeps all of it - it is about to become a dossier",
      "neighbours" in e and "ingredients_verbatim" in e and len(e["ingredients_verbatim"]) == 4
      and e.get("round_cut") == "chicken breast" and e.get("meets_round_band") is True,
      ",".join(sorted(e)))
    e2b, disp2b = qualify(new_entry("y2", "Y2", "https://d/y2", "d", "crawl"), node("512 kcal", "61 g"),
                          fams, meths)
    T("MUST FIRE  a 61 g carb page is RECORDED and available - the carb figure is kept for the run to rule on",
      disp2b != "out-of-band" and e2b["status"] == "available" and e2b["band"]["carbs"] == 61,
      "%s %s" % (disp2b, e2b["band"]))
    e2c, _ = qualify(new_entry("y3", "Y3", "https://d/y3", "d", "crawl"), node("400 kcal", "35 g"),
                     fams, meths)
    T("CLEAN TWIN the band is INCLUSIVE on both edges (400 cal / 35 g carbs is in)",
      e2c["status"] == "available", e2c["status"])

    e3, disp3 = qualify(new_entry("z", "Z", "https://d/z", "d", "crawl"),
                        {"@type": "Recipe", "name": "Z", "recipeYield": "8",
                         # conforming cut + carb source, so this case tests the missing NUTRITION
                         # block rather than the round filters that run before it
                         "recipeIngredient": ["2 lb ground beef", "3 cups rice"]}, fams, meths)
    # ---- THE ROUND'S CUT AND CARB GATES (Brad's ruling 2026-08-27) -----------------------------
    # Two HARD filters, because both are facts about the ingredient list that we read ourselves.
    # The band beside them stays a TAG - that asymmetry is the whole design and each half is pinned.
    def rc(ings, name="Dish"):
        return detect_round_cut(ings, name)
    T("MUST FIRE  each of the four allowed cuts is recognised as the main protein",
      rc(["2 lb boneless skinless chicken breast", "rice"]) == "chicken breast"
      and rc(["1 lb ground beef", "pasta"]) == "ground beef"
      and rc(["2 lb pork tenderloin", "potatoes"]) == "pork loin"
      and rc(["1 lb ground turkey", "tortillas"]) == "ground turkey",
      "|".join(str(rc(x)) for x in (["2 lb boneless skinless chicken breast"], ["1 lb ground beef"],
                                    ["2 lb pork tenderloin"], ["1 lb ground turkey"])))
    T("MUST FIRE  a DISQUALIFYING cut is refused even though its family is allowed - thighs are not breast",
      rc(["4 bone-in chicken thighs", "rice"]) is None and rc(["1 lb flank steak", "rice"]) is None
      and rc(["2 lb pork shoulder", "rice"]) is None,
      "thigh=%s steak=%s shoulder=%s" % (rc(["4 bone-in chicken thighs"]), rc(["1 lb flank steak"]),
                                         rc(["2 lb pork shoulder"])))
    T("MUST FIRE  TWO allowed cuts in one recipe is not a main protein, so it is refused",
      rc(["1 lb ground beef", "2 chicken breasts", "rice"]) is None,
      str(rc(["1 lb ground beef", "2 chicken breasts", "rice"])))
    e_cut, disp_cut = qualify(new_entry("c1", "C1", "https://d/c1", "d", "crawl"),
                              node("512 kcal", "9 g", ings=["4 bone-in chicken thighs", "2 cups rice"]),
                              fams, meths)
    T("MUST FIRE  a wrong-cut page is RULED, not available - and its band is still recorded as memory",
      disp_cut == "not-fit-cut" and e_cut["status"] == "ruled:rejected-not-fit"
      and e_cut["band"]["cal"] == 512,
      "%s %s %s" % (disp_cut, e_cut["status"], e_cut.get("band")))
    e_ns, disp_ns = qualify(new_entry("c2", "C2", "https://d/c2", "d", "crawl"),
                            node("512 kcal", "9 g", ings=["2 lb boneless skinless chicken breast",
                                                          "2 tbsp olive oil"]),
                            fams, meths)
    T("MUST FIRE  a conforming cut with NO carb source is refused - a cooked protein is not a meal",
      disp_ns == "not-fit-nostarch" and e_ns["status"] == "ruled:rejected-not-fit",
      "%s %s" % (disp_ns, e_ns["status"]))
    # THE BAND IS TAGGED, NEVER ENFORCED. This is the half that honours the 2026-08-24 ruling.
    e_hi, disp_hi = qualify(new_entry("c3", "C3", "https://d/c3", "d", "crawl"),
                            node("980 kcal", "9 g"), fams, meths)
    T("MUST FIRE  a conforming dinner OUTSIDE the round band stays AVAILABLE and is merely tagged - "
      "an unreliable publisher figure must never bury a candidate",
      e_hi["status"] == "available" and e_hi.get("meets_round_band") is False,
      "%s meets=%s" % (e_hi["status"], e_hi.get("meets_round_band")))
    T("CLEAN TWIN a conforming dinner INSIDE the round band is tagged True",
      e.get("meets_round_band") is True, str(e.get("meets_round_band")))
    e_nb, disp_nb = qualify(new_entry("c4", "C4", "https://d/c4", "d", "crawl"),
                            {"@type": "Recipe", "name": "C4", "recipeYield": "8",
                             "recipeIngredient": ["2 lb ground turkey", "3 cups rice"]}, fams, meths)
    T("CLEAN TWIN no nutrition panel means the round-band tag is None, never a guess",
      e_nb.get("meets_round_band") is None, str(e_nb.get("meets_round_band")))

    T("MUST FIRE  a page with no nutrition block is KEPT, flagged band-unverified",
      disp3 == "band-unverified" and e3["status"] == "available" and not e3["band"]["verified"],
      "%s %s" % (disp3, e3["status"]))
    T("  and it says WHY, so the decider is not guessing",
      "nutrition" in (e3["band"]["reason"] or ""), e3["band"]["reason"])

    e4, disp4 = qualify(new_entry("w", "W", "https://d/w", "d", "crawl"), node("512 kcal", "9 g", "6-8"),
                        fams, meths)
    T("MUST FIRE  an ambiguous serving basis (yield '6-8') demotes to band-unverified, never a guess",
      disp4 == "band-unverified" and e4["status"] == "available", "%s %s" % (disp4, e4["status"]))
    e5, disp5 = qualify(new_entry("v", "V", "https://d/v", "d", "crawl"), node("3200 kcal", "60 g"),
                        fams, meths)
    T("MUST FIRE  a per-RECIPE nutrition block (3200 cal/serving) demotes rather than filtering out",
      disp5 == "band-unverified" and e5["status"] == "available", "%s %s" % (disp5, e5["status"]))
    T("  and it names the per-recipe suspicion", "per-RECIPE" in e5["band"]["reason"],
      e5["band"]["reason"])

    # ---- exclusions ------------------------------------------------------------------------------
    e6, disp6 = qualify(new_entry("s", "S", "https://d/s", "d", "crawl"),
                        node("512 kcal", "9 g", "8", "Garlic Butter Shrimp",
                             ["1 lb shrimp", "3 tbsp butter"]), fams, meths)
    T("MUST FIRE  a seafood dish is ruled out on its ingredient nouns",
      disp6 == "excluded" and e6["status"] == "ruled:excluded", "%s %s" % (disp6, e6["status"]))
    T("CLEAN TWIN worcestershire's anchovy does not make a pot roast seafood",
      exclusions(["2 lb chuck roast", "2 tbsp worcestershire sauce (anchovy)"]) == [],
      str(exclusions(["2 lb chuck roast", "2 tbsp worcestershire sauce (anchovy)"])))
    T("MUST FIRE  ground chicken is a standing board exclusion",
      exclusions(["1 lb ground chicken"]) != [], "not excluded")

    # ---- IMAGE ATTACHMENT PAGES (Brad's ruling 2026-08-24) -----------------------------------------
    # FROZEN FIXTURE. WordPress mints a page per uploaded image and sitemaps list them. MEASURED on the
    # live pool: 187 of the 280 available candidates with no JSON-LD block were these - 67% - each one
    # already paid for out of a 60-a-day politeness budget, and each one poppable in front of a paid
    # decider once the band came off. They are not recipes and never can be.
    T("MUST FIRE  a WordPress image attachment page is not a recipe URL",
      is_image_page("https://d/baked-pork-chops-2-jpg/"), "not detected")
    T("MUST FIRE  ...and the other shapes the sitemaps actually served",
      (is_image_page("https://d/chicken-stir-fry-chop-suey-5-landscape-jpg/")
       and is_image_page("https://d/close-up-of-baked-pork-chops-with-potato-jpg")
       and is_image_page("https://d/photo-1200x628/")
       and is_image_page("https://d/hero.jpg")),
      "one of the four measured shapes was missed")
    # THE OVER-REJECTION TWINS. Matching a bare "jpg" or any digit anywhere would take real recipes.
    T("CLEAN TWIN a recipe slug carrying DIGITS is not an image page",
      not is_image_page("https://d/5-ingredient-chili/"), "excluded a real recipe")
    T("CLEAN TWIN and neither are the real recipes this drill actually wanted",
      (not is_image_page("https://d/chicken-tinga-tacos/")
       and not is_image_page("https://d/one-pot-sausage-meatball-pasta/")
       and not is_image_page("https://d/creamy-tuscan-chicken-pasta-bake/")),
      "excluded a real recipe")

    # ---- RIB CUTS (Brad's ruling 2026-08-24, after the 6b proving run) -----------------------------
    # FROZEN FIXTURE. 6b paid for `beef-back-ribs` through map, registrar AND pricing before the
    # pre-write band gate retired it at 41.6 g protein against a 50 g floor. Rib racks cannot reach a
    # high-protein floor inside the same band's calorie ceiling, so the class does not enter.
    #
    # THE NAME IS LOAD-BEARING AND THIS IS THE FIXTURE THAT PROVES IT: the pool held ZERO ingredient
    # lines for that very candidate (254 of 661 available candidates carry none), so an
    # ingredient-only filter could not have fired on the recipe that motivated the rule.
    T("MUST FIRE  a rib recipe with NO ingredient lines is excluded on its NAME - the pool held no "
      "lines for beef-back-ribs, so an ingredient-only filter would have missed the motivating case",
      exclusions([], "Beef Back Ribs") != [], "not excluded")
    T("MUST FIRE  a GENERIC rib title is excluded - the phrase list missed 'Fall-Apart Oven Baked "
      "Ribs' and it was accepted at 723 cal into hunt-2026-08-26-smoke2 on 2026-08-26",
      exclusions([], "Fall-Apart Oven Baked Ribs with Chipotle BBQ Sauce") != [], "not excluded")
    T("MUST FIRE  ...and so is 'Oven Pork Ribs with Barbecue Sauce', which sat available at 814 cal",
      exclusions([], "Oven Pork Ribs with Barbecue Sauce") != [], "not excluded")
    T("CLEAN TWIN a RIBEYE is still not a rib rack - the exemption the bare-substring trap was written "
      "to protect survives the plural",
      exclusions([], "Reverse Sear Ribeye Steak") == [], "wrongly excluded")
    T("CLEAN TWIN and PRIME RIB is still not a rib rack either",
      exclusions([], "Prime Rib Roast") == [], "wrongly excluded")
    T("MUST FIRE  ...and the ingredient side still catches ribs a title does not advertise",
      exclusions(["14 lb beef back ribs (about 3 1/2 racks)"], "Mystery Dinner") != [], "not excluded")
    T("MUST FIRE  three more rack cuts, because a collection fixture takes at least three",
      (exclusions([], "Slow Cooker Baby Back Ribs") != []
       and exclusions(["3 lb boneless beef short ribs"], "Braised Beef") != []
       and exclusions(["2 lb pork spare ribs"], "Grill Night") != []),
      "one of baby back / short ribs / spare ribs was not excluded")
    # The over-rejection twins. A bare "rib" substring would take these with the racks, which is the
    # silent-over-rejection class this file's own comments warn about.
    T("CLEAN TWIN a ribeye is NOT a rib rack - different cut, different fat and yield",
      exclusions(["2 lb ribeye steak"], "Garlic Butter Ribeye") == [],
      str(exclusions(["2 lb ribeye steak"], "Garlic Butter Ribeye")))
    T("CLEAN TWIN prime rib is not excluded either",
      exclusions([], "Prime Rib Roast") == [], str(exclusions([], "Prime Rib Roast")))
    T("CLEAN TWIN and an ordinary beef dinner is untouched",
      exclusions(["2 lb beef chuck roast"], "Pot Roast") == [],
      str(exclusions(["2 lb beef chuck roast"], "Pot Roast")))
    # SEAFOOD STAYS INGREDIENT-ONLY. Its job is catching a dinner whose title hides the fish; a
    # title-side seafood match would take "Chicken Puttanesca" with it.
    T("CLEAN TWIN the name side is RIBS-ONLY - a seafood title with no seafood ingredient is not excluded",
      exclusions([], "Shrimp Scampi") == [], str(exclusions([], "Shrimp Scampi")))

    # ---- protein / method ordering ----------------------------------------------------------------
    T("MUST FIRE  'ground turkey' reads as turkey, not as an accidental beef",
      detect_protein(["1 lb ground turkey", "1 cup beef broth"]) == "turkey",
      detect_protein(["1 lb ground turkey", "1 cup beef broth"]))
    T("MUST FIRE  'chicken sausage' reads as sausage, the more specific claim",
      detect_protein(["12 oz chicken sausage"]) == "sausage", detect_protein(["12 oz chicken sausage"]))
    T("MUST FIRE  casserole beats bake when the page says both",
      detect_method("Cheesy Beef Casserole", ["Bake in the oven 30 minutes"], meths) == "casserole",
      detect_method("Cheesy Beef Casserole", ["Bake in the oven 30 minutes"], meths))
    T("CLEAN TWIN a page with no method word is 'any', not a guess",
      detect_method("Something", ["Combine and serve"], meths) == "any",
      detect_method("Something", ["Combine and serve"], meths))

    # THE THREE SIGNATURE DEFECTS THE FIRST REAL DOSSIER BATCH EXPOSED (2026-08-23). Every one of them
    # was invisible to a synthetic fixture and obvious the moment 20 live pages were laid out side by
    # side, which is the argument for looking at real output before trusting a green suite.
    T("MUST FIRE  beef broth does not make a chicken dish beef (Chicken Madeira read as BEEF)",
      detect_protein(["4 chicken breasts", "1 cup beef broth", "8 oz mushrooms"]) == "chicken",
      detect_protein(["4 chicken breasts", "1 cup beef broth", "8 oz mushrooms"]))
    T("MUST FIRE  bacon does not make a chicken dish pork (Jalapeno Popper Chicken read as PORK)",
      detect_protein(["4 chicken breasts", "6 slices bacon", "8 oz cream cheese"]) == "chicken",
      detect_protein(["4 chicken breasts", "6 slices bacon", "8 oz cream cheese"]))
    T("CLEAN TWIN a dish whose only meat IS bacon still reads pork",
      detect_protein(["1 lb bacon", "6 eggs"]) == "pork",
      detect_protein(["1 lb bacon", "6 eggs"]))
    T("CLEAN TWIN a real pork chop dinner is pork even beside chicken broth",
      detect_protein(["4 bone-in pork chops", "1 cup chicken broth"]) == "pork",
      detect_protein(["4 bone-in pork chops", "1 cup chicken broth"]))
    T("MUST FIRE  the title names the dinner when the ingredients back it up "
      "(Chicken and Stuffing Casserole read as SAUSAGE, from the sausage in its stuffing)",
      detect_protein(["3 cups cooked chicken", "1 lb italian sausage", "1 box stuffing mix"],
                     "Chicken and Stuffing Casserole") == "chicken",
      detect_protein(["3 cups cooked chicken", "1 lb italian sausage", "1 box stuffing mix"],
                     "Chicken and Stuffing Casserole"))
    T("MUST FIRE  a title the ingredients do NOT back up is ignored (Chicken Fried Steak is beef)",
      detect_protein(["4 cube steaks", "2 cups buttermilk", "flour"], "Chicken Fried Steak") == "beef",
      detect_protein(["4 cube steaks", "2 cups buttermilk", "flour"], "Chicken Fried Steak"))
    T("CLEAN TWIN bacon in a TITLE is a topping, not the dinner",
      detect_protein(["4 chicken breasts", "6 slices bacon"], "Bacon Ranch Chicken") == "chicken",
      detect_protein(["4 chicken breasts", "6 slices bacon"], "Bacon Ranch Chicken"))
    T("MUST FIRE  chili POWDER is a spice, not a stew (a breakfast taco read as STEW)",
      detect_method("Mexican Breakfast Tacos", ["Season with 1 tsp chili powder and fry"], meths)
      != "stew",
      detect_method("Mexican Breakfast Tacos", ["Season with 1 tsp chili powder and fry"], meths))
    T("CLEAN TWIN an actual chili is still a stew",
      detect_method("Beef Chili", ["Simmer the chili 45 minutes"], meths) == "stew",
      detect_method("Beef Chili", ["Simmer the chili 45 minutes"], meths))
    T("MUST FIRE  the TITLE outweighs a vessel word buried in the instructions",
      detect_method("Chicken Stew", ["Brown in a dutch oven, then simmer"], meths) == "stew",
      detect_method("Chicken Stew", ["Brown in a dutch oven, then simmer"], meths))
    T("MUST FIRE  a title naming TWO methods falls to precedence, not to the body's word count",
      detect_method("Baked Gnocchi Casserole",
                    ["Pour into a baking dish", "Bake 25 minutes", "Return to the baking dish"],
                    meths) == "casserole",
      detect_method("Baked Gnocchi Casserole",
                    ["Pour into a baking dish", "Bake 25 minutes"], meths))
    T("CLEAN TWIN a silent title still lets the instructions speak",
      detect_method("Grandma's Sunday Dinner", ["Braise in a dutch oven for 3 hours"], meths)
      == "braised",
      detect_method("Grandma's Sunday Dinner", ["Braise in a dutch oven for 3 hours"], meths))
    T("MUST FIRE  breadcrumbs are a binder, not a bread starch (Swedish meatballs read starch=bread)",
      detect_starch(["1 lb ground turkey", "1/2 cup breadcrumbs", "1 egg"]) == "none",
      detect_starch(["1 lb ground turkey", "1/2 cup breadcrumbs", "1 egg"]))
    T("CLEAN TWIN actual bread on the plate still reads as a starch",
      detect_starch(["1 lb beef", "8 slices sourdough bread"]) == "bread",
      detect_starch(["1 lb beef", "8 slices sourdough bread"]))

    # ---- politeness -------------------------------------------------------------------------------
    r = Robots("d.com", "User-agent: *\nDisallow: /wp-admin/\nAllow: /wp-admin/admin-ajax.php\n"
                        "Sitemap: https://d.com/sitemap_index.xml\n")
    T("MUST FIRE  a robots.txt Disallow is honoured", not r.allows("https://d.com/wp-admin/x"), "allowed")
    T("a longer Allow beats a shorter Disallow", r.allows("https://d.com/wp-admin/admin-ajax.php"),
      "denied")
    T("CLEAN TWIN an unlisted path is allowed", r.allows("https://d.com/creamy-tuscan-chicken/"), "denied")
    T("robots.txt's own Sitemap line is used as the enumeration seed",
      r.sitemaps == ["https://d.com/sitemap_index.xml"], str(r.sitemaps))
    r2 = Robots("d.com", "User-agent: BadBot\nDisallow: /\n")
    T("CLEAN TWIN a Disallow aimed at another agent does not apply to us",
      r2.allows("https://d.com/anything"), "denied")

    clock = {"t": 100.0}
    slept = []
    pc = Pacer(2.0, 4.0, clock=lambda: clock["t"],
               sleeper=lambda s: (slept.append(s), clock.__setitem__("t", clock["t"] + s)),
               jitter=lambda: 3.0)
    pc.wait("a.com")
    pc.wait("a.com")
    T("MUST FIRE  two requests to one domain are paced at least 2 s apart",
      len(slept) == 1 and slept[0] >= 2.0, str(slept))
    pc.wait("b.com")
    T("CLEAN TWIN a different domain does not wait behind the first",
      len(slept) == 1, str(slept))

    st = {"days": {"2026-08-23": {"d.com": 59}}}
    T("the nightly cap leaves room at 59 of 60", nightly_room(st, "d.com", 60, "2026-08-23") == 1, "no")
    note_fetch(st, "d.com", "2026-08-23")
    T("MUST FIRE  the nightly cap stops the 61st fetch",
      nightly_room(st, "d.com", 60, "2026-08-23") == 0,
      str(nightly_room(st, "d.com", 60, "2026-08-23")))

    # ---- the pool's single-writer rules -------------------------------------------------------------
    tmp = os.path.join(os.environ.get("TEMP", "."), "harvest-selftest-%d.json" % os.getpid())
    try:
        pub, _n = published_slugs()
        T("the published-slug guard has a catalog to check against (blind is not clean)",
          len(pub) > 400, str(len(pub)))
        live = sorted(pub)[0]
        p = {"candidates": []}
        p["candidates"].append(new_entry("some-new-dish", "Some New Dish", "https://d/a", "d", "crawl"))
        write_pool(p, tmp)
        bs, bu = pool_index(read_pool(tmp))
        T("MUST FIRE  an already-published slug is refused entry to the pool",
          refuse_entry(live, "https://d/new", pub, bs, bu) == "already published",
          str(refuse_entry(live, "https://d/new", pub, bs, bu)))
        T("MUST FIRE  a slug already in the pool is refused a second entry",
          refuse_entry("some-new-dish", "https://d/other", pub, bs, bu) == "already in the pool",
          str(refuse_entry("some-new-dish", "https://d/other", pub, bs, bu)))
        T("MUST FIRE  the same URL under a new name is refused - one page, one candidate",
          refuse_entry("renamed", "https://d/a", pub, bs, bu) is not None,
          str(refuse_entry("renamed", "https://d/a", pub, bs, bu)))
        T("CLEAN TWIN a genuinely new slug on a new URL is admitted",
          refuse_entry("brand-new-thing", "https://d/z", pub, bs, bu) is None,
          str(refuse_entry("brand-new-thing", "https://d/z", pub, bs, bu)))

        p2 = read_pool(tmp)
        p2["candidates"][0]["status"] = "ruled:rejected-dupe"
        write_pool(p2, tmp)
        p3 = read_pool(tmp)
        avail = [c for c in p3["candidates"] if c["status"] == "available"]
        T("MUST FIRE  a ruled candidate never resurfaces as available", len(avail) == 0,
          str([c["status"] for c in p3["candidates"]]))
        T("the pool round-trips through an atomic write", len(p3["candidates"]) == 1,
          str(len(p3["candidates"])))
    finally:
        for suffix in ("", ".tmp"):
            try:
                os.remove(tmp + suffix)
            except OSError:
                pass

    # ---- --ingest gets the SAME treatment as a crawl ------------------------------------------------
    ing = new_entry("i", "I", "https://d/i", "d", "ingest")
    ing, dispi = qualify(ing, node("980 kcal", "9 g"), fams, meths)
    T("MUST FIRE  an --ingest candidate gets exactly the crawl treatment - recorded, not buried",
      dispi != "out-of-band" and ing["status"] == "available" and ing["entered_by"] == "ingest",
      "%s %s %s" % (dispi, ing["status"], ing["entered_by"]))
    ing2, dispi2 = qualify(new_entry("i2", "I2", "https://d/i2", "d", "ingest"), node("512 kcal", "9 g"),
                           fams, meths)
    T("CLEAN TWIN and it gets the same signature treatment",
      ing2["signature"]["sauce_family"] == "cream" and dispi2 == "in-band",
      json.dumps(ing2["signature"]))

    # ---- the dossier -------------------------------------------------------------------------------
    ing2["neighbours"] = [
        {"slug": "live-twin", "name": "Live Twin", "score": 20, "shared": ["creamy"],
         "source": "word-overlap", "side": "live-catalog"},
        {"slug": "backlog-twin", "name": "Backlog Twin", "score": 0.95, "shared": [],
         "source": "bge-m3", "side": "backlog"}]
    d = build_dossier(ing2, catalog_n=544)
    size = len(json.dumps(d, ensure_ascii=False))
    T("MUST FIRE  every neighbour says whether it is LIVE or BACKLOG - they are different questions",
      all(n.get("side") in ("live-catalog", "backlog") for n in d["neighbours"]),
      json.dumps(d["neighbours"]))
    T("MUST FIRE  the dossier states the catalog WAS searched, so an empty block is evidence of "
      "absence rather than absence of evidence",
      d["catalog_checked"]["live_recipes_searched"] == 544
      and d["catalog_checked"]["live_matches"] == 1
      and d["catalog_checked"]["backlog_matches"] == 1, json.dumps(d["catalog_checked"]))
    T("CLEAN TWIN a candidate with no neighbours still reports the search",
      build_dossier(ing, catalog_n=544)["catalog_checked"]["live_recipes_searched"] == 544,
      "search not reported")
    # ---- D12 rung 1: the dossier's cap is per CHANNEL per SIDE, never a flat cut ------------------
    many = ([{"source": "word-overlap", "side": "live-catalog", "slug": "w%d" % i} for i in range(5)]
            + [{"source": "bge-m3", "side": "live-catalog", "slug": "l%d" % i} for i in range(5)]
            + [{"source": "bge-m3", "side": "backlog", "slug": "b%d" % i} for i in range(5)])
    T("MUST FIRE  a flat 2xCAP cut lands inside the bge-m3 block and throws the whole backlog side "
      "away - the starvation arriving from the other end",
      not [x for x in many[:2 * DOSSIER_NEIGHBOUR_CAP] if x["side"] == "backlog"],
      str([x["slug"] for x in many[:2 * DOSSIER_NEIGHBOUR_CAP]]))
    kept = dossier_neighbours(many)
    T("MUST FIRE  the per-channel-per-side cap keeps all three blocks whole",
      len([x for x in kept if x["source"] == "word-overlap"]) == 5
      and len([x for x in kept if x["source"] == "bge-m3" and x["side"] == "live-catalog"]) == 5
      and len([x for x in kept if x["source"] == "bge-m3" and x["side"] == "backlog"]) == 5,
      str(len(kept)))
    T("CLEAN TWIN and it is still BOUNDED - the decider's cost per candidate stays constant in "
      "catalog size, which is what the cap is for",
      len(dossier_neighbours(many * 4)) == 15, str(len(dossier_neighbours(many * 4))))
    # THROUGH THE DOSSIER ITSELF, not just the helper. A guard on the rule that leaves the call site
    # unwatched is how a fixed function ends up beside an unfixed caller.
    wide = build_dossier({"slug": "wide", "name": "Wide", "neighbours": many}, catalog_n=1)
    T("MUST FIRE  the dossier a decider actually receives carries all three blocks - the backlog "
      "side is not what falls off the end",
      len([x for x in wide["neighbours"] if x["side"] == "backlog"]) == 5,
      str([x["slug"] for x in wide["neighbours"]]))
    T("and its catalog_checked counts what the dossier SHIPS, not what was scored",
      wide["catalog_checked"]["live_matches"] == 10
      and wide["catalog_checked"]["backlog_matches"] == 5,
      json.dumps(wide["catalog_checked"]))

    T("a dossier carries signature, band, neighbours, prior rulings and saturation",
      set(["signature", "band", "neighbours", "prior_rulings", "saturation_pressure"]).issubset(d),
      ",".join(sorted(d)))
    T("MUST FIRE  a dossier stays inside the 2-3 KB budget section S2 sets", size <= 3072, str(size))
    # AND THE REAL ONE, MEASURED. The fixture above runs on a two-neighbour candidate, so it can pass
    # while a real dossier does not - the trap where an agreeing number escapes scrutiny. D12 rung 1
    # fills every block: 5 word-overlap + 5 bge-m3 live + 5 bge-m3 backlog, each carrying its evidence.
    # MEASURED 2026-08-26 over the rescored live pool, 10 popped dossiers: 3,524-4,153 bytes, against
    # 2,603-3,118 for the same ten in the pre-D12 shape. So section S2's "2-3 KB each" line is no
    # longer true of a full dossier, and this estate does not leave a stale budget standing as a
    # guard: the assertion below bounds GROWTH at 1.5x the measured worst case - it catches an
    # unbounded neighbour block, and it does not pretend 4 KB is 3 KB.
    full = build_dossier({"slug": "full", "name": "A Fairly Long Candidate Dish Name Bowls",
                          "url": "https://example.com/" + "x" * 60, "domain": "example.com",
                          "signature": {"protein": "chicken", "method": "skillet"},
                          "ingredients_verbatim": ["1 1/2 lbs boneless skinless chicken thighs, "
                                                   "cut into bite-sized pieces"] * 22,
                          "neighbours": [{"slug": "neighbour-slug-%d" % i,
                                          "name": "Some Live Catalog Recipe Name %d" % i,
                                          "score": 0.9123, "shared": ["chicken", "skillet"],
                                          "shared_items": ["chicken-breast", "heavy-cream"],
                                          "source": s, "side": d}
                                         for s, d in (("word-overlap", "live-catalog"),
                                                      ("bge-m3", "live-catalog"),
                                                      ("bge-m3", "backlog"))
                                         for i in range(5)]}, catalog_n=562)
    full_size = len(json.dumps(full, ensure_ascii=False))
    # The measured size goes in the `got` field, never in the assertion NAME: a name that carries a
    # number changes every run, and the name set is the instrument that catches a vanished case.
    T("MUST FIRE  a FULL dossier - every channel and side at cap - stays bounded",
      full_size <= 6144, "%d bytes" % full_size)
    ranked = sorted([{"slug": "b", "band": {"verified": False}, "prior_rulings": [],
                      "saturation_pressure": 0, "ingredients_verbatim": []},
                     {"slug": "a", "band": {"verified": True}, "prior_rulings": [],
                      "saturation_pressure": 0, "ingredients_verbatim": []}], key=dossier_rank)
    T("MUST FIRE  a band-verified candidate ranks above a band-unverified one",
      ranked[0]["slug"] == "a", ranked[0]["slug"])

    # ---- batch-scalability: a FLAG that demotes, never a filter that rejects --------------------
    T("MUST FIRE  a cold salad is flagged", "cold-plate" in batch_concerns("Autumn Kale and Apple Salad"),
      str(batch_concerns("Autumn Kale and Apple Salad")))
    T("MUST FIRE  a wrap is flagged", "cold-plate" in batch_concerns("Chicken Caesar Wraps"),
      str(batch_concerns("Chicken Caesar Wraps")))
    T("MUST FIRE  a breakfast dish is flagged",
      "breakfast" in batch_concerns("Mexican Breakfast Tacos (Chorizo and Egg)"),
      str(batch_concerns("Mexican Breakfast Tacos (Chorizo and Egg)")))
    T("MUST FIRE  deep-frying to order is flagged",
      "cook-to-order" in batch_concerns("Katsu", ["Deep fry each cutlet just before serving"]),
      str(batch_concerns("Katsu", ["Deep fry each cutlet just before serving"])))
    T("CLEAN TWIN a plain batch dinner carries no concern",
      batch_concerns("Creamy Tuscan Chicken Skillet", ["Sear the chicken", "Simmer in cream"]) == [],
      str(batch_concerns("Creamy Tuscan Chicken Skillet", ["Sear"])))
    T("MUST FIRE  a flagged candidate is DEMOTED in the pop order, not removed",
      [x["slug"] for x in sorted(
          [{"slug": "salad", "band": {"verified": True}, "prior_rulings": [], "saturation_pressure": 0,
            "ingredients_verbatim": [], "batch_concerns": ["cold-plate"]},
           {"slug": "dinner", "band": {"verified": True}, "prior_rulings": [], "saturation_pressure": 0,
            "ingredients_verbatim": [], "batch_concerns": []}], key=dossier_rank)] == ["dinner", "salad"],
      "ordering wrong")
    T("MUST FIRE  and it is still POPPABLE - a flag is not a rejection",
      dossier_rank({"slug": "salad", "band": {"verified": True}, "prior_rulings": [],
                    "saturation_pressure": 0, "ingredients_verbatim": [],
                    "batch_concerns": ["cold-plate"]}) is not None, "removed")

    # ================================================================================================
    # D12 RUNG 1 - THE INGREDIENT CHANNEL, PLUGGED IN.
    # ================================================================================================
    verbatim = ["2 boneless, skinless chicken breasts (about 1.5 lbs, $4.20)",
                "1 cup heavy cream ($1.20)", "1/2 cup sun-dried tomatoes, chopped",
                "2 Tbsp butter", "2 cups fresh spinach", "salt and pepper to taste"]
    iw = ingredient_words(verbatim)
    T("MUST FIRE  the ingredient words carry the nouns the board's ids are built from",
      set(["chicken", "breasts", "heavy", "cream", "sun", "dried", "tomatoes", "spinach",
           "butter"]).issubset(iw), ",".join(iw))
    T("MUST FIRE  and they drop the measure, the price and the prep verb - none of which is a food",
      not (set(["cup", "cups", "tbsp", "lbs", "about", "chopped", "taste"]) & set(iw)), ",".join(iw))
    T("a parenthetical is dropped whole, so a publisher's cost note never becomes an ingredient",
      "4.20" not in iw and "1.5" not in iw, ",".join(iw))
    T("CLEAN TWIN no ingredient lines yields no words - which is exactly what score_pool sent for "
      "every candidate it has ever scored, and why the shared-items bonus never fired",
      ingredient_words([]) == [] and ingredient_words(None) == [], str(ingredient_words([])))

    # END TO END, through the real find-similar process and the LIVE digest: harvest.py's words in,
    # named ingredient evidence out. The two halves of this contract live in different languages and
    # this is the only fixture that proves they meet.
    if os.path.exists(CATALOG_DIGEST) and os.path.exists(FIND_SIMILAR_PS):
        twin_pool = {"candidates": [{
            "slug": "fixture-date-night-skillet", "name": "Date Night Skillet", "status": "available",
            "signature": {"protein": "chicken", "method": "skillet"},
            "ingredients_verbatim": verbatim}]}
        score_pool(twin_pool, quiet=True)
        nb = twin_pool["candidates"][0].get("neighbours") or []
        twin = [x for x in nb if x.get("slug") == "creamy-tuscan-chicken-skillet"]
        T("MUST FIRE  a composition duplicate under a disjoint name reaches the dossier through the "
          "real lane, not just through Get-Score",
          len(twin) == 1 and not twin[0].get("shared"),
          ",".join(x.get("slug") or "?" for x in nb))
        T("MUST FIRE  and its ingredient evidence is NAMED in the neighbour row",
          bool(twin) and "heavy-cream" in (twin[0].get("shared_items") or []),
          json.dumps(twin[0].get("shared_items") if twin else None))

    # ================================================================================================
    # D12 RUNG 2 - THE CALIBRATION IS READ, AND ITS ABSENCE IS BLIND.
    # ================================================================================================
    rec, why = load_similarity_calibration(path=os.path.join(HERE, "no-such-calibration.json"))
    T("MUST FIRE  a missing calibration is a REASON, never a default distribution",
      rec is None and "no calibration at" in why, why)
    if os.path.exists(CALIBRATION_FILE) and os.path.exists(CATALOG_DIGEST):
        rec, why = load_similarity_calibration()
        T("the emitted calibration reads back clean against the digest on disk", rec is not None, why)
        if rec:
            T("MUST FIRE  the threshold READ from the corpus sits above its own p99 - two published "
              "recipes must never read as duplicates of each other",
              float(rec["dupe_threshold"]) > float(rec["p99"]),
              "%s vs %s" % (rec["dupe_threshold"], rec["p99"]))
            T("the distribution names its corpus and its size, so a number in a dossier can be traced",
              int(rec["n"]) > 0 and (rec.get("generated_from") or {}).get("recipe_count"),
              json.dumps(rec.get("generated_from")))
        # STALE IS BLIND TOO. Same file, a digest it was not computed from.
        import tempfile as _tf
        fd, other = _tf.mkstemp(suffix=".json")
        os.close(fd)
        try:
            with open(other, "w", encoding="utf-8") as f:
                json.dump({"recipe_count": 1, "by_protein": {}}, f)
            rec2, why2 = load_similarity_calibration(digest_path=other)
            T("MUST FIRE  a calibration that does not match the digest on disk is STALE, and stale "
              "is could-not-look",
              rec2 is None and "STALE" in why2, why2)
        finally:
            try:
                os.remove(other)
            except OSError:
                pass

    # ---- llama-server refusal ------------------------------------------------------------------------
    T("MUST FIRE  --classify's health probe is a real probe, not an assumption",
      llama_up("http://127.0.0.1:1", timeout=1) is False, "claimed up")

    print("")
    if bad:
        print("harvest SELF-TEST FAIL (%d)" % len(bad))
        print("HARVEST-COMPLETE")
        return 2
    print("harvest SELF-TEST PASS")
    print("HARVEST-COMPLETE")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True, description="the v3 harvest plane")
    ap.add_argument("--crawl", action="store_true")
    ap.add_argument("--classify", action="store_true")
    ap.add_argument("--ingest", default="")
    ap.add_argument("--mark-taken", dest="mark_taken", default="")
    ap.add_argument("--mark-ruled", dest="mark_ruled", default="")
    ap.add_argument("--dossier", action="store_true")
    ap.add_argument("--status", action="store_true")
    ap.add_argument("--rescore", action="store_true")
    ap.add_argument("--calibration", action="store_true",
                    help="report the corpus similarity calibration (harvest_embed --calibrate "
                         "writes it). Exit 2 - BLIND - when it is missing or stale against the "
                         "digest; there is no default threshold.")
    ap.add_argument("--classify-nutrition", dest="classify_nutrition", action="store_true",
                    help="transcribe printed nutrition panels for candidates whose JSON-LD has "
                         "none. Needs llama-server; every number is proved against the page.")
    ap.add_argument("--probe-domains", dest="probe_domains", action="store_true",
                    help="MANUAL ONLY. Probe candidate publisher domains mechanically - robots, "
                         "enumeration, and whether their pages carry a usable recipe block. "
                         "Never scheduled and never called by the crawl.")
    ap.add_argument("--admit", action="store_true",
                    help="with --probe-domains: add the USABLE ones to the source-domains ledger")
    ap.add_argument("--samples", type=int, default=5)
    ap.add_argument("--reingredients", action="store_true",
                    help="restore ingredient lines to available candidates from the page cache. "
                         "No network and no model - a re-parse of pages already fetched.")
    ap.add_argument("--resignature", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--run", default="")
    ap.add_argument("--verdict", default="")
    ap.add_argument("--reason", default="")
    ap.add_argument("--count", type=int, default=10)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--per-domain", dest="per_domain", type=int, default=0)
    ap.add_argument("--domains", default="")
    ap.add_argument("--out", default="")
    ap.add_argument("--slugs", default="")
    # --pool exists so the end-to-end drills (decide_apply, and D9's daemon fixtures) can exercise the
    # real single-writer verbs against a scratch pool. Nothing that touches the live pool passes it.
    ap.add_argument("--pool", default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--dry-run", dest="dry_run", action="store_true")
    a = ap.parse_args(argv)

    if a.selftest:
        return cmd_selftest(a)
    if a.crawl:
        return cmd_crawl(a)
    if a.classify:
        return cmd_classify(a)
    if a.ingest:
        return cmd_ingest(a)
    if a.mark_taken:
        return cmd_mark_taken(a)
    if a.mark_ruled:
        return cmd_mark_ruled(a)
    if a.dossier:
        return cmd_dossier(a)
    if a.resignature:
        return cmd_resignature(a)
    if a.classify_nutrition:
        return cmd_classify_nutrition(a)
    if a.probe_domains:
        return cmd_probe_domains(a)
    if a.reingredients:
        return cmd_reingredients(a)
    if a.rescore:
        return cmd_rescore(a)
    if a.calibration:
        return cmd_calibration(a)
    if a.status:
        return cmd_status(a)
    ap.print_help()
    print("HARVEST-COMPLETE")
    return 2


if __name__ == "__main__":
    sys.exit(main())
