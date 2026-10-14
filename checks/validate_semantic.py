"""Validate semantic/*.yaml against the live database.

Checks:
  1. structure: model, source, dimensions[name, column, type, label], measures[name, column, type, format, label];
     measure type in sum/avg/count; names unique;
  2. every column exists in the source view;
  3. the loan-level model reproduces reporting.v_portfolio_metrics:
     SUM(measure) / SUM(portfolio) per report_date == ratio from the metrics view.

Stdlib only (tiny parser for this flat YAML format); runs SQL through psql, so
PG* env vars (or .env) must be set; PSQL env var overrides the psql command.
Usage: python checks/validate_semantic.py
"""
import csv
import io
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REQUIRED = {"dimensions": ["name", "column", "type", "label"],
            "measures": ["name", "column", "type", "format", "label"]}


def parse(path):
    model, section, item = {"dimensions": [], "measures": []}, None, None
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split(" #")[0].rstrip() if not raw.lstrip().startswith("#") else ""
        if not line.strip():
            continue
        m = re.match(r"^(\w+):\s*(.*)$", line)
        if m:  # top-level key
            key, val = m.groups()
            section = key if key in REQUIRED else None
            if not section:
                model[key] = val.strip('"')
            continue
        m = re.match(r"^\s*(-\s+)?(\w+):\s*(.*)$", line)
        if m and section:
            dash, key, val = m.groups()
            if dash:
                item = {}
                model[section].append(item)
            item[key] = val.strip().strip('"')
    return model


def psql(sql):
    env = dict(os.environ, PGCLIENTENCODING="UTF8")
    envf = ROOT / ".env"
    if envf.exists():
        for ln in envf.read_text().splitlines():
            if "=" in ln and not ln.startswith("#"):
                k, v = ln.split("=", 1)
                env.setdefault(k.strip(), v.strip())
    cmd = shlex.split(os.environ.get("PSQL", "psql"))  # same override as scripts/build.sh (e.g. docker exec)
    out = subprocess.run([*cmd, "-X", "-v", "ON_ERROR_STOP=1", "-c", f"COPY ({sql}) TO STDOUT WITH CSV HEADER"],
                         capture_output=True, env=env, check=True).stdout.decode("utf-8")
    return list(csv.DictReader(io.StringIO(out)))


def main():
    errors = []
    models = {}
    for path in sorted((ROOT / "semantic").glob("*.yaml")):
        m = parse(path)
        models[m.get("model")] = m
        for k in ("model", "source"):
            if not m.get(k):
                errors.append(f"{path.name}: missing '{k}'")
        schema, view = m["source"].split(".")
        cols = {r["column_name"] for r in psql(
            f"SELECT column_name FROM information_schema.columns WHERE table_schema='{schema}' AND table_name='{view}'")}
        if not cols:
            errors.append(f"{path.name}: source {m['source']} not found")
        names = set()
        for section, req in REQUIRED.items():
            for it in m[section]:
                for k in req:
                    if not it.get(k):
                        errors.append(f"{path.name}: {section} item {it.get('name')} missing '{k}'")
                if it.get("name") in names:
                    errors.append(f"{path.name}: duplicate name {it['name']}")
                names.add(it.get("name"))
                if it.get("column") not in cols:
                    errors.append(f"{path.name}: column {it.get('column')} not in {m['source']}")
                if section == "measures" and it.get("type") not in ("sum", "avg", "count"):
                    errors.append(f"{path.name}: measure {it['name']} has bad type {it.get('type')}")
        print(f"{path.name}: {len(m['dimensions'])} dimensions, {len(m['measures'])} measures, source {m['source']}")

    if errors:  # structural problems: report them, the reproduction query would fail anyway
        print("SEMANTIC MODEL: FAILED")
        for e in errors:
            print("  -", e)
        return 1

    # Reproduce headline metrics from the loan-level model measures.
    lp ={x["name"]: x for x in models["loan_portfolio"]["measures"]}
    sel = ", ".join(f"{x['type']}({x['column']}) AS {x['name']}" for x in lp.values())
    got = {r["report_date"]: r for r in psql(
        f"SELECT report_date, {sel} FROM {models['loan_portfolio']['source']} GROUP BY report_date ORDER BY 1")}
    exp = {r["report_date"]: r for r in psql("SELECT * FROM reporting.v_portfolio_metrics ORDER BY 1")}
    pairs = {"par30_ratio": "par30_kzt", "par90_ratio": "par90_kzt", "npl_ratio": "npl_kzt",
             "provision_coverage": "provisions_kzt", "top10_concentration": "top10_groups_kzt"}
    for d, e in exp.items():
        g = got[d]
        if abs(float(g["portfolio_kzt"]) - float(e["portfolio_kzt"])) > 0.01:
            errors.append(f"{d}: portfolio mismatch {g['portfolio_kzt']} vs {e['portfolio_kzt']}")
        if int(g["loans_count"]) != int(e["loans_cnt"]):
            errors.append(f"{d}: loans count mismatch")
        for ratio, num in pairs.items():
            r = float(g[num]) / float(g["portfolio_kzt"])
            if abs(r - float(e[ratio])) > 1e-9:
                errors.append(f"{d}: {ratio} from model {r} vs view {e[ratio]}")
    print("SEMANTIC MODEL:", "OK" if not errors else "FAILED")
    for e in errors:
        print("  -", e)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
