r"""seo_search_console.py - what Google actually did with our pages, recorded over time.

    python ops/seo_search_console.py            # pull yesterday's window, append to history
    python ops/seo_search_console.py --report   # read the history back, no network
    python ops/seo_search_console.py --selftest # hermetic

WHY THIS EXISTS (2026-09-07, backlog I24's open half). `ops/audit-seo-surface.py` measures the
surface we CONTROL - one distinct recipe image across 584 recipes, 49 of them empty. It cannot say
whether any of that costs us a reader, because nothing here has ever recorded Google's response. So
every SEO claim this estate has made is unfalsifiable, and "we fixed the images" would have to be
believed rather than checked.

THE PROPERTY IS SETTLED AND IS NOT GUESSED HERE (backlog I25, closed): `https://www.thriftycrew.com/`
as a URL-prefix property, owned by schweino68@gmail.com, verified 2026-08-31. Three files used to
name three different owning accounts; the memory `seo-baseline-2026-08-31` is the authority.

NO NEW DEPENDENCIES, DELIBERATELY. google-auth and googleapiclient are not installed and this estate
has a standing problem with adding runtimes. A service-account token is an RS256 JWT and a form POST,
both of which `cryptography` and `requests` already do, so the whole exchange is forty lines instead
of a package tree.

A MISSING CREDENTIAL IS BLIND, NEVER CLEAN. Until the key exists this exits 3 and says so. "No SEO
data" and "SEO data showing nothing" must never print the same, which is the failure this whole item
is about.

WHAT IT REFUSES TO SAY. The property was verified on 2026-08-31 and Search Console keeps no data from
before a property existed, so the series starts there - and Google's own reporting lags two to three
days. A trend over four points is not a trend, so `--report` states the window and the row count
beside every number and refuses a direction under MIN_DAYS. `.claude/rules/measurement.md`.

Exit 0 = pulled or reported. 2 = the API refused us. 3 = no credential, or nothing to report.
"""
from __future__ import annotations

import argparse
import base64
import datetime
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, ".."))
KEY_FILE = os.path.join(HERE, ".gsc-key.json")
HISTORY = os.path.join(HERE, "seo-search-console-history.jsonl")

SITE = "https://www.thriftycrew.com/"
SCOPE = "https://www.googleapis.com/auth/webmasters.readonly"
TOKEN_URL = "https://oauth2.googleapis.com/token"

EXIT_CLEAN, EXIT_FINDING, EXIT_CANNOT_RUN = 0, 2, 3

# Google's reporting lags; asking for yesterday returns a hole that is not a fall in traffic.
LAG_DAYS = 3
# Below this many recorded days, no direction is stated. Four points is not a trend.
MIN_DAYS = 14


def _b64u(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode("ascii")


def claim_set(client_email: str, now: int, scope: str = SCOPE, ttl: int = 3600) -> dict:
    """The JWT payload a service account exchanges for an access token.

    Pure so the fixtures can check it without a key: `aud` must be the token endpoint and not the
    API, and `exp` must be inside an hour - Google rejects a longer one, and the failure reads as an
    authentication problem rather than as the clock arithmetic it is.
    """
    return {"iss": client_email, "scope": scope, "aud": TOKEN_URL,
            "iat": now, "exp": now + min(ttl, 3600)}


def query_body(start: str, end: str, dimensions=None, row_limit: int = 25) -> dict:
    """The searchAnalytics request. Pure, so the date window is checkable without spending a call."""
    return {"startDate": start, "endDate": end,
            "dimensions": list(dimensions or []), "rowLimit": row_limit,
            "dataState": "final"}


def window(today: datetime.date, days: int = 28, lag: int = LAG_DAYS):
    """(start, end) as ISO dates, ending LAG days back.

    Ending at yesterday is the obvious choice and it is wrong: Search Console finalises two to three
    days late, so the newest day is a hole that reads as a collapse in traffic.
    """
    end = today - datetime.timedelta(days=lag)
    return (end - datetime.timedelta(days=days - 1)).isoformat(), end.isoformat()


def totals_from(rows) -> dict:
    """Fold API rows into one record. Position is IMPRESSION-WEIGHTED, not a mean of means.

    Averaging the per-row averages is the obvious move and it silently weights a page with three
    impressions the same as one with three thousand.
    """
    clicks = sum(int(r.get("clicks", 0)) for r in rows)
    imps = sum(int(r.get("impressions", 0)) for r in rows)
    wpos = sum(float(r.get("position", 0)) * int(r.get("impressions", 0)) for r in rows)
    return {"clicks": clicks, "impressions": imps,
            "ctr": round(clicks / imps, 5) if imps else None,
            "position": round(wpos / imps, 2) if imps else None,
            "rows": len(rows)}


def judge_trend(history, min_days: int = MIN_DAYS) -> dict:
    """A direction, or an honest refusal to state one.

    Compares the newest record against the oldest. Deliberately says how many records that is over,
    because "position improved" over three days is noise wearing a verdict's clothes.
    """
    n = len(history)
    if n < min_days:
        return {"verdict": "too-few-days", "n": n,
                "line": ("%d recorded day(s), under the %d needed to state a direction. The property "
                         "was verified 2026-08-31, so the series cannot be longer than the days "
                         "since." % (n, min_days))}
    first, last = history[0], history[-1]
    fp, lp = first.get("position"), last.get("position")
    if fp is None or lp is None:
        return {"verdict": "no-position", "n": n,
                "line": "%d day(s) recorded, but a record carries no position to compare." % n}
    # Position is a RANK: lower is better, and reading it the other way is the classic error here.
    d = round(lp - fp, 2)
    v = "improved" if d < 0 else ("worsened" if d > 0 else "held")
    return {"verdict": v, "n": n, "delta": d,
            "line": ("average position %s from %.2f to %.2f (%+.2f) over %d recorded day(s); "
                     "impressions %d -> %d. Lower is better."
                     % (v, fp, lp, d, n, first.get("impressions", 0), last.get("impressions", 0)))}


def load_history(path=None):
    rows = []
    try:
        with io.open(path or HISTORY, encoding="utf-8-sig") as f:
            for ln in f:
                ln = ln.strip()
                if ln:
                    try:
                        rows.append(json.loads(ln))
                    except Exception:                              # noqa: BLE001
                        continue
    except OSError:
        return []
    return rows


# --------------------------------------------------------------------------- network half
def access_token(key: dict) -> str:
    """Sign the claim set with the service account's private key and trade it for a token."""
    import requests                                                # noqa: PLC0415
    from cryptography.hazmat.primitives import hashes, serialization        # noqa: PLC0415
    from cryptography.hazmat.primitives.asymmetric import padding           # noqa: PLC0415

    now = int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    header = _b64u(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
    payload = _b64u(json.dumps(claim_set(key["client_email"], now)).encode())
    signing_input = (header + "." + payload).encode()
    pk = serialization.load_pem_private_key(key["private_key"].encode(), password=None)
    sig = pk.sign(signing_input, padding.PKCS1v15(), hashes.SHA256())
    assertion = header + "." + payload + "." + _b64u(sig)
    r = requests.post(TOKEN_URL, timeout=30, data={
        "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion})
    r.raise_for_status()
    return r.json()["access_token"]


def search_analytics(token: str, body: dict) -> dict:
    import requests                                                # noqa: PLC0415
    import urllib.parse                                            # noqa: PLC0415
    url = ("https://searchconsole.googleapis.com/webmasters/v3/sites/%s/searchAnalytics/query"
           % urllib.parse.quote(SITE, safe=""))
    r = requests.post(url, timeout=60, json=body,
                      headers={"Authorization": "Bearer " + token})
    if r.status_code == 403:
        raise RuntimeError(
            "403 from Search Console. The credential is valid but the service account is not a user "
            "on %s. In Search Console: Settings -> Users and permissions -> Add user -> the service "
            "account's client_email, Full or Restricted." % SITE)
    r.raise_for_status()
    return r.json()


# --------------------------------------------------------------------------- self-test
def selftest():
    bad = []

    def T(name, ok, got=""):
        if ok:
            print("  ok    " + name)
        else:
            print("  X     %s   got: %s" % (name, got))
            bad.append(name)

    print("seo_search_console self-test")
    print("")

    c = claim_set("svc@proj.iam.gserviceaccount.com", 1000)
    T("MUST FIRE  the JWT audience is the TOKEN endpoint, not the API - the commonest way this fails, "
      "and it reads as an auth problem rather than a wrong field",
      c["aud"] == TOKEN_URL, c["aud"])
    T("MUST FIRE  the assertion never asks for more than an hour, which Google refuses outright",
      c["exp"] - c["iat"] <= 3600, str(c["exp"] - c["iat"]))
    T("MUST FIRE  the scope is READ-ONLY - this account must never be able to change the property",
      c["scope"].endswith("webmasters.readonly"), c["scope"])

    w = window(datetime.date(2026, 9, 7), days=28)
    T("MUST FIRE  THE LAG - the window ends 3 days back, because asking for yesterday returns a hole "
      "that reads exactly like a collapse in traffic",
      w[1] == "2026-09-04", str(w))
    T("MUST FIRE  a 28-day window is 28 days inclusive", w[0] == "2026-08-08", str(w))

    rows = [{"clicks": 1, "impressions": 3, "position": 90.0},
            {"clicks": 9, "impressions": 3000, "position": 10.0}]
    t = totals_from(rows)
    T("MUST FIRE  average position is IMPRESSION-WEIGHTED - a page with 3 impressions must not count "
      "as much as one with 3,000",
      t["position"] == 10.08, str(t["position"]))
    T("MUST NOT FIRE  clicks and impressions are plain sums", (t["clicks"], t["impressions"]) == (10, 3003), str(t))
    T("MUST NOT FIRE  zero impressions yields no CTR and no position rather than a division by zero",
      totals_from([])["position"] is None and totals_from([])["ctr"] is None, str(totals_from([])))

    T("MUST NOT FIRE  THE MEASUREMENT RULE - four days is not a trend and no direction is stated",
      judge_trend([{"position": 50.0}] * 4)["verdict"] == "too-few-days",
      judge_trend([{"position": 50.0}] * 4)["line"])
    hist = [{"position": 50.0, "impressions": 100}] + [{"position": 45.0, "impressions": 120}] * 14
    T("MUST FIRE  POSITION IS A RANK - falling from 50 to 45 is an IMPROVEMENT, and reading it the "
      "other way is the classic error with this metric",
      judge_trend(hist)["verdict"] == "improved", judge_trend(hist)["line"])
    worse = [{"position": 40.0, "impressions": 100}] + [{"position": 60.0, "impressions": 90}] * 14
    T("MUST FIRE  a rising position number is a WORSENING", judge_trend(worse)["verdict"] == "worsened",
      judge_trend(worse)["line"])
    T("MUST NOT FIRE  a record with no position refuses rather than treating the gap as zero",
      judge_trend([{"impressions": 1}] * 20)["verdict"] == "no-position",
      judge_trend([{"impressions": 1}] * 20)["line"])

    b = query_body("2026-08-08", "2026-09-04", ["query"], 25)
    T("CLEAN TWIN the request carries the window it was asked for", (b["startDate"], b["endDate"]) == ("2026-08-08", "2026-09-04"), json.dumps(b))
    T("CLEAN TWIN dataState is final, so a partial day cannot enter the series",
      b["dataState"] == "final", b["dataState"])
    T("CLEAN TWIN a missing history file reads as no days, not as a crash",
      load_history(os.path.join(HERE, "no-such-history.jsonl")) == [], "threw or invented rows")
    T("CLEAN TWIN the trend line always carries the day count beside the direction",
      "over 15 recorded day(s)" in judge_trend(hist)["line"], judge_trend(hist)["line"])

    if bad:
        print("")
        print("SELF-TEST FAIL: %d check(s)" % len(bad))
        print("SEO-SEARCH-CONSOLE-SELFTEST-COMPLETE")
        return 1
    print("")
    print("SELF-TEST PASS: 8 must-fire cases led by the reporting lag and by position being a RANK, "
          "3 must-not-fire cases, and 4 clean twins")
    print("SEO-SEARCH-CONSOLE-SELFTEST-COMPLETE")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Search Console series for thriftycrew.com")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--report", action="store_true", help="read the history back, no network")
    ap.add_argument("--days", type=int, default=28)
    a = ap.parse_args()
    if a.selftest:
        return selftest()

    if a.report:
        hist = load_history()
        if not hist:
            print("SEO SEARCH CONSOLE BLIND: no history recorded yet, so there is nothing to report. "
                  "That is not 'no traffic' - it is 'never measured'.")
            print("SEO-SEARCH-CONSOLE-COMPLETE blind=no-history")
            return EXIT_CANNOT_RUN
        for r in hist[-10:]:
            print("  %s  clicks %-6s impressions %-8s ctr %-8s position %s"
                  % (r.get("pulled_at", "?")[:10], r.get("clicks"), r.get("impressions"),
                     r.get("ctr"), r.get("position")))
        print("")
        print("  " + judge_trend(hist)["line"])
        print("SEO-SEARCH-CONSOLE-COMPLETE days=%d" % len(hist))
        return EXIT_CLEAN

    raw = os.environ.get("GSC_KEY_JSON") or ""
    key = None
    if raw:
        try:
            key = json.loads(raw)
        except Exception:                                          # noqa: BLE001
            key = None
    elif os.path.exists(KEY_FILE):
        try:
            with io.open(KEY_FILE, encoding="utf-8-sig") as f:
                key = json.load(f)
        except Exception:                                          # noqa: BLE001
            key = None
    if not key or not key.get("client_email") or not key.get("private_key"):
        print("SEO SEARCH CONSOLE BLIND: no service-account credential, so Google's response to our "
              "pages has NOT been measured. This is the honest state, not a clean one.")
        print("  Put the service-account JSON at ops\\.gsc-key.json (gitignored) or in $GSC_KEY_JSON,")
        print("  and add its client_email as a user on %s in Search Console." % SITE)
        print("SEO-SEARCH-CONSOLE-COMPLETE blind=no-credential")
        return EXIT_CANNOT_RUN

    start, end = window(datetime.date.today(), days=a.days)
    try:
        tok = access_token(key)
        overall = totals_from(search_analytics(tok, query_body(start, end, [], 1)).get("rows", []))
        queries = search_analytics(tok, query_body(start, end, ["query"], 25)).get("rows", [])
        pages = search_analytics(tok, query_body(start, end, ["page"], 25)).get("rows", [])
    except Exception as e:                                         # noqa: BLE001
        print("SEO SEARCH CONSOLE REFUSED: %s" % e)
        print("SEO-SEARCH-CONSOLE-COMPLETE refused=1")
        return EXIT_FINDING

    rec = dict(overall)
    rec.update({"pulled_at": datetime.datetime.now().isoformat(timespec="seconds"),
                "site": SITE, "start": start, "end": end, "days": a.days,
                "top_queries": [{"q": (r.get("keys") or [""])[0], "clicks": r.get("clicks"),
                                 "impressions": r.get("impressions"),
                                 "position": round(float(r.get("position", 0)), 2)} for r in queries[:25]],
                "top_pages": [{"p": (r.get("keys") or [""])[0], "clicks": r.get("clicks"),
                               "impressions": r.get("impressions"),
                               "position": round(float(r.get("position", 0)), 2)} for r in pages[:25]]})
    with io.open(HISTORY, "a", encoding="utf-8", newline="\n") as f:
        f.write(json.dumps(rec) + "\n")

    print("  window %s .. %s (ends %d day(s) back: Search Console finalises late)" % (start, end, LAG_DAYS))
    print("  clicks %s, impressions %s, ctr %s, impression-weighted position %s, over %s row(s)"
          % (rec["clicks"], rec["impressions"], rec["ctr"], rec["position"], rec["rows"]))
    hist = load_history()
    print("  " + judge_trend(hist)["line"])
    print("seo-search-console: recorded. %d day(s) of series now on disk." % len(hist))
    print("SEO-SEARCH-CONSOLE-COMPLETE days=%d impressions=%s" % (len(hist), rec["impressions"]))
    return EXIT_CLEAN


if __name__ == "__main__":
    sys.exit(main())
