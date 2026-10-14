"""Independent reference calculation of portfolio risk metrics.

Pure Python (stdlib only), does NOT touch PostgreSQL. Used to cross-check
the numbers produced by the reporting.* views.

Usage:
    python checks/reference_metrics.py                       # print reference metrics
    python checks/reference_metrics.py --compare FILE.csv    # compare with export of reporting.v_portfolio_metrics
"""
import argparse
import csv
import sys
from collections import defaultdict
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"

METRICS = [
    "portfolio_kzt", "loans_cnt", "par30_kzt", "par90_kzt", "npl_kzt",
    "provisions_kzt", "top10_groups_kzt",
    "par30_ratio", "par90_ratio", "npl_ratio", "provision_coverage", "top10_concentration",
]


def load():
    fx = {}
    with open(DATA / "fx.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            fx[(r["date"], r["currency"])] = Decimal(r["rate_kzt"])

    seen = set()
    loans = []
    dup = 0
    with open(DATA / "portfolio.csv", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            key = (r["report_date"], r["loan_id"])
            if key in seen:
                dup += 1
                continue
            seen.add(key)
            loans.append(r)
    return loans, fx, dup


def rate(fx, date, cur):
    if cur == "KZT":
        return Decimal(1)
    # rate on the snapshot date; fall back to the last earlier date if missing
    cands = [d for (d, c) in fx if c == cur and d <= date]
    if not cands:
        raise ValueError(f"no FX rate for {cur} on {date}")
    return fx[(max(cands), cur)]


def compute():
    loans, fx, dup = load()
    out = {}
    for date in sorted({r["report_date"] for r in loans}):
        m = defaultdict(Decimal)
        groups = defaultdict(Decimal)
        cnt = 0
        for r in loans:
            if r["report_date"] != date or r["written_off"] == "1":
                continue
            amt = Decimal(r["principal_outstanding"]) * rate(fx, date, r["currency"])
            dpd = int(r["days_past_due"])
            npl = dpd > 90 or r["restructured"] == "1"
            cnt += 1
            m["portfolio_kzt"] += amt
            m["par30_kzt"] += amt if dpd > 30 else 0
            m["par90_kzt"] += amt if dpd > 90 else 0
            m["npl_kzt"] += amt if npl else 0
            pr = Decimal("0.50") if npl else (Decimal("0.10") if dpd > 30 else Decimal("0.01"))
            m["provisions_kzt"] += amt * pr
            groups[r["group_id"]] += amt
        m["top10_groups_kzt"] = sum(sorted(groups.values(), reverse=True)[:10])
        p = m["portfolio_kzt"]
        res = {k: m[k] for k in ["portfolio_kzt", "par30_kzt", "par90_kzt", "npl_kzt", "provisions_kzt", "top10_groups_kzt"]}
        res["loans_cnt"] = Decimal(cnt)
        res["par30_ratio"] = m["par30_kzt"] / p
        res["par90_ratio"] = m["par90_kzt"] / p
        res["npl_ratio"] = m["npl_kzt"] / p
        res["provision_coverage"] = m["provisions_kzt"] / p
        res["top10_concentration"] = m["top10_groups_kzt"] / p
        out[date] = res
    return out, dup


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--compare", help="CSV export of reporting.v_portfolio_metrics")
    args = ap.parse_args()
    ref, dup = compute()
    print(f"duplicate rows skipped: {dup}")
    for d, res in ref.items():
        print(f"\n== {d}")
        for k in METRICS:
            v = res[k]
            print(f"  {k:22s} {v:,.6f}" if "ratio" in k or "concentration" in k or "coverage" in k else f"  {k:22s} {v:,.2f}")

    if not args.compare:
        return 0
    errors = 0
    with open(args.compare, encoding="utf-8") as f:
        rows = {r["report_date"]: r for r in csv.DictReader(f)}
    for d, res in ref.items():
        for k in METRICS:
            sql_v = Decimal(rows[d][k])
            tol = Decimal("1e-9") if k.endswith(("ratio", "coverage", "concentration")) else Decimal("0.01")
            if abs(sql_v - res[k]) > tol:
                errors += 1
                print(f"MISMATCH {d} {k}: sql={sql_v} ref={res[k]}")
    print("\nRECONCILIATION:", "OK" if errors == 0 else f"{errors} mismatches")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
