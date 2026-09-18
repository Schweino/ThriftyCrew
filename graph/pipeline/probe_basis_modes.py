"""Basis-mode probe - do basis errors form a SECOND MODE per commodity? (backlog I182)

WHAT IT MEASURES. flag_outliers.py bars a per-unit price more than a fixed 5.0x BELOW the
commodity median, and grocery/audit-unit-basis-outlier.ps1 flags one at or above 4.0x ABOVE it.
A basis error (a per-pack price read as per-ounce, or the reverse) is expected to produce not one
stray row but a second population offset by roughly the pack size. This probe asks, per commodity,
whether the per-unit prices split into two groups, and whether the smaller group escapes the fixed
factor on its own side. It reads exactly flag_outliers' rows and per-unit prices: match_status
include_hit or llm_confirmed, per-unit from its own row_unit_price, pu > 0, whatever basis_flag says.

THE TEST (the acceptance bar is in design/BACKLOG-course-findings.md, item I182, written before the run):
  two modes   VARIANT 2. A two-component Gaussian mixture on log10(per-unit), fitted by EM from
              Otsu's split, sd floored at SD_FLOOR. It must beat one component on BIC by more than
              MIN_BIC_GAIN, Ashman's D on the FITTED means and sds must be at least MIN_ASHMAN_D,
              and the minority component must hold at least MIN_MODE_ROWS rows by hard assignment.
              Variant 1 put Ashman's D on the two Otsu classes and was invalid: a hard split of any
              continuous spread truncates both classes, so a uniform spread scores D = 3.46. The
              smooth-spread MUST NOT FIRE below is the case that caught it.
  minority    the smaller component by hard assignment; on a tie, the LOWER one (the false-cheap side
              is the one that reaches a reader).
  blind       a two-mode commodity with at least one minority row the fixed factor on its side
              misses: a LOW row not below median/LOW_FACTOR, a HIGH row not at or above
              median*HIGH_FACTOR. The median is the arm's own median over every priced row.

TWO ARMS. pool = every eligible row (the population flag_outliers takes its median over).
day = rows whose observed_at date is the date with the most eligible rows among the last 7 dates.

READ-ONLY. graph.db is opened with sqlite URI mode=ro. graph.db is gitignored, so a worktree has
none: pass --db, ideally a COPY. Writes one JSON row per commodity per arm to --out if given.

SCOPE OF A CLEAN REPORT: UNSOUND. Otsu always finds a cut, and D >= 2 is a separation bar, not a
proof of two populations; a commodity with fewer than N rows is not tested at all. "Not blind" says
the fixed factors would catch this split's minority, not that the commodity is clean. What a
second mode MEANS (basis error, genuine price tier, wrong product) is not decided here: it is read
by hand off the minority rows the probe prints.

Usage:
  python graph/pipeline/probe_basis_modes.py --db PATH [--arm pool|day|both] [--n 8] [--out rows.jsonl]
  python graph/pipeline/probe_basis_modes.py --selftest
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sqlite3
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
sys.path.insert(0, HERE)

MIN_ROWS = 8          # N, stated before the run
MIN_MODE_ROWS = 2     # one row is an outlier, not a mode
MIN_ASHMAN_D = 2.0    # the standard bar for two cleanly separated groups (on FITTED parameters)
MIN_BIC_GAIN = 6.0    # two components must beat one by more than this ("strong")
SD_FLOOR = 0.02       # log10, about 5% in price: identical prices cannot make a zero-width component
EM_MAX_ITER = 500
LOW_FACTOR = 5.0      # flag_outliers.DEFAULT_FACTOR
HIGH_FACTOR = 4.0     # audit-unit-basis-outlier.ps1


def otsu_split(values: list[float]) -> int:
    """Index k into sorted values: class 0 = values[:k], class 1 = values[k:]. Maximises
    w0*w1*(m0-m1)^2 over every cut with both classes non-empty."""
    n = len(values)
    total = sum(values)
    best_k, best_v, left = 1, -1.0, 0.0
    for k in range(1, n):
        left += values[k - 1]
        w0, w1 = k / n, (n - k) / n
        m0, m1 = left / k, (total - left) / (n - k)
        v = w0 * w1 * (m0 - m1) ** 2
        if v > best_v:
            best_v, best_k = v, k
    return best_k


def _npdf(x: float, m: float, s: float) -> float:
    return math.exp(-0.5 * ((x - m) / s) ** 2) / (s * math.sqrt(2 * math.pi))


def fit_mixture(xs: list[float], k: int):
    """Two-component Gaussian mixture by EM, initialised from the Otsu split at k (xs sorted).
    Returns (w0, m0, s0, m1, s1, loglik, posteriors_of_component_1)."""
    n = len(xs)
    a, b = xs[:k], xs[k:]
    w0 = len(a) / n
    m0, m1 = statistics.fmean(a), statistics.fmean(b)
    s0, s1 = max(statistics.pstdev(a), SD_FLOOR), max(statistics.pstdev(b), SD_FLOOR)
    prev = -math.inf
    for _ in range(EM_MAX_ITER):
        p0 = [w0 * _npdf(x, m0, s0) for x in xs]
        p1 = [(1 - w0) * _npdf(x, m1, s1) for x in xs]
        tot = [u + v for u, v in zip(p0, p1)]
        ll = sum(math.log(t) for t in tot if t > 0)
        r1 = [v / t if t > 0 else 0.5 for v, t in zip(p1, tot)]
        n1 = sum(r1)
        n0 = n - n1
        if n0 < 1e-9 or n1 < 1e-9:
            break
        w0 = n0 / n
        m0 = sum((1 - r) * x for r, x in zip(r1, xs)) / n0
        m1 = sum(r * x for r, x in zip(r1, xs)) / n1
        s0 = max(math.sqrt(sum((1 - r) * (x - m0) ** 2 for r, x in zip(r1, xs)) / n0), SD_FLOOR)
        s1 = max(math.sqrt(sum(r * (x - m1) ** 2 for r, x in zip(r1, xs)) / n1), SD_FLOOR)
        if abs(ll - prev) < 1e-9:
            break
        prev = ll
    p0 = [w0 * _npdf(x, m0, s0) for x in xs]
    p1 = [(1 - w0) * _npdf(x, m1, s1) for x in xs]
    tot = [u + v for u, v in zip(p0, p1)]
    ll = sum(math.log(t) for t in tot if t > 0)
    r1 = [v / t if t > 0 else 0.5 for v, t in zip(p1, tot)]
    return w0, m0, s0, m1, s1, ll, r1


def assess(priced: list[tuple[float, dict]], n_min: int = MIN_ROWS) -> dict | None:
    """priced = [(per_unit, row_dict)]. None when below n_min. Variant 2 (see header)."""
    if len(priced) < n_min:
        return None
    priced = sorted(priced, key=lambda t: t[0])
    logs = [math.log10(p) for p, _ in priced]
    n = len(logs)
    k = otsu_split(logs)
    w0, m0, s0, m1, s1, ll2, r1 = fit_mixture(logs, k)
    mu, sd = statistics.fmean(logs), max(statistics.pstdev(logs), SD_FLOOR)
    ll1 = sum(math.log(_npdf(x, mu, sd)) for x in logs)
    bic1 = 2 * math.log(n) - 2 * ll1
    bic2 = 5 * math.log(n) - 2 * ll2
    d = math.sqrt(2) * abs(m1 - m0) / math.sqrt(s0 ** 2 + s1 ** 2)
    # component 0 is the lower-mean one after the swap below
    if m0 > m1:
        m0, m1, s0, s1 = m1, m0, s1, s0
        r1 = [1 - r for r in r1]
    lo = [t for t, r in zip(priced, r1) if r <= 0.5]
    hi = [t for t, r in zip(priced, r1) if r > 0.5]
    med = statistics.median([p for p, _ in priced])
    minority_side = "low" if len(lo) <= len(hi) else "high"
    minority = lo if minority_side == "low" else hi
    two_modes = (bic1 - bic2 > MIN_BIC_GAIN and d >= MIN_ASHMAN_D
                 and len(minority) >= MIN_MODE_ROWS and len(lo) > 0 and len(hi) > 0)
    gm = lambda xs: (10 ** statistics.fmean([math.log10(p) for p, _ in xs])) if xs else float("nan")
    rows, escaped = [], 0
    for p, r in minority:
        caught = (p < med / LOW_FACTOR) if minority_side == "low" else (p >= med * HIGH_FACTOR)
        if not caught:
            escaped += 1
        rows.append({**r, "per_unit": round(p, 5), "x_median": round(p / med, 3), "caught": caught})
    return {
        "n": len(priced), "median": round(med, 5),
        "lo_n": len(lo), "hi_n": len(hi),
        "lo_gm": round(gm(lo), 5), "hi_gm": round(gm(hi), 5),
        "gap": round(gm(hi) / gm(lo), 2),
        "ashman_d": round(d, 2), "bic_gain": round(bic1 - bic2, 2),
        "mode_lo": round(10 ** m0, 5), "mode_hi": round(10 ** m1, 5),
        "two_modes": two_modes, "minority_side": minority_side,
        "minority_n": len(minority), "minority_escaped": escaped,
        "blind": two_modes and escaped > 0,
        "minority_rows": rows,
    }


def load(db_path: str) -> dict[str, list[dict]]:
    from flag_outliers import row_unit_price  # the rows and prices flag_outliers itself uses
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    out: dict[str, list[dict]] = {}
    for c in conn.execute("SELECT id, properties_json FROM nodes WHERE type='Commodity' ORDER BY id"):
        basis = json.loads(c["properties_json"] or "{}").get("unit_basis")
        for r in conn.execute(
                """SELECT id, product_name, price, unit_price, unit, size_text, store_id, observed_at, basis_flag
                   FROM price_observations
                   WHERE commodity_id=? AND match_status IN ('include_hit','llm_confirmed')""", (c["id"],)):
            pu = row_unit_price(r, basis)
            if pu is not None and pu > 0:
                out.setdefault(c["id"], []).append({
                    "pu": pu, "product": (r["product_name"] or "")[:70], "store": r["store_id"].replace("store:", ""),
                    "price": r["price"], "size": r["size_text"], "date": (r["observed_at"] or "")[:10],
                    "basis_flag": r["basis_flag"]})
    conn.close()
    return out


def run_arm(data: dict[str, list[dict]], arm: str, n_min: int) -> tuple[list[dict], str | None]:
    day = None
    if arm == "day":
        counts: dict[str, int] = {}
        for rows in data.values():
            for r in rows:
                counts[r["date"]] = counts.get(r["date"], 0) + 1
        last7 = sorted(counts)[-7:]
        day = max(last7, key=lambda d: (counts[d], d))
    results = []
    for cid, rows in sorted(data.items()):
        use = [r for r in rows if day is None or r["date"] == day]
        priced = [(r["pu"], {k: v for k, v in r.items() if k != "pu"}) for r in use]
        a = assess(priced, n_min)
        if a is not None:
            results.append({"arm": arm, "day": day, "commodity": cid, **a})
    return results, day


def selftest() -> int:
    fails, ran = 0, 0

    def case(label, cond):
        nonlocal fails, ran
        ran += 1
        print(("ok   " if cond else "FAIL ") + label)
        if not cond:
            fails += 1

    def rows(prices):
        return [(p, {"product": f"p{i}"}) for i, p in enumerate(prices)]

    # MUST FIRE: a second mode 3x below the rest - inside flag_outliers' blind range.
    a = assess(rows([1.00, 1.02, 0.98, 1.05, 0.97, 1.01, 0.33, 0.34]))
    case("MUST FIRE: a low second mode at 3x below is two-mode and BLIND", a["two_modes"] and a["blind"]
         and a["minority_side"] == "low" and a["minority_escaped"] == 2)
    # CLEAN TWIN: the same shape at 10x below is two-mode and CAUGHT by the 5x factor.
    a = assess(rows([1.00, 1.02, 0.98, 1.05, 0.97, 1.01, 0.10, 0.101]))
    case("CLEAN TWIN: a low second mode at 10x below is two-mode and caught", a["two_modes"]
         and not a["blind"] and a["minority_escaped"] == 0)
    # MUST FIRE, high side: 3x above escapes the 4x audit.
    a = assess(rows([1.00, 1.02, 0.98, 1.05, 0.97, 1.01, 3.0, 3.1]))
    case("MUST FIRE: a high second mode at 3x above is BLIND on the high side", a["blind"]
         and a["minority_side"] == "high")
    # MUST NOT FIRE: a smooth spread has no second mode.
    a = assess(rows([0.80, 0.85, 0.90, 0.95, 1.00, 1.05, 1.10, 1.15, 1.20]))
    case("MUST NOT FIRE: a smooth spread is not two-mode", not a["two_modes"] and not a["blind"])
    # MUST NOT FIRE: forty prices spread evenly in log over a 3x range - ordinary price dispersion.
    a = assess(rows([10 ** (math.log10(0.5) + i * math.log10(3) / 39) for i in range(40)]))
    case("MUST NOT FIRE: an even 3x spread of forty prices is not two-mode", not a["two_modes"])
    # MUST NOT FIRE: one stray row is an outlier, not a mode.
    a = assess(rows([1.00, 1.02, 0.98, 1.05, 0.97, 1.01, 1.03, 0.30]))
    case("MUST NOT FIRE: a single stray row is not a mode", not a["two_modes"])
    # MUST NOT FIRE: below N nothing is assessed.
    case("MUST NOT FIRE: seven rows are below N=8", assess(rows([1, 1, 1, 1, 1, 0.3, 0.3])) is None)

    expected = 7
    if ran != expected:
        print(f"FAIL ran {ran} of {expected} cases")
        fails += 1
    print(f"probe_basis_modes self-test: {'pass' if fails == 0 else 'FAIL'} ({ran - fails} of {ran} cases)")
    return 0 if fails == 0 else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db")
    ap.add_argument("--arm", choices=["pool", "day", "both"], default="both")
    ap.add_argument("--n", type=int, default=MIN_ROWS)
    ap.add_argument("--out")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.db or not os.path.exists(a.db):
        print("probe_basis_modes: --db must name a graph.db (a COPY); none given or not found - BLIND")
        print("PROBE-BASIS-MODES-COMPLETE blind=no-db")
        return 3
    h = hashlib.md5()
    with open(a.db, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    print(f"input: {a.db} md5={h.hexdigest()}")
    data = load(a.db)
    print(f"commodities with any priced row: {len(data)}; priced rows: {sum(len(v) for v in data.values())}")
    arms = ["pool", "day"] if a.arm == "both" else [a.arm]
    allrows = []
    for arm in arms:
        res, day = run_arm(data, arm, a.n)
        allrows += res
        tested = len(res)
        two = [r for r in res if r["two_modes"]]
        blind = [r for r in two if r["blind"]]
        bl = [r for r in blind if r["minority_side"] == "low"]
        bh = [r for r in blind if r["minority_side"] == "high"]
        print(f"\n[{arm}{' ' + day if day else ''}] tested {tested} commodities with n >= {a.n}")
        print(f"  two modes: {len(two)} of {tested}")
        print(f"  blind: {len(blind)} of {tested} (low side {len(bl)}, high side {len(bh)}); "
              f"two-mode and caught: {len(two) - len(blind)} of {len(two)}")
        for r in blind:
            print(f"  {r['commodity'].split(':')[-1]:<34} n={r['n']:<4} {r['minority_side']:<4} "
                  f"minority {r['minority_n']} (escaped {r['minority_escaped']}) gap {r['gap']}x D={r['ashman_d']}")
    if a.out:
        with open(a.out, "w", encoding="utf-8", newline="\n") as f:
            for r in allrows:
                f.write(json.dumps(r, default=str) + "\n")
        print(f"\nwrote {len(allrows)} rows to {a.out}")
    print(f"PROBE-BASIS-MODES-COMPLETE rows={len(allrows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
