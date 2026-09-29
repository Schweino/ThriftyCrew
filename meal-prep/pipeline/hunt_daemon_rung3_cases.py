"""hunt_daemon_rung3_cases.py - the extract lane's rung-3 and page-snapshot fixtures, split out of
hunt_daemon_selftest.py (2026-09-29) so the battery stays under its line mark
(ops/audit-file-size-budget.ps1). They run INSIDE the battery, which calls each case with itself as
`H` for its helpers (daemon, FakeDispatch, arun, scratch_dir). Not a suite of its own.

The rung-3 cases are the battery's own, moved verbatim. The two page-snapshot cases are W6 of
design/PLAN-eval-heldout-and-hillclimb-2026-09-29.md: every extraction saves the page it read.
"""
from __future__ import annotations

import json
import os
import shutil

class _Battery:
    """The battery's globals, read at CALL time: bind() runs near the top of the battery, before the
    helpers below it are defined, and however the battery was loaded (as __main__ or by importlib)."""

    def __init__(self, g):
        self._g = g

    def __getattr__(self, name):
        return self._g[name]


H = None   # bound by bind() before any case runs


def bind(battery_globals):
    global H
    H = _Battery(battery_globals)


def rung3_daemon(tmp, returned):
    """Drive rung 3 directly against a written escalation file."""
    import harvest                                               # noqa: PLC0415
    os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
    esc = os.path.join(tmp, "extracted", "p1.escalation.json")
    with open(esc, "w", encoding="utf-8") as f:
        json.dump({"state": "escalate", "reason": "one line failed", "title": "P One",
                   "source_url": "https://d/p", "ingredients": [], "instructions": [],
                   "escalate": True, "escalate_reason": "one line failed"}, f)
    fd = H.FakeDispatch({"recipe-hunter-extractor": [returned]})
    d = H.daemon(run_dir=tmp, dispatcher=fd)
    real = harvest.cached_body
    # The page states the line WITH INLINE TAGS, which is the whole point: it substring-matches the
    # stripped text and never matches raw markup.
    harvest.cached_body = lambda u, cache_dir=None: (
        "<html><body><li>1 lb <strong>chicken</strong> thighs</li>"
        "<li>2 cups rice</li></body></html>")
    try:
        H.arun(d.rung3("p1"))
    finally:
        harvest.cached_body = real
    return d, esc


def rung3_verifies_stripped_text():
    tmp = H.scratch_dir(prefix="daemon-rung3-")
    try:
        d, _esc = rung3_daemon(tmp, {
            "state": "ok", "title": "P One", "servings": 4,
            "ingredients": [{"raw": "1 lb chicken thighs", "item": "chicken thighs"},
                            {"raw": "2 cups rice", "item": "rice"}],
            "instructions": ["Cook."], "concerns": []})
        with open(os.path.join(tmp, "extracted", "p1.json"), "r", encoding="utf-8") as f:
            doc = json.load(f)
        v = doc.get("verification") or {}
        return (doc.get("extracted_by") == "claude" and v.get("verified") == 2
                and v.get("unverified") == 0 and v.get("passed") is True,
                json.dumps(v))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def rung3_cleans_up():
    tmp = H.scratch_dir(prefix="daemon-rung3b-")
    try:
        d, esc = rung3_daemon(tmp, {
            "state": "ok", "title": "P One",
            "ingredients": [{"raw": "1 lb chicken thighs", "item": "chicken thighs"},
                            {"raw": "2 cups rice", "item": "rice"}],
            "instructions": ["Cook."], "concerns": []})
        return (not os.path.exists(esc) and os.path.exists(os.path.join(tmp, "extracted", "p1.json")),
                "the escalation file survived a settle" if os.path.exists(esc)
                else "no settled file was written")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def rung3_records_not_gates():
    tmp = H.scratch_dir(prefix="daemon-rung3c-")
    try:
        d, esc = rung3_daemon(tmp, {
            "state": "ok", "title": "P One",
            "ingredients": [{"raw": "1 lb chicken thighs", "item": "chicken thighs"},
                            {"raw": "3 tablespoons invented sauce", "item": "invented sauce"}],
            "instructions": ["Cook."], "concerns": []})
        p = os.path.join(tmp, "extracted", "p1.json")
        with open(p, "r", encoding="utf-8") as f:
            doc = json.load(f)
        concerns = " ".join(doc.get("concerns") or [])
        return (os.path.exists(p) and not os.path.exists(esc)
                and doc["verification"]["unverified"] == 1 and "verified only" in concerns,
                "concerns=%s verification=%s" % (concerns[:120], json.dumps(doc["verification"])))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def rung3_saves_its_page():
    import extract_sweep                                         # noqa: PLC0415
    import hashlib                                               # noqa: PLC0415
    tmp = H.scratch_dir(prefix="daemon-rung3d-")
    try:
        d, _esc = rung3_daemon(tmp, {
            "state": "ok", "title": "P One",
            "ingredients": [{"raw": "1 lb chicken thighs", "item": "chicken thighs"},
                            {"raw": "2 cups rice", "item": "rice"}],
            "instructions": ["Cook."], "concerns": []})
        with open(os.path.join(tmp, "extracted", "p1.json"), "r", encoding="utf-8") as f:
            doc = json.load(f)
        page = ("<html><body><li>1 lb <strong>chicken</strong> thighs</li>"
                "<li>2 cups rice</li></body></html>")
        want = hashlib.sha256(page.encode("utf-8")).hexdigest()
        snap = doc.get("page_snapshot") or {}
        return (snap.get("sha256") == want and extract_sweep.snapshot_problem(doc) is None
                and not any("not saved" in x for x in d.findings),
                "snapshot=%s problem=%s" % (json.dumps(snap), extract_sweep.snapshot_problem(doc)))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def local_settle_saves_its_page():
    """The daemon's own extract lane, one page, fake ladder: the contract names a saved page, the
    file is under the suite's seam, and nothing new appears under the checkout's real cache."""
    import extract_sweep                                         # noqa: PLC0415
    import harvest                                               # noqa: PLC0415
    tmp = H.scratch_dir(prefix="daemon-snap-local-")
    real_dir = os.path.join(harvest.PAGE_CACHE, extract_sweep.SNAPSHOT_SUBDIR)
    real_before = sorted(os.listdir(real_dir)) if os.path.isdir(real_dir) else []
    try:
        os.makedirs(os.path.join(tmp, "extracted"), exist_ok=True)
        d = H.daemon(run_dir=tmp, dispatcher=H.FakeDispatch({}))
        d.ch["extract"].push({"slug": "p1", "url": "https://d/p1", "name": "P One"})
        d.ch["extract"].close()

        class OneLadder:
            allow_rung2 = True

            def slot_ctx(self):
                return 16384

            def rung1(self, html, url):
                return {"extraction": {"usable": True, "unusable_reason": None, "title": "P One",
                                       "servings": 4, "total_time": None, "active_time": None,
                                       "ingredients": [{"raw": "1 lb chicken", "item": "chicken",
                                                        "qty": "1", "unit": "lb", "prep": None,
                                                        "optional": False, "section": None}],
                                       "instructions": ["Cook."]},
                        "verification": {"lines": 1, "verified": 1, "unverified": 0,
                                         "verified_rate": 1.0, "unverified_lines": [],
                                         "passed": True},
                        "model": "fake", "tokens": 0, "rung": 1, "extracted_by": "jsonld-local",
                        "escalate": False, "escalate_reason": None}

            def rung2(self, html, url):
                return None, "unused"

        real = harvest.cached_body
        harvest.cached_body = lambda u, cache_dir=None: "<html><body>1 lb chicken</body></html>"
        try:
            H.arun(d.extract_lane(ladder=OneLadder()))
        finally:
            harvest.cached_body = real
        p = os.path.join(tmp, "extracted", "p1.json")
        doc = json.load(open(p, encoding="utf-8")) if os.path.exists(p) else {}
        real_after = sorted(os.listdir(real_dir)) if os.path.isdir(real_dir) else []
        return (bool((doc.get("page_snapshot") or {}).get("sha256"))
                and extract_sweep.snapshot_problem(doc) is None
                and real_after == real_before
                and not any("not saved" in x for x in d.findings),
                "doc=%s real-cache %d -> %d findings=%s"
                % (json.dumps(doc.get("page_snapshot")), len(real_before), len(real_after),
                   d.findings[:3]))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
